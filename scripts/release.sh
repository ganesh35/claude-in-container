#!/bin/sh
# GitHub releases for the published image (CI only; needs curl, jq, git and GITHUB_TOKEN).
# Usage: scripts/release.sh changed   exit 0 if image files changed since the latest release (or there is none), else 1
#        scripts/release.sh create    release HEAD: v<claude-version>, or v<claude-version>-N for an image-only change
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
repo=${RELEASE_REPO:-ganesh35/claude-in-container}
[ -n "${GITHUB_TOKEN:-}" ] || { echo "GITHUB_TOKEN is not set" >&2; exit 2; }
api() { # method path [curl args...]; the token goes in a header file, never on the command line
  m=$1 p=$2; shift 2
  hdr=$(mktemp); trap 'rm -f "$hdr"' EXIT
  printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$hdr"
  curl -fsSL --proto '=https' -X "$m" -H @"$hdr" -H 'Accept: application/vnd.github+json' "$@" "https://api.github.com/repos/$repo/$p"
  rm -f "$hdr"; trap - EXIT
}
version=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$ROOT/Dockerfile")
head=$(git -C "$ROOT" rev-parse HEAD)
latest=$(api GET "releases?per_page=1" | jq -r '.[0].tag_name // empty')

case ${1:-} in
  changed)
    [ -n "$latest" ] || exit 0
    since=$(api GET "commits/$latest" | jq -r .sha)
    git -C "$ROOT" cat-file -e "$since^{commit}" 2>/dev/null || git -C "$ROOT" fetch -q origin "$since"
    # Everything that goes into the image; docs, tests and CI changes don't warrant a release
    if git -C "$ROOT" diff --quiet "$since" "$head" -- Dockerfile start.sh install-tools.sh routine.sh keys; then
      echo "No image change since $latest"; exit 1
    fi
    echo "Image changed since $latest" ;;
  create)
    tags=$(api GET "releases?per_page=100" | jq -r '.[].tag_name')
    if ! printf '%s\n' "$tags" | grep -qx "v$version"; then
      tag="v$version"
    else
      n=$(printf '%s\n' "$tags" | sed -n "s/^v$version-\([0-9]*\)$/\1/p" | sort -n | tail -1)
      tag="v$version-$(( ${n:-0} + 1 ))"
    fi
    body=$(jq -n --arg t "$tag" --arg c "$head" \
      '{tag_name: $t, target_commitish: $c, name: ("claude-in-container " + $t), generate_release_notes: true}')
    api POST releases -d "$body" | jq -r '"Released \(.tag_name): \(.html_url)"' ;;
  *) echo "usage: $0 changed|create" >&2; exit 2 ;;
esac
