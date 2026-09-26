#!/bin/sh
# Start the container. Usage: scripts/run.sh [--replace]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

replace=${1:-}
workspace=$(abs_path "${WORKSPACE_DIR:-./workspace}")
home=$(abs_path "${CLAUDE_HOME_DIR:-./home}")
uid=${PUID:-1000} gid=${PGID:-1000}
mkdir -p "$workspace" "$home"

if engine container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  [ "$replace" = --replace ] || { echo "Container '$CONTAINER_NAME' exists; use --replace to recreate it" >&2; exit 1; }
  engine rm -f "$CONTAINER_NAME" >/dev/null
fi

# Names only for -e: values come from .env via lib.sh, so the key never shows up in the process list
set -- run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_NAME" --restart unless-stopped \
  --user "$uid:$gid" -v "$workspace:/workspace" -v "$home:/home/node" \
  -e REMOTE_CONTROL_NAME -e ANTHROPIC_API_KEY
# Rootless Podman: map the host user to PUID/PGID so mounted files keep their owner
if is_podman && [ "$(id -u)" != 0 ]; then set -- "$@" --userns "keep-id:uid=$uid,gid=$gid"; fi
engine "$@" "$IMAGE" >/dev/null
echo "Started '$CONTAINER_NAME' — attach with scripts/attach.sh"
