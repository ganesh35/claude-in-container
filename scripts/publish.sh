#!/bin/sh
# Build and push the image to GHCR (Docker buildx only; run from CI). Usage: GHCR_TOKEN=... scripts/publish.sh
# Tags: the Claude Code version baked into the image, and latest. PLATFORMS defaults to linux/amd64.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

image=${PUBLISH_IMAGE:-ghcr.io/ganesh35/claude-in-container}
platforms=${PLATFORMS:-linux/amd64}
version=${CLAUDE_CODE_VERSION:-$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$ROOT/Dockerfile")}
[ -n "${GHCR_TOKEN:-}" ] || { echo "GHCR_TOKEN is not set" >&2; exit 1; }
is_podman && { echo "publish.sh needs Docker buildx" >&2; exit 1; }
user=${image#ghcr.io/}; user=${user%%/*}

# Token reaches docker on stdin only, never as an argument
printf '%s' "$GHCR_TOKEN" | engine login ghcr.io -u "$user" --password-stdin
trap 'engine logout ghcr.io >/dev/null 2>&1 || true' EXIT

# Multi-platform pushes need the docker-container driver; single-platform works with the default builder
set -- build --platform "$platforms" --push
case $platforms in *,*)
  engine buildx inspect cic-publish >/dev/null 2>&1 || engine buildx create --name cic-publish --driver docker-container >/dev/null
  set -- "$@" --builder cic-publish ;;
esac
# No provenance/SBOM attestations: they add unknown/unknown entries to the manifest list that confuse Unraid's update check
engine buildx "$@" --provenance=false --sbom=false \
  --build-arg "CLAUDE_CODE_VERSION=$version" -t "$image:$version" -t "$image:latest" "$ROOT"
echo "Published $image:$version and $image:latest ($platforms)"
