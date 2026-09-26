#!/bin/sh
set -eu

# The single mount must be fully writable by the container user
[ -w /data ] || { echo "/data is not writable by uid $(id -u):$(id -g); fix the owner of the mounted folder" >&2; exit 1; }
mkdir -p "$HOME"

# CONTINUE=false starts fresh: instances sharing /data would otherwise all resume the same conversation
case ${CONTINUE:-true} in
  true) resume=true ;;
  false) resume=false ;;
  *) echo "CONTINUE must be true or false, got '$CONTINUE'" >&2; exit 1 ;;
esac

# A checksum mismatch (exit 2) stops the container; any other installer problem is logged and Claude starts anyway
rc=0
install-tools.sh || rc=$?
if [ "$rc" -eq 2 ]; then exit 2; fi
if [ "$rc" -ne 0 ]; then echo "tools: installer exited $rc, starting Claude without all tools" >&2; fi

name=${REMOTE_CONTROL_NAME:-$(hostname)}
# Compose passes unset .env values as empty strings, which Claude would treat as a (bad) key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then unset ANTHROPIC_API_KEY; fi

# The session name reaches tmux as an env var, so no quoting of user input into the command string
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # Remote Control requires a claude.ai subscription login; API-key sessions are terminal-only
  echo "ANTHROPIC_API_KEY set: Remote Control disabled, attach via tmux"
  claude='claude'
else
  echo "Remote Control session name: $name"
  # shellcheck disable=SC2016 # expanded by tmux's shell, not here
  claude='claude --remote-control "$RC_NAME"'
fi

# Resume the last conversation (falling back to a fresh one) or start fresh; drop to a shell when Claude exits
if [ "$resume" = true ]; then cmd="$claude --continue || $claude"; else cmd=$claude; fi
tmux new-session -d -s main -c /data -e "RC_NAME=$name" "$cmd; exec bash"
echo "Claude started in tmux session 'main'"

# Stay alive while the session exists; exit lets the restart policy start a fresh one
trap 'tmux kill-server 2>/dev/null; exit 0' TERM INT
while tmux has-session -t main 2>/dev/null; do
  sleep 5 & wait $!
done
echo "tmux session 'main' ended"
