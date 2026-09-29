#!/bin/sh
# Breaking-change check on committed code: the public contract (container variables, template settings, scripts,
# HOME and the working directory) must keep everything the latest release had. A commit since that release whose
# message says "BREAKING CHANGE" allows removals. Usage: scripts/compat.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# Release tags live on GitHub, and CI checkouts may lack them; the repo is public, so no token is needed
git fetch -q --tags "https://github.com/${RELEASE_REPO:-ganesh35/claude-in-container}.git"
base=$(git describe --tags --abbrev=0 --match 'v*' HEAD)

contract() { # rev: one line per public item
  git show "$1:scripts/lib.sh" | sed -n 's/^CONTAINER_ENV="\(.*\)"/\1/p' | tr ' ' '\n' | sed 's/^/variable /'
  git show "$1:unraid/claude-in-container.xml" | sed -n 's/.*Target="\([^"]*\)".*/template setting \1/p'
  git ls-tree --name-only "$1" scripts/ | sed 's/^/script /'
  git show "$1:Dockerfile" | sed -n 's/^ENV HOME=/HOME /p; s/^WORKDIR /working directory /p'
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
contract "$base" | sort -u >"$tmp/base"
contract HEAD | sort -u >"$tmp/head"
removed=$(comm -23 "$tmp/base" "$tmp/head")
if [ -z "$removed" ]; then
  echo "No breaking change since $base"
elif git log --format=%B "$base..HEAD" | grep -q 'BREAKING CHANGE'; then
  printf 'Breaking changes since %s, declared with BREAKING CHANGE:\n%s\n' "$base" "$removed"
else
  printf 'Breaking changes since %s (add a BREAKING CHANGE: footer to the commit if intended):\n%s\n' "$base" "$removed" >&2
  exit 1
fi
