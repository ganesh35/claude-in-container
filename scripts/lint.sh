#!/bin/sh
# Lint shell scripts and the Dockerfile using pinned linter images (nothing to install)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

cd "$ROOT"
# Container variables are repeated in .env.example, compose.yaml and the Unraid template; fail on any drift
tpl=unraid/claude-in-container.xml drift=0
for v in $CONTAINER_ENV; do
  env=$(sed -n "s/^$v=//p" .env.example | tr -d '"')
  def=$(sed -n "s/.*Target=\"$v\" Default=\"\([^\"]*\)\".*/\1/p" "$tpl")
  val=$(sed -n "s/.*Target=\"$v\" .*>\([^<]*\)<\/Config>.*/\1/p" "$tpl")
  if [ "$env" != "$def" ] || [ "$env" != "$val" ]; then
    echo "Drift: $v is '$env' in .env.example, template Default '$def', value '$val'" >&2; drift=1
  fi
  grep -qw "$v" compose.yaml || { echo "Drift: $v missing from compose.yaml" >&2; drift=1; }
  grep -q "Target=\"$v\"" "$tpl" || { echo "Drift: $v missing from $tpl" >&2; drift=1; }
done
[ "$drift" -eq 0 ] || exit 1
echo "No drift between .env.example, compose.yaml and $tpl"

# Files are streamed in, not mounted, so this also works where the engine can't see the repo path
tar -c start.sh install-tools.sh scripts | engine run --rm -i -e LANG=C.UTF-8 --entrypoint sh koalaman/shellcheck-alpine:v0.11.0@sha256:9955be09ea7f0dbf7ae942ac1f2094355bb30d96fffba0ec09f5432207544002 \
  -c 'mkdir /src && cd /src && tar -x && shellcheck -x start.sh install-tools.sh scripts/*.sh'
# DL3008: apt versions are not pinned; Debian drops old ones, and the digest-pinned base keeps builds reproducible
engine run --rm -i hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d hadolint --ignore DL3008 - < Dockerfile
echo "Lint passed"
