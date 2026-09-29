#!/bin/sh
# Start the container. Usage: scripts/run.sh [--replace] [--name <instance>]
# --name runs an extra instance on the same DATA_DIR (set CONTINUE=false for it to start fresh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

replace=false
while [ $# -gt 0 ]; do
  case $1 in
    --replace) replace=true ;;
    --name)
      [ $# -ge 2 ] || {
        echo "--name needs a value" >&2
        exit 1
      }
      CONTAINER_NAME=$2
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done
data=$(abs_path "${DATA_DIR:-./data}")
uid=${PUID:-1000} gid=${PGID:-1000}
mkdir -p "$data"

if engine container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  [ "$replace" = true ] || {
    echo "Container '$CONTAINER_NAME' exists; use --replace to recreate it" >&2
    exit 1
  }
  engine rm -f "$CONTAINER_NAME" >/dev/null
fi

# Env file rather than -e NAME: sudo drops the caller's environment; values also stay out of the process list
envfile=$(mktemp)
trap 'rm -f "$envfile"' EXIT
for v in $CONTAINER_ENV; do
  eval "[ -z \"\${$v+x}\" ] || printf '%s=%s\n' $v \"\$$v\""
done >"$envfile"
# Nothing in the image needs Linux capabilities or setuid escalation; drop both
set -- run -d --name "$CONTAINER_NAME" --hostname "$CONTAINER_NAME" --restart unless-stopped \
  --user "$uid:$gid" --cap-drop ALL --security-opt no-new-privileges \
  -v "$data:/data" --env-file "$envfile"
# Rootless Podman: map the host user to PUID/PGID so mounted files keep their owner
if is_podman && [ "$(id -u)" != 0 ]; then set -- "$@" --userns "keep-id:uid=$uid,gid=$gid"; fi
engine "$@" "$IMAGE" >/dev/null
echo "Started '$CONTAINER_NAME' — attach with scripts/attach.sh --name $CONTAINER_NAME"
