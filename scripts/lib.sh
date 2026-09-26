# shellcheck shell=sh
# Shared setup for scripts/*.sh — sourced after the caller sets ROOT
# pipefail where supported (POSIX 2024; dash lacks it)
# shellcheck disable=SC3040 # guarded by the support check
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
# shellcheck disable=SC1091 # optional, user-provided
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

# CONTAINER_ENGINE may hold a prefix, e.g. "sudo docker" on hosts where docker needs root
if [ -n "${CONTAINER_ENGINE:-}" ]; then ENGINE=$CONTAINER_ENGINE
elif command -v docker >/dev/null; then ENGINE=docker
elif command -v podman >/dev/null; then ENGINE=podman
else echo "Neither docker nor podman found" >&2; exit 1
fi
IMAGE="${IMAGE:-claude-in-container:local}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-in-container}"

# eval splits ENGINE into words in every shell, including zsh (no implicit word splitting)
engine() { eval "$ENGINE" '"$@"'; }
is_podman() { case $ENGINE in *podman) return 0 ;; *) return 1 ;; esac; }
# Relative paths in .env are relative to the repo root
abs_path() { case $1 in /*) echo "$1" ;; *) echo "$ROOT/${1#./}" ;; esac; }
