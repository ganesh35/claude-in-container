#!/bin/sh
# Runs one headless Claude prompt from /data/routines. Crontab usage: <schedule> routine <prompt...>
# The reply (stdout and stderr) goes to /data/routines-output/<UTC time>-<first words>.md; one summary line to the container log.
set -eu
[ $# -gt 0 ] || { echo "routine: no prompt given" >&2; exit 2; }
out=/data/routines-output
mkdir -p "$out"
slug=$(printf '%s' "$*" | tr -cs 'A-Za-z0-9' '-' | cut -c1-40 | sed 's/^-//; s/-$//')
file="$out/$(date -u +%Y-%m-%dT%H%M%SZ)-$slug.md"
rc=0
cd /data
claude -p --permission-mode auto "$*" > "$file" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then echo "routine: ok -> $file"; else echo "routine: failed (exit $rc) -> $file"; fi
exit "$rc"
