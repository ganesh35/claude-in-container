#!/bin/sh
# End-to-end tests on the local engine. Usage: scripts/test.sh
# Scripts run under every installed shell in TEST_SHELLS (default: dash ash bash zsh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# Work on a copy without .env, so a user's CONTAINER_NAME can never point tests at a real container
work=$(mktemp -d "${TMPDIR:-/tmp}/cic-test.XXXXXX")
repo="$work/repo"
mkdir "$repo" && cp -R "$ROOT/Dockerfile" "$ROOT/start.sh" "$ROOT/scripts" "$repo/"
unset CLAUDE_CODE_VERSION ANTHROPIC_API_KEY REMOTE_CONTROL_NAME CONTAINER_NAME WORKSPACE_DIR CLAUDE_HOME_DIR
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
use() { # container name: points run.sh at it and its own folders
  CONTAINER_NAME=$1 WORKSPACE_DIR="$work/$1/workspace" CLAUDE_HOME_DIR="$work/$1/home"
  export CONTAINER_NAME WORKSPACE_DIR CLAUDE_HOME_DIR
  created="$created $1"
}
wait_healthy() {
  i=0
  while [ $i -lt 24 ]; do
    s=$(engine inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo missing)
    [ "$s" = healthy ] && break
    i=$((i + 1)); sleep 5
  done
  echo "$s"
}
has_arg() { # container arg: yes if the claude process got arg as one argument
  # shellcheck disable=SC2016 # expands inside the container
  # grep reads all input (no -q): an early exit would SIGPIPE the producer and fail under pipefail
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
  name="$prefix-$sh"; use "$name"
  REMOTE_CONTROL_NAME="e2e $sh it's"; export REMOTE_CONTROL_NAME
  check run.sh 0 "$(rc "$sh" "$repo/scripts/run.sh")"
  check "run.sh refuses an existing container" 1 "$(rc "$sh" "$repo/scripts/run.sh")"
  check "run.sh --replace" 0 "$(rc "$sh" "$repo/scripts/run.sh" --replace)"
  check healthy healthy "$(wait_healthy "$name")"
  check "session name arrives as one argument" yes "$(has_arg "$name" "$REMOTE_CONTROL_NAME")"
  engine exec "$name" touch /workspace/e2e-file
  # shellcheck disable=SC2012 # single known filename
  check "workspace files owned by PUID" "$PUID" "$(ls -ln "$WORKSPACE_DIR/e2e-file" | awk '{print $3}')"
  echo "CLAUDE_CODE_VERSION=$(engine exec "$name" claude --version | cut -d' ' -f1)" > "$repo/.env"
  check "update.sh is a no-op when current" "Already on" "$("$sh" "$repo/scripts/update.sh" 2>&1 | tail -1 | cut -c1-10)"
  rm "$repo/.env"
done

echo "== behaviour"
name="$prefix-behaviour"; use "$name"
REMOTE_CONTROL_NAME=e2e; export REMOTE_CONTROL_NAME
sh "$repo/scripts/run.sh" >/dev/null
wait_healthy "$name" >/dev/null
hc=$(engine inspect -f '{{index .Config.Healthcheck.Test 3}}' "$name")
check "healthcheck passes while claude runs" 0 "$(rc engine exec "$name" sh -c "$hc")"
# Twice: start.sh falls back from 'claude --continue' to a fresh 'claude'
engine exec "$name" pkill -x claude || true; sleep 3
engine exec "$name" pkill -x claude || true; sleep 3
check "healthcheck fails once claude exits" 1 "$(rc engine exec "$name" sh -c "$hc")"
check "tmux session survives in the fallback shell" 0 "$(rc engine exec "$name" tmux has-session -t main)"
engine exec "$name" tmux kill-session -t main; sleep 8
check "start.sh ends with the tmux session" yes "$(engine logs "$name" 2>&1 | grep "session 'main' ended" >/dev/null && echo yes || echo no)"

name="$prefix-apikey"; created="$created $name"
engine run -d --name "$name" --user "$PUID:$PGID" -e ANTHROPIC_API_KEY=e2e-dummy-key "$IMAGE" >/dev/null; sleep 10
check "API key disables Remote Control" "claude --continue" "$(engine exec "$name" pgrep -xa claude | cut -d' ' -f2-)"
engine stop -t 10 "$name" >/dev/null
check "clean stop" 0 "$(engine inspect -f '{{.State.ExitCode}}' "$name")"

echo "== shells tested:${tested:- none}"
if [ "$failed" -eq 0 ]; then echo "All tests passed"; else echo "$failed test(s) failed"; exit 1; fi
