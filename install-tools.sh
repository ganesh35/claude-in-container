#!/bin/sh
# Installs tools pinned in the environment into $HOME/.local, skipping any already at that version.
# Download or install errors are logged and skipped; a checksum mismatch exits 2 so the container stops.
set -eu
prefix="$HOME/.local" state="$HOME/.local/share/cic-tools" lock="$HOME/.local/.install-tools.lock"
export UV_TOOL_DIR="$prefix/share/uv/tools" UV_TOOL_BIN_DIR="$prefix/bin"
mkdir -p "$prefix/bin" "$state"
case $(uname -m) in
  x86_64) arch=amd64 awsarch=x86_64 ;;
  aarch64 | arm64) arch=arm64 awsarch=aarch64 ;;
  *) echo "tools: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

log() { echo "tools: $*"; }
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
# Fails on a missing or wrong checksum; callers map that to exit 2
sha_ok() { [ -n "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

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
# AWS publishes a GPG signature, not a checksum; the download is over HTTPS from awscli.amazonaws.com
install_aws() {
  fetch "https://awscli.amazonaws.com/awscli-exe-linux-$awsarch-$1.zip" aws.zip && unzip -q aws.zip || return 1
  ./aws/install --install-dir "$prefix/aws-cli" --bin-dir "$prefix/bin" --update
}
install_npm() { npm install -g --prefix "$prefix" "$1"; }
install_uv() { uv tool install --force "$1"; }

run() { # key wanted-version binary-or-empty installer [args...]
  key=$1 want=$2 bin=$3; shift 3
  [ -n "$want" ] || return 0
  if [ "$(cat "$state/$key" 2>/dev/null)" = "$want" ] && { [ -z "$bin" ] || [ -x "$prefix/bin/$bin" ]; }; then
    log "$key $want up to date"; return 0
  fi
  d=$(mktemp -d) rc=0
  (cd "$d" && "$@" "$want") > "$d/.log" 2>&1 || rc=$?
  case $rc in
    0) printf '%s\n' "$want" > "$state/$key"; log "$key $want installed" ;;
    2) log "$key $want CHECKSUM MISMATCH, stopping"; rm -rf "$d"; exit 2 ;;
    *) log "$key $want FAILED, continuing without it"; tail -n 3 "$d/.log" | sed 's/^/tools:   /' ;;
  esac
  rm -rf "$d"
}

# One installer at a time across instances sharing the folder; a crashed holder's lock goes stale after 30 min
until mkdir "$lock" 2>/dev/null; do
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
  [ -n "${waiting:-}" ] || { log "waiting for another instance to finish installing"; waiting=1; }
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
for spec in ${NPM_TOOLS:-}; do
  # name@version, version required; scoped names start with @
  case $spec in
    ?*@?*) run "npm-$(printf '%s' "${spec%@*}" | tr '/@' '__')" "$spec" "" install_npm "$spec" ;;
    *) log "npm $spec FAILED: pin a version as name@version" ;;
  esac
done
for spec in ${UV_TOOLS:-}; do
  case $spec in
    ?*==?*) run "uv-${spec%%==*}" "$spec" "" install_uv "$spec" ;;
    *) log "uv $spec FAILED: pin a version as name==version" ;;
  esac
done
