#!/bin/sh
# End-to-end tests on the local engine. Usage: scripts/test.sh
# Scripts run under every installed shell in TEST_SHELLS (default: dash ash bash zsh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# Everything runs from a copy without .env, so a user's CONTAINER_NAME or GHCR_TOKEN can never reach a real container or GHCR
work=$(mktemp -d "${TMPDIR:-/tmp}/cic-test.XXXXXX")
repo="$work/repo"
mkdir "$repo" && cp -R "$ROOT/Dockerfile" "$ROOT/start.sh" "$ROOT/install-tools.sh" "$ROOT/routine.sh" "$ROOT/.env.example" "$ROOT/compose.yaml" \
  "$ROOT/scripts" "$ROOT/keys" "$ROOT/unraid" "$ROOT/maintenance" "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/ca_profile.xml" \
  "$ROOT/.editorconfig" "$ROOT/.shellcheckrc" "$ROOT/.yamllint" "$ROOT/.gitignore" "$repo/"
for v in $CONTAINER_ENV CLAUDE_CODE_VERSION CONTAINER_NAME DATA_DIR GHCR_TOKEN GITHUB_TOKEN PUBLISH_IMAGE PLATFORMS RELEASE_REPO; do unset "$v"; done
CONTAINER_ENGINE=$ENGINE IMAGE="claude-in-container:test-$$" PUID=$(id -u) PGID=$(id -g)
export CONTAINER_ENGINE IMAGE PUID PGID
prefix="cic-test-$$" created="" failed=0
pin() { sed -n "s/^$1=//p" "$repo/.env.example" | tr -d '"'; }
JQ=$(pin JQ_VERSION) YQ=$(pin YQ_VERSION) AWS=$(pin AWSCLI_VERSION)
JQ_OLD=1.8.1 # any released jq older than the pin, to exercise a version change

# Removes only what this run created
cleanup() {
  for c in $created; do engine rm -f "$c" >/dev/null 2>&1 || true; done
  engine image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() { # description expected actual
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else
    echo "  FAIL $1 (expected '$2', got '$3')"
    failed=$((failed + 1))
  fi
}
rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
# grep reads all input (no -q): an early exit would SIGPIPE the producer and fail under pipefail
has() { grep -F "$1" >/dev/null && echo yes || echo no; }
logged() { engine logs "$1" 2>&1 | has "$2"; }
claude_args() { engine exec "$1" pgrep -xa claude | cut -d' ' -f2-; }
has_arg() { # container arg: yes if the claude process got arg as one argument
  # shellcheck disable=SC2016 # expands inside the container
  engine exec "$1" sh -c 'tr "\0" "\n" < /proc/$(pgrep -x claude)/cmdline' | grep -Fx "$2" >/dev/null && echo yes || echo no
}
use() { # container data-dir: points run.sh at it
  CONTAINER_NAME=$1 DATA_DIR=$2
  export CONTAINER_NAME DATA_DIR
  created="$created $1"
}
raw() { # label [--ro] [engine run args...]: a container started directly, with its own data dir under $work/label
  name="$prefix-$1"
  created="$created $name"
  mkdir -p "$work/$1"
  mount="$work/$1:/data"
  shift
  if [ "${1:-}" = --ro ]; then
    mount="$mount:ro"
    shift
  fi
  engine run -d --name "$name" --user "$PUID:$PGID" -v "$mount" "$@" "$IMAGE" >/dev/null || true
}
wait_healthy() { # stops early once the container is gone or has exited
  i=0
  while [ "$i" -lt 40 ]; do
    s=$(engine inspect -f '{{.State.Running}} {{.State.Health.Status}}' "$1" 2>/dev/null || echo "false missing")
    case $s in
      "true healthy")
        s=healthy
        break
        ;;
      "false "*)
        s="exited (${s#false })"
        break
        ;;
      *) ;; # still starting
    esac
    i=$((i + 1))
    sleep 5
  done
  echo "${s#true }"
}
wait_exit() { # echoes the exit code once the container stops
  i=0
  while [ "$(engine inspect -f '{{.State.Running}}' "$1")" = true ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 2
  done
  engine inspect -f '{{.State.ExitCode}}' "$1"
}
wait_until() { # container test-command...: polls up to 30 s
  c=$1
  shift
  i=0
  until engine exec "$c" "$@" >/dev/null 2>&1 || [ "$i" -ge 15 ]; do
    i=$((i + 1))
    sleep 2
  done
}

echo "== lint"
check "publish.sh refuses to run without a token" 1 "$(rc sh "$repo/scripts/publish.sh")"
check "release.sh refuses to run without a token" 2 "$(rc sh "$repo/scripts/release.sh" changed)"
if out=$(sh "$repo/scripts/lint.sh" 2>&1); then echo "  PASS lint.sh"; else
  echo "  FAIL lint.sh"
  echo "$out" | tail -20
  exit 1
fi
echo "== build"
if out=$(sh "$repo/scripts/build.sh" 2>&1); then echo "  PASS build.sh"; else
  echo "  FAIL build.sh"
  echo "$out" | tail -20
  exit 1
fi
echo "== security"
if out=$(sh "$repo/scripts/security.sh" "$IMAGE" 2>&1); then echo "  PASS image has no fixable CRITICAL vulnerabilities"; else
  echo "  FAIL image vulnerability scan"
  echo "$out" | tail -40
  exit 1
fi

tested=""
for shell in ${TEST_SHELLS:-dash ash bash zsh}; do
  command -v "$shell" >/dev/null || {
    echo "== $shell: SKIP (not installed)"
    continue
  }
  echo "== $shell"
  tested="$tested $shell"
  name="$prefix-$shell"
  use "$name" "$work/$shell"
  REMOTE_CONTROL_NAME="e2e $shell it's"
  export REMOTE_CONTROL_NAME
  check run.sh 0 "$(rc "$shell" "$repo/scripts/run.sh")"
  check "run.sh refuses an existing container" 1 "$(rc "$shell" "$repo/scripts/run.sh")"
  check "run.sh --replace" 0 "$(rc "$shell" "$repo/scripts/run.sh" --replace)"
  check "run.sh rejects an unknown option" 1 "$(rc "$shell" "$repo/scripts/run.sh" --bogus)"
  check healthy healthy "$(wait_healthy "$name")"
  check "session name arrives as one argument" yes "$(has_arg "$name" "$REMOTE_CONTROL_NAME")"
  engine exec "$name" touch /data/e2e-file || true
  # shellcheck disable=SC2012 # single known filename
  check "data files owned by PUID" "$PUID" "$(ls -ln "$DATA_DIR/e2e-file" | awk '{print $3}')"
  current=$(engine exec "$name" claude --version | cut -d' ' -f1)
  echo "CLAUDE_CODE_VERSION=$current" >"$repo/.env"
  check "update.sh is a no-op when current" "Already on" "$("$shell" "$repo/scripts/update.sh" "$current" 2>&1 | tail -1 | cut -c1-10)"
  rm "$repo/.env"
done
unset REMOTE_CONTROL_NAME

echo "== instances sharing one DATA_DIR"
shared="$work/shared" main="$prefix-main" second="$prefix-second"
use "$main" "$shared"
created="$created $second"
JQ_VERSION=$JQ sh "$repo/scripts/run.sh" >/dev/null || true
check "main: healthy" healthy "$(wait_healthy "$main")"
check "main: jq installed when missing" yes "$(logged "$main" "jq $JQ installed")"
check "main: resumes (CONTINUE default)" "claude --remote-control $main --continue" "$(claude_args "$main")"
engine exec "$main" touch /data/.home/e2e-shared || true
CONTINUE=false JQ_VERSION=$JQ sh "$repo/scripts/run.sh" --name "$second" >/dev/null || true
check "second: healthy" healthy "$(wait_healthy "$second")"
check "second: jq skipped when current" yes "$(logged "$second" "jq $JQ up to date")"
check "second: starts fresh (CONTINUE=false)" "claude --remote-control $second" "$(claude_args "$second")"
check "second: shares the login folder" 0 "$(rc engine exec "$second" test -f /data/.home/e2e-shared)"
check "second: uses the shared jq" "jq-$JQ" "$(engine exec "$second" jq --version)"

echo "== tool installs"
JQ_VERSION=$JQ_OLD TERRAFORM_VERSION=0.0.0-e2e AWSCLI_VERSION=$AWS sh "$repo/scripts/run.sh" --replace >/dev/null || true
check "healthy despite a failed install" healthy "$(wait_healthy "$main")"
check "jq reinstalled on version change" "jq-$JQ_OLD" "$(engine exec "$main" jq --version)"
check "failed install is logged" yes "$(logged "$main" "terraform 0.0.0-e2e FAILED, continuing")"
check "AWS CLI installed after signature check" yes "$(logged "$main" "aws $AWS installed")"
# exec re-runs the installer in the live container with extra vars; existing tools just report up to date
check "npm tool with an exact version installs" yes "$(engine exec -e NPM_TOOLS=cowsay@1.6.0 "$main" install-tools.sh 2>&1 | has "cowsay@1.6.0 installed")"
check "npm git spec is rejected" yes "$(engine exec -e NPM_TOOLS=e2e-bad@git+https://example.com/x.git "$main" install-tools.sh 2>&1 | has "FAILED: pin an exact version")"
check "npm range spec is rejected" yes "$(engine exec -e NPM_TOOLS=pnpm@12 "$main" install-tools.sh 2>&1 | has "pnpm@12 FAILED: pin an exact version")"
check "uv range spec is rejected" yes "$(engine exec -e "UV_TOOLS=ruff==0.9.*" "$main" install-tools.sh 2>&1 | has "FAILED: pin an exact version")"
# Test-only curl that corrupts downloads matching FAKE_CORRUPT; mounted where the installer's fixed PATH finds it first
cat >"$work/fakecurl" <<'FAKE'
#!/bin/sh
/usr/bin/curl "$@"; rc=$?; out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
case $out in $FAKE_CORRUPT) printf x >> "$out" ;; esac
exit $rc
FAKE
chmod +x "$work/fakecurl"
corrupt() { # label env-assignment file-pattern: container must stop with exit 2 and log the failure
  raw "$1" -v "$work/fakecurl:/usr/local/bin/curl:ro" -e "FAKE_CORRUPT=$3" -e "$2"
  check "$1 stops the container" 2 "$(wait_exit "$name")"
  check "$1 is logged" yes "$(logged "$name" "VERIFICATION FAILED")"
}
corrupt checksum-mismatch "YQ_VERSION=$YQ" 'yq_linux_*'
corrupt bad-signature "AWSCLI_VERSION=$AWS" aws.zip
# A stop during a first-start install must release the lock, or the next start waits behind it
raw stop-install -e "AWSCLI_VERSION=$AWS"
lock="$work/stop-install/.home/.local/.install-tools.lock"
i=0
until [ -d "$lock" ] || [ "$i" -ge 30 ]; do
  i=$((i + 1))
  sleep 1
done
engine stop -t 10 "$name" >/dev/null || true
check "stop during install releases the lock" no "$(test -d "$lock" && echo yes || echo no)"

echo "== behaviour"
name="$prefix-behaviour"
use "$name" "$work/behaviour"
REMOTE_CONTROL_NAME=e2e
export REMOTE_CONTROL_NAME
sh "$repo/scripts/run.sh" >/dev/null || true
wait_healthy "$name" >/dev/null
# Engine-agnostic (docker and podman report CapDrop differently): read the kernel's view from inside
check "all capabilities dropped" 0000000000000000 "$(engine exec "$name" sh -c "grep ^CapEff /proc/self/status | cut -f2")"
check "no-new-privileges set" 1 "$(engine exec "$name" sh -c "grep ^NoNewPrivs /proc/self/status | cut -f2")"
hc=$(engine inspect -f '{{index .Config.Healthcheck.Test 3}}' "$name")
check "healthcheck passes while claude runs" 0 "$(rc engine exec "$name" sh -c "$hc")"
# Twice: start.sh falls back from 'claude --continue' to a fresh 'claude'; wait for each state rather than sleeping
first=$(engine exec "$name" pgrep -x claude || true)
engine exec "$name" pkill -x claude || true
wait_until "$name" sh -c "p=\$(pgrep -x claude) && [ \"\$p\" != '$first' ]"
engine exec "$name" pkill -x claude || true
wait_until "$name" sh -c "! pgrep -x claude"
check "healthcheck fails once claude exits" 1 "$(rc engine exec "$name" sh -c "$hc")"
check "tmux session survives in the fallback shell" 0 "$(rc engine exec "$name" tmux has-session -t =main)"
engine exec "$name" tmux kill-session -t =main || true
i=0
while [ "$(engine inspect -f '{{.State.Running}}' "$name")" = true ] && [ "$i" -lt 10 ]; do
  i=$((i + 1))
  sleep 2
done
check "start.sh ends with the tmux session" yes "$(logged "$name" "session 'main' ended")"

raw apikey -e ANTHROPIC_API_KEY=e2e-dummy-key
wait_until "$name" pgrep -x claude
check "API key disables Remote Control" "claude --continue" "$(claude_args "$name")"
engine stop -t 10 "$name" >/dev/null || true
check "clean stop" 0 "$(engine inspect -f '{{.State.ExitCode}}' "$name")"
raw server -e REMOTE_CONTROL_MODE=server -e REMOTE_CONTROL_NAME=e2e
check "server mode starts the Remote Control server" yes "$(logged "$name" "Remote Control server, session name prefix: e2e")"
# Without a login the server exits at once; its error proves 'claude remote-control' ran
wait_until "$name" sh -c "tmux capture-pane -p -t =main: | grep -q 'must be logged in to use Remote Control'"
check "server mode ran claude remote-control" yes "$(engine exec "$name" tmux capture-pane -p -t =main: | has "must be logged in to use Remote Control")"
raw badmode -e REMOTE_CONTROL_MODE=bogus
check "unknown REMOTE_CONTROL_MODE stops the container" 1 "$(wait_exit "$name")"
raw badcontinue -e CONTINUE=bogus
check "unknown CONTINUE stops the container" 1 "$(wait_exit "$name")"
raw server-apikey -e REMOTE_CONTROL_MODE=server -e ANTHROPIC_API_KEY=e2e-dummy-key
check "server mode with an API key stops the container" 1 "$(wait_exit "$name")"
raw readonly --ro
check "unwritable DATA_DIR stops the container" 1 "$(wait_exit "$name")"

echo "== routines"
check "routines off by default" 1 "$(rc engine exec "$prefix-server" pgrep -x supercronic)"
mkdir -p "$work/routines-off"
echo '* * * * * true' >"$work/routines-off/routines"
raw routines-off
wait_until "$name" pgrep -x claude
check "a routines file alone does nothing (ROUTINES unset)" 1 "$(rc engine exec "$name" pgrep -x supercronic)"
mkdir -p "$work/routines"
# 7-field expressions (seconds first) fire every 5 s, so the suite needn't wait for a minute boundary
printf '%s\n' '*/5 * * * * * * echo e2e-routine-ran > /data/routine-proof' '*/5 * * * * * * routine say e2e hello' >"$work/routines/routines"
raw routines -e ROUTINES=/data/routines
wait_until "$name" test -f /data/routine-proof
check "routine schedule fires" 0 "$(rc engine exec "$name" test -f /data/routine-proof)"
wait_until "$name" sh -c "ls /data/routines-output/*say-e2e-hello.md"
check "routine helper saves the run" 0 "$(rc engine exec "$name" sh -c "ls /data/routines-output/*say-e2e-hello.md")"
# The summary line comes when claude -p finishes, a moment after the output file appears
i=0
until [ "$(logged "$name" "routine: ")" = yes ] || [ "$i" -ge 15 ]; do
  i=$((i + 1))
  sleep 2
done
check "routine run is logged" yes "$(logged "$name" "routine: ")"
check "claude still runs alongside routines" 0 "$(rc engine exec "$name" pgrep -x claude)"
mkdir -p "$work/badroutines"
echo "not a cron line" >"$work/badroutines/routines"
raw badroutines -e ROUTINES=/data/routines
wait_until "$name" pgrep -x claude
check "invalid routines file is logged" yes "$(logged "$name" "routines disabled")"
check "claude starts despite an invalid routines file" 0 "$(rc engine exec "$name" pgrep -x claude)"

echo "== shells tested:${tested:- none}"
if [ "$failed" -eq 0 ]; then echo "All tests passed"; else
  echo "$failed test(s) failed"
  exit 1
fi
