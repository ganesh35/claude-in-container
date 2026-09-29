#!/bin/sh
# CI entrypoint. Used by TeamCity; run it yourself before opening a PR. Fastest checks first; test.sh then lints,
# builds, scans the image and runs the end-to-end tests, stopping at the first failing stage.
set -eu
dir=$(dirname "$0")
sh "$dir/compat.sh"
sh "$dir/security.sh"
exec sh "$dir/test.sh"
