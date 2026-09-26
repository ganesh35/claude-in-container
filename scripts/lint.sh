#!/bin/sh
# Lint shell scripts and the Dockerfile using pinned linter images (nothing to install)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# Files are streamed in, not mounted, so this also works where the engine can't see the repo path
cd "$ROOT"
tar -c start.sh install-tools.sh scripts | engine run --rm -i -e LANG=C.UTF-8 --entrypoint sh koalaman/shellcheck-alpine:v0.11.0 \
  -c 'mkdir /src && cd /src && tar -x && shellcheck -x start.sh install-tools.sh scripts/*.sh'
# DL3008: apt versions are not pinned; Debian drops old ones, and the digest-pinned base keeps builds reproducible
engine run --rm -i hadolint/hadolint:v2.15.1 hadolint --ignore DL3008 - < Dockerfile
echo "Lint passed"
