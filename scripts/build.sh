#!/bin/sh
# Build the image. Usage: scripts/build.sh [--platform linux/amd64]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

set -- build -t "$IMAGE" "$@"
if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then set -- "$@" --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION"; fi
# Podman's default OCI format drops HEALTHCHECK
if is_podman; then set -- "$@" --format docker; fi
engine "$@" "$ROOT"
