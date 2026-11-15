#!/bin/bash
# Fills the test instance (scripts/test-instance.sh) with demo sessions for screenshots of the UI:
# stand-in agents (scripts/fake-agent, real hook events, no model) working, waiting, finished,
# asleep, a shell, and two ended sessions on a remote host. The installed Muxbar isn't touched.
#
#   scripts/ux-demo.sh [remote-host]     default remote: devbox ("" = this Mac only)
#   scripts/ux-demo.sh --clean [remote-host]
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --clean ]; then REMOTE=${2-devbox}; else REMOTE=${1-devbox}; fi
mb() { scripts/test-instance.sh cli "$@"; }
STATE_DIR=/tmp/muxbar-e2e-state
HOOK=/tmp/muxbar-e2e-plugin/plugins/muxbar-status/bin/muxbar-hook
FAKE=/tmp/muxbar-e2e-fake/bin
NAMES="api-index api-eval release-notes bench-runner docs-writer scratch vector-search data-prep ui-review web-app"

rsh() { if [ "$1" = local ]; then shift; /bin/sh -c "$*"; else local h=$1; shift; ssh -o BatchMode=yes "$h" "$*" 2>/dev/null; fi; }
tm() { local h=$1; shift; rsh "$h" "tmux -L muxbar-e2e $*"; }
idof() { mb list --json | python3 -c "import json,sys; r=[s['id'] for s in json.load(sys.stdin)['result'] if s['host']=='$1' and s['name']=='$2' and not s['ended']]; print(r[0] if r else '')"; }
say() { local id; id=$(idof "$1" "$2"); [ -n "$id" ] || return; tm "$1" "send-keys -t '$id' -l '$3'"; sleep 0.3; tm "$1" "send-keys -t '$id' Enter"; }
agent() { echo "env MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK $FAKE/$1"; }

clean() {
  for n in $NAMES; do
    for h in local ${REMOTE:+$REMOTE}; do id=$(idof "$h" "$n"); [ -n "$id" ] && mb kill --host "$h" --id "$id" --yes >/dev/null 2>&1; done
  done
  for h in local ${REMOTE:+$REMOTE}; do mb dismiss-ended --host "$h" >/dev/null 2>&1; done
  mb group-delete --host local --name api >/dev/null 2>&1 || true
}

if [ "${1:-}" = --clean ]; then clean; echo "demo sessions removed"; exit 0; fi

scripts/test-instance.sh start >/dev/null
for h in local ${REMOTE:+$REMOTE}; do scripts/e2e-deploy.sh "$h" >/dev/null 2>&1; done
[ -n "$REMOTE" ] && mb hosts-add --host "$REMOTE" >/dev/null 2>&1
clean
mkdir -p /tmp/muxbar-demo
mb group-create --host local --name api >/dev/null 2>&1

mb new --host local --name api-index --dir /tmp/muxbar-demo --group api --cmd "$(agent claude)" --no-attach >/dev/null
mb new --host local --name api-eval --dir /tmp/muxbar-demo --group api --cmd "$(agent codex)" --no-attach >/dev/null
mb new --host local --name release-notes --dir /tmp/muxbar-demo --cmd "$(agent claude)" --no-attach >/dev/null
mb new --host local --name bench-runner --dir /tmp/muxbar-demo --cmd "$(agent codex)" --no-attach >/dev/null
mb new --host local --name docs-writer --dir /tmp/muxbar-demo --cmd "$(agent claude)" --no-attach >/dev/null
mb new --host local --name scratch --dir /tmp/muxbar-demo --no-attach >/dev/null
if [ -n "$REMOTE" ]; then
  mb new --host "$REMOTE" --name vector-search --dir /tmp --cmd "$(agent claude)" --no-attach >/dev/null
  mb new --host "$REMOTE" --name data-prep --dir /tmp --no-attach >/dev/null
  mb new --host "$REMOTE" --name ui-review --dir /tmp --cmd "$(agent claude)" --no-attach >/dev/null
  mb new --host "$REMOTE" --name web-app --dir /tmp --cmd "$(agent codex)" --no-attach >/dev/null
fi
sleep 3
say local api-index "work 1800 Rebuilding the shard index"
say local api-eval "ask"
say local release-notes "reply Drafted the release notes: 4 features and 6 fixes, grouped by area. Ready for your review."
say local bench-runner "reply p99 latency is 41 ms at 2k QPS; the cold-cache run is 3x slower, details in bench.md."
say local docs-writer "reply Updated the README sections for New Session and Resume all."
if [ -n "$REMOTE" ]; then
  say "$REMOTE" vector-search "work 1800 Building the vector index"
  say "$REMOTE" ui-review "reply Done."
  say "$REMOTE" web-app "reply Done."
fi
sleep 4
mb refresh --host local >/dev/null
mb mark-read --host local --id bench-runner >/dev/null 2>&1
mb mark-read --host local --id docs-writer >/dev/null 2>&1
mb sleep --host local --id docs-writer >/dev/null 2>&1
if [ -n "$REMOTE" ]; then
  # Two sessions that ended (as after the host restarted): their tmux sessions go away.
  for n in ui-review web-app; do id=$(idof "$REMOTE" "$n"); [ -n "$id" ] && tm "$REMOTE" "kill-session -t '$id'"; done
  mb refresh --host "$REMOTE" >/dev/null
fi
echo "demo sessions ready"
