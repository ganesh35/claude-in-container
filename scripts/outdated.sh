#!/bin/sh
# Reports newer versions of pinned tools and the base image. Read-only: makes no changes.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# Runs entirely inside a throwaway Alpine container (3.24.2, digest-pinned) so curl/jq are never required on the host
engine run --rm -i -v "$ROOT:/repo:ro" -e LANG=C.UTF-8 --entrypoint sh docker.io/library/alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 <<'CHECK'
set -eu
apk add -q curl jq >/dev/null
cd /repo

cur() { sed -n "s/^ARG $1=//p; s/^$1=//p" Dockerfile .env.example | head -1 | tr -d '"'; }
gh_latest() { curl -fsSL --proto '=https' --proto-redir '=https' "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name | sed "s/^$2//"; }
npm_latest() { curl -fsSL --proto '=https' --proto-redir '=https' "https://registry.npmjs.org/$1/latest" | jq -r .version; }

row() { # name current latest
  if [ -z "$3" ] || [ "$3" = null ]; then printf '%-14s %-20s %-20s %s\n' "$1" "$2" "?" "COULD NOT CHECK"
  elif [ "$2" = "$3" ]; then printf '%-14s %-20s %-20s %s\n' "$1" "$2" "$3" "up to date"
  else printf '%-14s %-20s %-20s %s\n' "$1" "$2" "$3" "UPDATE AVAILABLE"; fi
}

printf '%-14s %-20s %-20s %s\n' NAME CURRENT LATEST STATUS
row claude-code "$(cur CLAUDE_CODE_VERSION)" "$(npm_latest @anthropic-ai/claude-code || true)"
row supercronic "$(cur SUPERCRONIC_VERSION)" "$(gh_latest aptible/supercronic v || true)"
row uv "$(cur UV_IMAGE | sed -n 's/^.*:\([0-9][0-9.]*\)@.*/\1/p')" "$(gh_latest astral-sh/uv v || true)"
row playwright "$(cur PLAYWRIGHT_VERSION)" "$(npm_latest playwright || true)"
row gh "$(cur GH_VERSION)" "$(gh_latest cli/cli v || true)"
row yq "$(cur YQ_VERSION)" "$(gh_latest mikefarah/yq v || true)"
row jq "$(cur JQ_VERSION)" "$(gh_latest jqlang/jq jq- || true)"
row terraform "$(cur TERRAFORM_VERSION)" "$(curl -fsSL --proto '=https' --proto-redir '=https' https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version || true)"
# grep -m1 (not head -1) would still trip curl's SIGPIPE warning; read the whole file instead
row aws-cli "$(cur AWSCLI_VERSION)" "$(curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p || true)"
for spec in $(sed -n 's/^NPM_TOOLS=//p' .env.example | tr -d '"'); do
  name=${spec%@*}; row "$name" "${spec##*@}" "$(npm_latest "$name" || true)"
done

echo
node_index=$(curl -fsSL --proto '=https' --proto-redir '=https' https://nodejs.org/dist/index.json)
major=$(cur NODE_IMAGE | sed -n 's/.*\/node:\([0-9]*\)\..*/\1/p')
patch=$(echo "$node_index" | jq -r --arg m "v$major." '[.[] | select(.version | startswith($m))][0].version // empty' | tr -d v)
lts=$(echo "$node_index" | jq -r '[.[] | select(.lts != false)][0].version // empty' | tr -d v)
row "node $major.x" "$(cur NODE_IMAGE | sed -n 's/.*\/node:\([0-9.]*\)-.*/\1/p')" "$patch"
if [ -n "$lts" ] && [ "${lts%%.*}" != "$major" ]; then
  echo "Node $major.x is not the newest LTS line; $lts is (base-image switch, not a patch bump)"
fi
CHECK
