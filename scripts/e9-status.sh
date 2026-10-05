#!/bin/bash
# E9: status accuracy against a real Claude Code session in local tmux.
# Drives Claude through idle → working → idle → waiting (permission) → idle → exited, takes 20
# samples, and compares Muxbar's reported status with the state the script put Claude in.
# Each sample's pane text is saved so mismatches can be reviewed (and promoted to fixtures).
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
M="$HOME/Applications/Muxbar.app/Contents/MacOS/Muxbar"
mb() { perl -e 'alarm 90; exec @ARGV' "$M" --cli "$@"; }
OUT=e2e-artifacts/e9-status
rm -rf "$OUT"; mkdir -p "$OUT"
NAME=muxbar-e2e-claude
DIRC=/tmp/muxbar-e2e-claude
mkdir -p "$DIRC"

if ! tmux has-session -t "=$NAME" 2>/dev/null; then
  tmux new-session -d -s "$NAME" -x 120 -y 40 -c "$DIRC" "env CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 zsh -lc 'claude; exec zsh -l'"
else
  tmux send-keys -t "=$NAME:" -l 'claude'; tmux send-keys -t "=$NAME:" Enter
fi
ID=$(tmux list-sessions -F '#{session_id} #{session_name}' | awk -v n="$NAME" '$2==n{print $1}')
keys() { tmux send-keys -t "$ID" "$@"; }
text() { tmux send-keys -t "$ID" -l "$1"; sleep 0.4; tmux send-keys -t "$ID" Enter; }
screen() { tmux capture-pane -p -J -t "$ID"; }
wait_screen() { local t=$1 pat=$2; for _ in $(seq "$t"); do screen | grep -q -- "$pat" && return 0; sleep 1; done; return 1; }

n=0; ok=0; unknown=0; wrong=0
sample() { # sample <expected>
  n=$((n + 1))
  local f; f=$(printf '%s/%02d' "$OUT" "$n")
  mb refresh --host local >/dev/null
  local got; got=$(mb status --host local --id "$NAME" | tr ' ' '\n' | sed -n 's/^status=//p')
  screen > "$f-pane.txt"
  local verdict
  if [ "$got" = "$1" ]; then verdict=correct; ok=$((ok + 1))
  elif [ "$got" = unknown ]; then verdict=unknown; unknown=$((unknown + 1))
  else verdict=WRONG; wrong=$((wrong + 1)); fi
  printf '%02d\texpected=%s\tgot=%s\t%s\n' "$n" "$1" "$got" "$verdict" | tee -a "$OUT/samples.tsv"
  mv "$f-pane.txt" "$f-$1-got-$got.txt"
}

wait_screen 30 "auto mode on\|manual mode on\|accept edits\|plan mode" || { echo "claude didn't start"; exit 1; }
sleep 2
for _ in 1 2 3 4; do sample idle; sleep 1; done

text 'Write a 700 word story about a lighthouse keeper and a storm. Do not use any tools.'
wait_screen 15 "…" ; sleep 1
for _ in 1 2 3 4 5 6; do sample working; sleep 1.5; done

wait_screen 120 " for [0-9]*s" || true
sleep 2
for _ in 1 2; do sample idle; sleep 1; done

# Switch to manual mode so Claude asks permission for a shell command.
for _ in 1 2 3 4; do screen | grep -q "manual mode on" && break; keys BTab; sleep 1; done
text 'Run this exact bash command: touch /tmp/muxbar-e2e-claude/e9.txt'
wait_screen 60 "Do you want to proceed" || true
for _ in 1 2 3 4; do sample waiting; sleep 1; done

keys Escape; sleep 3
for _ in 1 2; do sample idle; sleep 1; done

text '/exit'; sleep 4
for _ in 1 2; do sample notClaude; sleep 1; done

printf 'samples=%d correct=%d unknown=%d wrong=%d\n' "$n" "$ok" "$unknown" "$wrong" | tee "$OUT/summary.txt"
[ "$wrong" -eq 0 ]
