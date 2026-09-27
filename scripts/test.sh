#!/bin/sh
# End-to-end tests on the local engine. Usage: scripts/test.sh
# Scripts run under every installed shell in TEST_SHELLS (default: dash ash bash zsh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# Setup steps end in || true so only checks fail a run; a failed setup shows up in the checks after it
# Work on a copy without .env, so a user's CONTAINER_NAME can never point tests at a real container
work=$(mktemp -d "${TMPDIR:-/tmp}/cic-test.XXXXXX")
repo="$work/repo"
mkdir "$repo" && cp -R "$ROOT/Dockerfile" "$ROOT/start.sh" "$ROOT/install-tools.sh" "$ROOT/scripts" "$ROOT/keys" "$repo/"
for v in $CONTAINER_ENV CLAUDE_CODE_VERSION CONTAINER_NAME DATA_DIR; do unset "$v"; done
CONTAINER_ENGINE=$ENGINE IMAGE="claude-in-container:test-$$" PUID=$(id -u) PGID=$(id -g)
export CONTAINER_ENGINE IMAGE PUID PGID
prefix="cic-test-$$" created="" failed=0

# Removes only what this run created
cleanup() {
  for c in $created; do engine rm -f "$c" >/dev/null 2>&1 || true; done
  engine image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

check() { # description expected actual
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (expected '$2', got '$3')"; failed=$((failed + 1)); fi
}
rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
use() { # container data-dir: points run.sh at it
  CONTAINER_NAME=$1 DATA_DIR=$2
  export CONTAINER_NAME DATA_DIR
  created="$created $1"
}
wait_healthy() {
  i=0
  while [ $i -lt 40 ]; do
    s=$(engine inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo missing)
    [ "$s" = healthy ] && break
    i=$((i + 1)); sleep 5
  done
  echo "$s"
}
wait_exit() { # echoes the exit code once the container stops
  i=0
  while [ "$(engine inspect -f '{{.State.Running}}' "$1")" = true ] && [ $i -lt 30 ]; do i=$((i + 1)); sleep 2; done
  engine inspect -f '{{.State.ExitCode}}' "$1"
}
# grep reads all input (no -q): an early exit would SIGPIPE the producer and fail under pipefail
logged() { engine logs "$1" 2>&1 | grep -F "$2" >/dev/null && echo yes || echo no; }
claude_args() { engine exec "$1" pgrep -xa claude | cut -d' ' -f2-; }
has_arg() { # container arg: yes if the claude process got arg as one argument
  # shellcheck disable=SC2016 # expands inside the container
  engine exec "$1" sh -c 'tr "\0" "\n" < /proc/$(pgrep -x claude)/cmdline' | grep -Fx "$2" >/dev/null && echo yes || echo no
}

echo "== lint"
check lint.sh 0 "$(rc sh "$ROOT/scripts/lint.sh")"
echo "== build"
check build.sh 0 "$(rc sh "$repo/scripts/build.sh")"

tested=""
for sh in ${TEST_SHELLS:-dash ash bash zsh}; do
  command -v "$sh" >/dev/null || { echo "== $sh: SKIP (not installed)"; continue; }
  echo "== $sh"; tested="$tested $sh"
  name="$prefix-$sh"; use "$name" "$work/$sh"
  REMOTE_CONTROL_NAME="e2e $sh it's"; export REMOTE_CONTROL_NAME
  check run.sh 0 "$(rc "$sh" "$repo/scripts/run.sh")"
  check "run.sh refuses an existing container" 1 "$(rc "$sh" "$repo/scripts/run.sh")"
  check "run.sh --replace" 0 "$(rc "$sh" "$repo/scripts/run.sh" --replace)"
  check healthy healthy "$(wait_healthy "$name")"
  check "session name arrives as one argument" yes "$(has_arg "$name" "$REMOTE_CONTROL_NAME")"
  engine exec "$name" touch /data/e2e-file || true
  # shellcheck disable=SC2012 # single known filename
  check "data files owned by PUID" "$PUID" "$(ls -ln "$DATA_DIR/e2e-file" | awk '{print $3}')"
  echo "CLAUDE_CODE_VERSION=$(engine exec "$name" claude --version | cut -d' ' -f1)" > "$repo/.env"
  check "update.sh is a no-op when current" "Already on" "$("$sh" "$repo/scripts/update.sh" 2>&1 | tail -1 | cut -c1-10)"
  rm "$repo/.env"
done
unset REMOTE_CONTROL_NAME

echo "== instances sharing one DATA_DIR"
shared="$work/shared" main="$prefix-main" second="$prefix-second"
use "$main" "$shared"; created="$created $second"
JQ_VERSION=1.8.2 sh "$repo/scripts/run.sh" >/dev/null || true
check "main: healthy" healthy "$(wait_healthy "$main")"
check "main: jq installed when missing" yes "$(logged "$main" "jq 1.8.2 installed")"
check "main: resumes (CONTINUE default)" "claude --remote-control $main --continue" "$(claude_args "$main")"
engine exec "$main" touch /data/.home/e2e-shared || true
CONTINUE=false JQ_VERSION=1.8.2 sh "$repo/scripts/run.sh" --name "$second" >/dev/null || true
check "second: healthy" healthy "$(wait_healthy "$second")"
check "second: jq skipped when current" yes "$(logged "$second" "jq 1.8.2 up to date")"
check "second: starts fresh (CONTINUE=false)" "claude --remote-control $second" "$(claude_args "$second")"
check "second: shares the login folder" 0 "$(rc engine exec "$second" test -f /data/.home/e2e-shared)"
check "second: uses the shared jq" jq-1.8.2 "$(engine exec "$second" jq --version)"

echo "== tool installs"
JQ_VERSION=1.8.1 TERRAFORM_VERSION=0.0.0-e2e AWSCLI_VERSION=2.37.4 sh "$repo/scripts/run.sh" --replace >/dev/null || true
check "healthy despite a failed install" healthy "$(wait_healthy "$main")"
check "jq reinstalled on version change" jq-1.8.1 "$(engine exec "$main" jq --version)"
check "failed install is logged" yes "$(logged "$main" "terraform 0.0.0-e2e FAILED, continuing")"
check "AWS CLI installed after signature check" yes "$(logged "$main" "aws 2.37.4 installed")"
# exec re-runs the installer in the live container with extra vars; existing tools just report up to date
check "npm tool with a numeric version installs" yes "$(engine exec -e NPM_TOOLS=cowsay@1.6.0 "$main" install-tools.sh 2>&1 | grep -F "cowsay@1.6.0 installed" >/dev/null && echo yes || echo no)"
check "npm spec without a numeric version is rejected" yes "$(engine exec -e NPM_TOOLS=e2e-bad@git+https://example.com/x.git "$main" install-tools.sh 2>&1 | grep -F "e2e-bad@git+https://example.com/x.git FAILED: pin a version" >/dev/null && echo yes || echo no)"
# Test-only curl that corrupts downloads matching FAKE_CORRUPT, reached via PATH
mkdir "$work/fakebin"
cat > "$work/fakebin/curl" <<'FAKE'
#!/bin/sh
/usr/bin/curl "$@"; rc=$?; out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
case $out in $FAKE_CORRUPT) printf x >> "$out" ;; esac
exit $rc
FAKE
chmod +x "$work/fakebin/curl"
corrupt() { # label env-assignment file-pattern: container must stop with exit 2 and log the failure
  name="$prefix-$1"; created="$created $name"; mkdir "$work/$1"
  engine run -d --name "$name" --user "$PUID:$PGID" -v "$work/$1:/data" -v "$work/fakebin:/fakebin:ro" -e "FAKE_CORRUPT=$3" \
    -e PATH=/fakebin:/data/.home/.local/bin:/usr/local/bin:/usr/bin:/bin -e "$2" "$IMAGE" >/dev/null || true
  check "$1 stops the container" 2 "$(wait_exit "$name")"
  check "$1 is logged" yes "$(logged "$name" "VERIFICATION FAILED")"
}
corrupt checksum-mismatch YQ_VERSION=4.53.6 'yq_linux_*'
corrupt bad-signature AWSCLI_VERSION=2.37.4 aws.zip

echo "== behaviour"
name="$prefix-behaviour"; use "$name" "$work/behaviour"
REMOTE_CONTROL_NAME=e2e; export REMOTE_CONTROL_NAME
sh "$repo/scripts/run.sh" >/dev/null || true
wait_healthy "$name" >/dev/null
# Engine-agnostic (docker and podman report CapDrop differently): read the kernel's view from inside
check "all capabilities dropped" 0000000000000000 "$(engine exec "$name" sh -c "grep ^CapEff /proc/self/status | cut -f2")"
check "no-new-privileges set" 1 "$(engine exec "$name" sh -c "grep ^NoNewPrivs /proc/self/status | cut -f2")"
hc=$(engine inspect -f '{{index .Config.Healthcheck.Test 3}}' "$name")
check "healthcheck passes while claude runs" 0 "$(rc engine exec "$name" sh -c "$hc")"
# Twice: start.sh falls back from 'claude --continue' to a fresh 'claude'
engine exec "$name" pkill -x claude || true; sleep 3
engine exec "$name" pkill -x claude || true; sleep 3
check "healthcheck fails once claude exits" 1 "$(rc engine exec "$name" sh -c "$hc")"
check "tmux session survives in the fallback shell" 0 "$(rc engine exec "$name" tmux has-session -t main)"
engine exec "$name" tmux kill-session -t main || true; sleep 8
check "start.sh ends with the tmux session" yes "$(logged "$name" "session 'main' ended")"

name="$prefix-apikey"; created="$created $name"; mkdir "$work/apikey"
engine run -d --name "$name" --user "$PUID:$PGID" -v "$work/apikey:/data" -e ANTHROPIC_API_KEY=e2e-dummy-key "$IMAGE" >/dev/null || true; sleep 10
check "API key disables Remote Control" "claude --continue" "$(claude_args "$name")"
engine stop -t 10 "$name" >/dev/null || true
check "clean stop" 0 "$(engine inspect -f '{{.State.ExitCode}}' "$name")"
name="$prefix-readonly"; created="$created $name"; mkdir "$work/readonly"
engine run -d --name "$name" --user "$PUID:$PGID" -v "$work/readonly:/data:ro" "$IMAGE" >/dev/null || true
check "unwritable DATA_DIR stops the container" 1 "$(wait_exit "$name")"

echo "== shells tested:${tested:- none}"
if [ "$failed" -eq 0 ]; then echo "All tests passed"; else echo "$failed test(s) failed"; exit 1; fi
