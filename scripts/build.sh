#!/usr/bin/env bash
# Build the image. Usage: scripts/build.sh [--platform linux/amd64]
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

args=(build -t "$IMAGE" "$@")
[ -n "${CLAUDE_CODE_VERSION:-}" ] && args+=(--build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION")
# Podman's default OCI format drops HEALTHCHECK
is_podman && args+=(--format docker)
"${ENGINE[@]}" "${args[@]}" "$ROOT"
