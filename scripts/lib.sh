# shellcheck shell=sh
# zsh does not split unquoted variables; POSIX mode keeps every list loop in scripts/ working
[ -z "${ZSH_VERSION:-}" ] || emulate sh
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
# Variables passed into the container when set (by run.sh; compose.yaml lists the same names)
# shellcheck disable=SC2034 # used by run.sh
CONTAINER_ENV="REMOTE_CONTROL_NAME REMOTE_CONTROL_MODE ANTHROPIC_API_KEY CONTINUE ROUTINES GH_VERSION YQ_VERSION JQ_VERSION TERRAFORM_VERSION AWSCLI_VERSION NPM_TOOLS UV_TOOLS"

# eval splits ENGINE into words in every shell, including zsh (no implicit word splitting)
engine() { eval "$ENGINE" '"$@"'; }
is_podman() { case $ENGINE in *podman) return 0 ;; *) return 1 ;; esac; }
# Relative paths in .env are relative to the repo root
abs_path() { case $1 in /*) echo "$1" ;; *) echo "$ROOT/${1#./}" ;; esac; }
