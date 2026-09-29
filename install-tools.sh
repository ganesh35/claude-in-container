#!/bin/sh
# Installs tools pinned in the environment into $HOME/.local, skipping any already at that version.
# Download or install errors are logged and skipped; a failed checksum or signature check exits 2 so the container stops.
set -eu
# Fixed PATH: /data/.home/.local/bin comes first in the image and is user-writable, so nothing there may shadow the tools that verify downloads
PATH=/usr/local/bin:/usr/bin:/bin
prefix="$HOME/.local" state="$HOME/.local/share/cic-tools" lock="$HOME/.local/.install-tools.lock"
export UV_TOOL_DIR="$prefix/share/uv/tools" UV_TOOL_BIN_DIR="$prefix/bin"
mkdir -p "$prefix/bin" "$state"
case $(uname -m) in
  x86_64) arch=amd64 awsarch=x86_64 ;;
  aarch64 | arm64) arch=arm64 awsarch=aarch64 ;;
  *)
    echo "tools: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

log() { echo "tools: $*"; }
# HTTPS only, including redirects: a redirect to plain http would otherwise be followed
# Timeouts: a stalled download would otherwise hold the install lock indefinitely
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 30 --speed-limit 1000 --speed-time 60 --max-time 900 -o "$2" "$1"; }
# Fails on a missing or wrong checksum; callers map that to exit 2
sha_ok() { [ -n "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }
# AWS CLI signing key from the AWS CLI install guide; it expires 2027-07-01, then refresh keys/aws-cli.asc from the guide
aws_key=/usr/local/share/claude-in-container/aws-cli.asc aws_fpr=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
# Valid signature by the pinned fingerprint only, so a swapped key file can't pass either
aws_sig_ok() (
  export GNUPGHOME="$PWD/gnupg"
  mkdir -m 700 "$GNUPGHOME" && gpg --batch --quiet --import "$aws_key" 2>/dev/null &&
    gpg --batch --status-fd 1 --verify "$1.sig" "$1" 2>/dev/null | grep "^\[GNUPG:\] VALIDSIG $aws_fpr " >/dev/null
)

# Installers run in a temp dir and get the version as their last argument.
# set -e is off inside || contexts, so every step checks its own result.
install_gh() {
  f="gh_$1_linux_$arch.tar.gz" u="https://github.com/cli/cli/releases/download/v$1"
  fetch "$u/$f" "$f" && fetch "$u/gh_$1_checksums.txt" sums || return 1
  sha_ok "$f" "$(awk -v f="$f" '$2 == f {print $1}' sums)" || return 2
  tar -xzf "$f" && install "gh_$1_linux_$arch/bin/gh" "$prefix/bin/gh"
}
install_yq() {
  f="yq_linux_$arch" u="https://github.com/mikefarah/yq/releases/download/v$1"
  fetch "$u/$f" "$f" && fetch "$u/checksums-bsd" sums || return 1
  sha_ok "$f" "$(sed -n "s/^SHA256 ($f) = //p" sums)" || return 2
  install "$f" "$prefix/bin/yq"
}
install_jq() {
  f="jq-linux-$arch" u="https://github.com/jqlang/jq/releases/download/jq-$1"
  fetch "$u/$f" "$f" && fetch "$u/sha256sum.txt" sums || return 1
  sha_ok "$f" "$(awk -v f="$f" '$2 == f {print $1}' sums)" || return 2
  install "$f" "$prefix/bin/jq"
}
install_terraform() {
  f="terraform_$1_linux_$arch.zip" u="https://releases.hashicorp.com/terraform/$1"
  fetch "$u/$f" "$f" && fetch "$u/terraform_$1_SHA256SUMS" sums || return 1
  sha_ok "$f" "$(awk -v f="$f" '$2 == f {print $1}' sums)" || return 2
  unzip -q "$f" terraform && install terraform "$prefix/bin/terraform"
}
install_aws() {
  u="https://awscli.amazonaws.com/awscli-exe-linux-$awsarch-$1.zip"
  fetch "$u" aws.zip && fetch "$u.sig" aws.zip.sig || return 1
  aws_sig_ok aws.zip || return 2
  unzip -q aws.zip || return 1
  ./aws/install --install-dir "$prefix/aws-cli" --bin-dir "$prefix/bin" --update
}
install_npm() { npm install -g "$1"; } # NPM_CONFIG_PREFIX in the image points at $prefix
install_uv() { uv tool install --force "$1"; }

run() { # key wanted-version binary-or-empty installer [args...]
  key=$1 want=$2 bin=$3
  shift 3
  [ -n "$want" ] || return 0
  if [ "$(cat "$state/$key" 2>/dev/null)" = "$want" ] && { [ -z "$bin" ] || [ -x "$prefix/bin/$bin" ]; }; then
    log "$key $want up to date"
    return 0
  fi
  d=$(mktemp -d) rc=0
  (cd "$d" && "$@" "$want") >"$d/.log" 2>&1 || rc=$?
  case $rc in
    0)
      printf '%s\n' "$want" >"$state/$key"
      log "$key $want installed"
      ;;
    2)
      log "$key $want VERIFICATION FAILED (checksum or signature), stopping"
      rm -rf "$d"
      exit 2
      ;;
    *)
      log "$key $want FAILED, continuing without it"
      tail -n 3 "$d/.log" | sed 's/^/tools:   /'
      ;;
  esac
  rm -rf "$d"
}

# One installer at a time across instances sharing the folder; a crashed holder's lock goes stale after 30 min
until mkdir "$lock" 2>/dev/null; do
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
    continue
  fi
  [ -n "${waiting:-}" ] || {
    log "waiting for another instance to finish installing"
    waiting=1
  }
  sleep 2
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
trap 'exit 1' INT TERM

run gh "${GH_VERSION:-}" gh install_gh
run yq "${YQ_VERSION:-}" yq install_yq
run jq "${JQ_VERSION:-}" jq install_jq
run terraform "${TERRAFORM_VERSION:-}" terraform install_terraform
run aws "${AWSCLI_VERSION:-}" aws install_aws

set -f # lists are split on spaces, never globbed
# Exact versions only: ranges, tags and git/file/URL specs would resolve to a moving target while the state file says
# "up to date". npm needs all three parts (it reads 'pnpm@12' as a range); pip's == is exact for any digits-and-dots version.
# Scoped npm names start with @, so the version is what follows the last @.
exact() { case $1 in '' | *[!0-9.]*) return 1 ;; *) return 0 ;; esac }
exact_npm() { case $1 in [0-9]*.[0-9]*.[0-9]*) exact "$1" ;; *) return 1 ;; esac }
for spec in ${NPM_TOOLS:-}; do
  if [ "${spec%@*}" != "$spec" ] && exact_npm "${spec##*@}"; then
    run "npm-$(printf '%s' "${spec%@*}" | tr '/@' '__')" "$spec" "" install_npm
  else log "npm $spec FAILED: pin an exact version as name@x.y.z"; fi
done
for spec in ${UV_TOOLS:-}; do
  if [ "${spec%%==*}" != "$spec" ] && exact "${spec##*==}"; then
    run "uv-${spec%%==*}" "$spec" "" install_uv
  else log "uv $spec FAILED: pin an exact version as name==x.y.z"; fi
done
