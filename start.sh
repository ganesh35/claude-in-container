#!/usr/bin/env bash
set -euo pipefail

name="${REMOTE_CONTROL_NAME:-$(hostname)}"
# Compose passes unset .env values as empty strings, which Claude would treat as a (bad) key
[ -z "${ANTHROPIC_API_KEY:-}" ] && unset ANTHROPIC_API_KEY

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # Remote Control requires a claude.ai subscription login; API-key sessions are terminal-only
  echo "ANTHROPIC_API_KEY set: Remote Control disabled, attach via tmux"
  claude=(claude)
else
  claude=(claude --remote-control "$name")
  echo "Remote Control session name: $name"
fi

# Resume the last conversation, else start fresh; drop to a shell when Claude exits so the session survives
tmux new-session -d -s main -c /workspace \
  "${claude[*]@Q} --continue || ${claude[*]@Q}; exec bash"
echo "Claude started in tmux session 'main'"

# Stay alive while the session exists; exit lets the restart policy start a fresh one
trap 'tmux kill-server 2>/dev/null; exit 0' TERM INT
while tmux has-session -t main 2>/dev/null; do
  sleep 5 & wait $!
done
echo "tmux session 'main' ended"
