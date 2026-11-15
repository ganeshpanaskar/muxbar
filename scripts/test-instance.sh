#!/bin/bash
# Isolated Muxbar for tests: its own home (sockets, state, logs), tmux server (`tmux -L`), bundle id
# and Dock tile. It never takes focus and only records notifications. The installed Muxbar and the
# user's sessions are never touched.
#
#   scripts/test-instance.sh start      build/MuxbarTest.app must exist (make bundle-test)
#   scripts/test-instance.sh stop
#   scripts/test-instance.sh restart
#   scripts/test-instance.sh cli <command> [--key value ...]
#   scripts/test-instance.sh pid | env
#   MUXBAR_TEST_INTERACTIVE=1 scripts/test-instance.sh restart   to try it by hand: its window comes
#                                                                   forward when clicked (tests: unset)
set -uo pipefail
cd "$(dirname "$0")/.."

export MUXBAR_HOME=${MUXBAR_HOME:-/tmp/mbx-e2e}
export MUXBAR_TMUX_SOCKET=${MUXBAR_TMUX_SOCKET:-muxbar-e2e}
export MUXBAR_TEST=1
# Hook state files of test sessions (on every host), and fast polling for lag measurements.
export MUXBAR_HOOK_STATE_DIR=${MUXBAR_HOOK_STATE_DIR:-/tmp/muxbar-e2e-state}
export MUXBAR_FAST_POLL=${MUXBAR_FAST_POLL:-2}
# Hook install/uninstall can only reach stub agent CLIs and throwaway folders, never the user's
# real Claude or Codex configuration.
export MUXBAR_TEST_AGENT_BIN=${MUXBAR_TEST_AGENT_BIN:-/tmp/muxbar-e2e-stub/bin}
export MUXBAR_TEST_CODEX_HOME=${MUXBAR_TEST_CODEX_HOME:-/tmp/muxbar-e2e-codex-home}
export MUXBAR_TEST_PLUGIN_DIR=${MUXBAR_TEST_PLUGIN_DIR:-/tmp/muxbar-e2e-plugin-installed}
APP=${TEST_APP:-$PWD/build/MuxbarTest.app}
BIN="$APP/Contents/MacOS/Muxbar"

cli() { perl -e 'alarm 90; exec @ARGV' "$BIN" --cli "$@"; }
running() { cli info >/dev/null 2>&1; }

start() {
  [ -x "$BIN" ] || { echo "no test app at $APP (run: make bundle-test)" >&2; exit 2; }
  if running; then echo "test instance already running (pid $(cli info | sed -n 's/.* pid=\([0-9]*\).*/\1/p'))"; return 0; fi
  mkdir -p "$MUXBAR_HOME"; chmod 700 "$MUXBAR_HOME"
  # Exec the binary directly (not `open`) so the environment above reaches the app, in a session
  # of its own (so it outlives this shell) and with SIGHUP at its default, as when launched from
  # Finder. Not `nohup`: an ignored SIGHUP is inherited by every pane's ssh and its proxy, which
  # then can't be hung up.
  perl -e 'use POSIX (); POSIX::setsid(); $SIG{HUP} = "DEFAULT"; $SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' \
    "$BIN" >> "$MUXBAR_HOME/stdout.log" 2>&1 < /dev/null &
  for _ in $(seq 40); do running && break; sleep 0.5; done
  running || { echo "test instance didn't start; see $MUXBAR_HOME/logs/app.log" >&2; exit 1; }
  echo "test instance running: $(cli info)"
}

stop() {
  running || { echo "test instance not running"; return 0; }
  local pid; pid=$(cli info | sed -n 's/.* pid=\([0-9]*\).*/\1/p')
  cli quit >/dev/null 2>&1
  for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$pid" 2>/dev/null; then echo "test instance $pid didn't quit" >&2; exit 1; fi
  echo "test instance stopped ($pid)"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  cli) shift; cli "$@" ;;
  pid) cli info | sed -n 's/.* pid=\([0-9]*\).*/\1/p' ;;
  env) echo "MUXBAR_HOME=$MUXBAR_HOME MUXBAR_TMUX_SOCKET=$MUXBAR_TMUX_SOCKET MUXBAR_TEST=1 BIN=$BIN" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
