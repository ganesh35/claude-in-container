#!/bin/sh
# CI entrypoint (lint, then the full end-to-end suite). Used by TeamCity; run it yourself before opening a PR.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
sh "$ROOT/scripts/lint.sh"
sh "$ROOT/scripts/test.sh"
