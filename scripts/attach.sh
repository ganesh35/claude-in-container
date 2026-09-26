#!/bin/sh
# Attach to Claude's tmux session; detach with Ctrl-b d
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

engine exec -it "$CONTAINER_NAME" tmux new -A -s main
