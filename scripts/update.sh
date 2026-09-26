#!/bin/sh
# Pin a Claude Code version in .env, rebuild and recreate. Usage: scripts/update.sh [version] (default: latest)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

[ -f "$ROOT/.env" ] || { echo "No .env — run: cp .env.example .env" >&2; exit 1; }
# npm from the existing image, so the host needs no Node
version=${1:-$(engine run --rm --entrypoint npm "$IMAGE" view @anthropic-ai/claude-code version)}
if [ "$version" = "${CLAUDE_CODE_VERSION:-}" ]; then echo "Already on Claude Code $version"; exit 0; fi

if grep -q '^CLAUDE_CODE_VERSION=' "$ROOT/.env"; then
  sed -i.bak "s/^CLAUDE_CODE_VERSION=.*/CLAUDE_CODE_VERSION=$version/" "$ROOT/.env" && rm "$ROOT/.env.bak"
else
  echo "CLAUDE_CODE_VERSION=$version" >> "$ROOT/.env"
fi
echo "Updating Claude Code ${CLAUDE_CODE_VERSION:-?} -> $version"
CLAUDE_CODE_VERSION=$version
export CLAUDE_CODE_VERSION
"$ROOT/scripts/build.sh"
"$ROOT/scripts/run.sh" --replace
