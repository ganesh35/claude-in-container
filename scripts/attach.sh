#!/bin/sh
# Attach to Claude's tmux session; detach with Ctrl-b d. Usage: scripts/attach.sh [--name <instance>]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

if [ "${1:-}" = --name ]; then CONTAINER_NAME=${2:?--name needs a value}; fi
engine exec -it "$CONTAINER_NAME" tmux new -A -s main
