#!/usr/bin/env bash
# Attach to Claude's tmux session; detach with Ctrl-b d
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

"${ENGINE[@]}" exec -it "$CONTAINER_NAME" tmux new -A -s main
