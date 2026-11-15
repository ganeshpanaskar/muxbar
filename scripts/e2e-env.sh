# Shared by scripts/e2e.sh and scripts/e9-status.sh: which Muxbar the tests drive and which tmux
# server they use. Source it from the repo root.
#
#   TARGET=test (default)  the isolated test instance (scripts/test-instance.sh): own home, control
#                          socket, state, logs and tmux server (`tmux -L muxbar-e2e`), so tests can't
#                          see or touch the installed Muxbar or the user's sessions.
#   TARGET=user            the installed ~/Applications/Muxbar.app and the default tmux server
#                          (only when the user asks for it).
TARGET=${TARGET:-test}
if [ "$TARGET" = test ]; then
  export MUXBAR_HOME=${MUXBAR_HOME:-/tmp/mbx-e2e}
  export MUXBAR_TMUX_SOCKET=${MUXBAR_TMUX_SOCKET:-muxbar-e2e}
  export MUXBAR_TEST=1
  export MUXBAR_HOOK_STATE_DIR=${MUXBAR_HOOK_STATE_DIR:-/tmp/muxbar-e2e-state}
  M=${M:-$PWD/build/MuxbarTest.app/Contents/MacOS/Muxbar}
  STATE_FILE="$MUXBAR_HOME/support/state.json"
  CM_DIR="$MUXBAR_HOME/cm"
  TSOCK=$MUXBAR_TMUX_SOCKET
else
  M=${M:-$HOME/Applications/Muxbar.app/Contents/MacOS/Muxbar}
  STATE_FILE="$HOME/Library/Application Support/Muxbar/state.json"
  CM_DIR="$HOME/.muxbar/cm"
  TSOCK=""
fi

# Every tmux call in the tests, local or in scripts sent to a host, goes to the app's tmux server.
if [ -n "$TSOCK" ]; then
  tmux() { command tmux -L "$TSOCK" "$@"; }
  TMUX_FN="tmux() { command tmux -L '$TSOCK' \"\$@\"; }"
else
  TMUX_FN=":"
fi
# How the app's attach clients look in `ps` (for the simulated VPN drop).
ATTACH_L_LOCAL=${TSOCK:+-L $TSOCK }
ATTACH_L_REMOTE=${TSOCK:+-L \'$TSOCK\' }

app_start() {
  if [ "$TARGET" = test ]; then scripts/test-instance.sh start >/dev/null
  else open "$HOME/Applications/Muxbar.app"; fi
  local i; for i in $(seq 40); do "$M" --cli info >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

app_quit() {
  if [ "$TARGET" = test ]; then scripts/test-instance.sh stop >/dev/null
  else "$M" --cli quit >/dev/null 2>&1; sleep 2; fi
}
