#!/usr/bin/env bash
# Start the container. Usage: scripts/run.sh [--replace]
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

workspace="$(abs_path "${WORKSPACE_DIR:-./workspace}")"
home="$(abs_path "${CLAUDE_HOME_DIR:-./home}")"
uid="${PUID:-1000}" gid="${PGID:-1000}"
mkdir -p "$workspace" "$home"

if "${ENGINE[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  [ "${1:-}" = --replace ] || { echo "Container '$CONTAINER_NAME' exists; use --replace to recreate it" >&2; exit 1; }
  "${ENGINE[@]}" rm -f "$CONTAINER_NAME" >/dev/null
fi

args=(run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_NAME" --restart unless-stopped
  --user "$uid:$gid" -v "$workspace:/workspace" -v "$home:/home/node"
  # Names only: values come from .env via lib.sh, so the key never shows up in the process list
  -e REMOTE_CONTROL_NAME -e ANTHROPIC_API_KEY)
# Rootless Podman: map the host user to PUID/PGID so mounted files keep their owner
if is_podman && [ "$(id -u)" != 0 ]; then args+=(--userns "keep-id:uid=$uid,gid=$gid"); fi
"${ENGINE[@]}" "${args[@]}" "$IMAGE" >/dev/null
echo "Started '$CONTAINER_NAME' — attach with scripts/attach.sh"
