# shellcheck shell=bash
# Shared setup for scripts/*.sh — sourced, not executed
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # optional, user-provided
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

# CONTAINER_ENGINE may hold a prefix, e.g. "sudo docker" on hosts where docker needs root
if [ -n "${CONTAINER_ENGINE:-}" ]; then read -ra ENGINE <<< "$CONTAINER_ENGINE"
elif command -v docker >/dev/null; then ENGINE=(docker)
elif command -v podman >/dev/null; then ENGINE=(podman)
else echo "Neither docker nor podman found" >&2; exit 1
fi
IMAGE="${IMAGE:-claude-in-container:local}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-in-container}"

# Last word of the engine command; no negative index, macOS ships bash 3.2
is_podman() { [[ "${ENGINE[${#ENGINE[@]}-1]}" == podman ]]; }
# Relative paths in .env are relative to the repo root
abs_path() { [[ "$1" == /* ]] && echo "$1" || echo "$ROOT/${1#./}"; }
