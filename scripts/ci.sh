#!/bin/sh
# CI entrypoint. Used by TeamCity; run it yourself before opening a PR. test.sh lints first and stops if that fails.
set -eu
exec sh "$(dirname "$0")/test.sh"
