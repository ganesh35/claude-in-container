#!/bin/sh
set -eu

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

# Resume the last conversation, else start fresh; drop to a shell when Claude exits so the session survives
tmux new-session -d -s main -c /workspace -e "RC_NAME=$name" "$claude --continue || $claude; exec bash"
echo "Claude started in tmux session 'main'"

# Stay alive while the session exists; exit lets the restart policy start a fresh one
trap 'tmux kill-server 2>/dev/null; exit 0' TERM INT
while tmux has-session -t main 2>/dev/null; do
  sleep 5 & wait $!
done
echo "tmux session 'main' ended"
