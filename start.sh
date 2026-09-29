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

# server: one host that starts a new session for each request from the Claude app; session: one named session
mode=${REMOTE_CONTROL_MODE:-session}
case $mode in
  session) ;;
  # 'remote-control --continue' would resume a single old session and exit, not restart the server
  server) resume=false ;;
  *) echo "REMOTE_CONTROL_MODE must be session or server, got '$mode'" >&2; exit 1 ;;
esac

# A failed checksum or signature check (exit 2) stops the container; any other installer problem is logged and Claude starts anyway.
# On a stop during the install, forward the signal and wait: if this shell died first, PID 1 would exit and the kernel
# would SIGKILL the installer before it could release its lock
rc=0
/usr/local/bin/install-tools.sh & ipid=$!
trap 'kill -TERM "$ipid" 2>/dev/null; wait "$ipid" 2>/dev/null; exit 0' TERM INT
wait "$ipid" || rc=$?
trap - TERM INT
if [ "$rc" -eq 2 ]; then exit 2; fi
if [ "$rc" -ne 0 ]; then echo "tools: installer exited $rc, starting Claude without all tools" >&2; fi

name=${REMOTE_CONTROL_NAME:-$(hostname)}
# Compose passes unset .env values as empty strings, which Claude would treat as a (bad) key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then unset ANTHROPIC_API_KEY; fi

# The session name reaches tmux as an env var, so no quoting of user input into the command string
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # Remote Control requires a claude.ai subscription login; API-key sessions are terminal-only
  if [ "$mode" = server ]; then echo "REMOTE_CONTROL_MODE=server needs the subscription login, not ANTHROPIC_API_KEY" >&2; exit 1; fi
  echo "ANTHROPIC_API_KEY set: Remote Control disabled, attach via tmux"
  claude='claude'
elif [ "$mode" = server ]; then
  echo "Remote Control server, session name prefix: $name"
  # shellcheck disable=SC2016 # expanded by tmux's shell, not here
  claude='claude remote-control --remote-control-session-name-prefix "$RC_NAME"'
else
  echo "Remote Control session name: $name"
  # shellcheck disable=SC2016 # expanded by tmux's shell, not here
  claude='claude --remote-control "$RC_NAME"'
fi

# Routines: ROUTINES names a crontab run by supercronic (reloaded when edited); empty = off.
# A missing or invalid file is logged and skipped, so Claude still starts
if [ -n "${ROUTINES:-}" ]; then
  if [ -f "$ROUTINES" ] && /usr/local/bin/supercronic -test "$ROUTINES" >/dev/null 2>&1; then
    /usr/local/bin/supercronic -inotify "$ROUTINES" &
    echo "routines: scheduled from $ROUTINES"
  else
    echo "routines: $ROUTINES is missing or invalid, routines disabled (check it with: supercronic -test $ROUTINES)" >&2
  fi
fi

# Resume the last conversation (falling back to a fresh one) or start fresh; drop to a shell when Claude exits
if [ "$resume" = true ]; then cmd="$claude --continue || $claude"; else cmd=$claude; fi
tmux new-session -d -s main -c /data -e "RC_NAME=$name" "$cmd; exec bash"
echo "Claude started in tmux session 'main'"

# Stay alive while the session exists; exit lets the restart policy start a fresh one
trap 'tmux kill-server 2>/dev/null; exit 0' TERM INT
while tmux has-session -t =main 2>/dev/null; do
  sleep 5 & wait $!
done
echo "tmux session 'main' ended"
