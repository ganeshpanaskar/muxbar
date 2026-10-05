#!/bin/bash
# Muxbar end-to-end suite. Drives the *running* app through `Muxbar --cli` (same code as the UI)
# and checks results against tmux on the host and the terminal's own AppleScript view.
#
#   HOST=local    scripts/e2e.sh            all tests for a host
#   HOST=devbox   scripts/e2e.sh E3 E4      selected tests (any ssh alias with tmux)
#   TERMINAL=iterm HOST=local scripts/e2e.sh E3 E4 E7 E8   (E15)
#   TERMINAL=embedded HOST=devbox scripts/e2e.sh            (built-in terminal pane, the default)
#
# Guardrail: only tmux sessions named muxbar-e2e-* are ever created, changed or killed.
set -uo pipefail
cd "$(dirname "$0")/.."

HOST=${HOST:-local}
# Second host for cross-host tests (an ssh alias with tmux 2.6+); those tests skip if unreachable.
REMOTE=${REMOTE:-devbox}
TERMINAL=${TERMINAL:-embedded}
M="$HOME/Applications/Muxbar.app/Contents/MacOS/Muxbar"
OUT="e2e-artifacts/$HOST-$TERMINAL"
RES="$OUT/results.tsv"
DIR=/tmp/muxbar-e2e-dir
mkdir -p "$OUT"

mb() { perl -e 'alarm 90; exec @ARGV' "$M" --cli "$@"; }

# Run a shell script on the host directly (test setup/verification, outside Muxbar).
rsh() {
  if [ "$HOST" = local ]; then
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" sh -c "$1"
  else
    printf '%s\n' "$1" | ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto \
      -o "ControlPath=$HOME/.muxbar/cm/%C" -o ControlPersist=10m -T "$HOST" sh -s 2>/dev/null
  fi
}

log() { printf '%s\n' "$*" >> "$OUT/log.txt"; printf '%s\n' "$*"; }
pass() { printf '%s\tPASS\t%s\n' "$1" "$2" >> "$RES"; log "✅ $1 PASS — $2"; }
fail() { printf '%s\tFAIL\t%s\n' "$1" "$2" >> "$RES"; log "❌ $1 FAIL — $2"; }
skip() { printf '%s\tSKIP\t%s\n' "$1" "$2" >> "$RES"; log "⏭  $1 SKIP — $2"; }

# list columns: host id status name path
row()    { mb list --host "$HOST" | awk -F'\t' -v n="$1" '$4==n' | head -1; }
idof()   { row "$1" | cut -f2; }
statof() { row "$1" | cut -f3; }
listed() { [ -n "$(row "$1")" ]; }
tmux_has() { rsh "tmux list-sessions -F '#{session_name}' 2>/dev/null" | grep -Fxq -- "$1"; }
# iTerm2 appends the job name ("name (tmux)"); Terminal shows the title as set.
emb_line() { mb embedded | grep -F "name=$1 " | head -1; }
emb_state() { emb_line "$1" | sed -n 's/.*state=\([a-z]*\).*/\1/p'; }
emb_starts() { emb_line "$1" | sed -n 's/.* starts=\([0-9]*\).*/\1/p'; }
# ≥1: after a hard drop the remote may still count the dead client until sshd times it out.
is_attached() { rsh "tmux list-sessions -F '#{session_name} #{session_attached}'" | awk -v n="$1" '$1==n && $2>=1 {f=1} END {exit !f}'; }
ext_windows() { # number of Terminal + iTerm2 windows (built-in mode must never open any)
  local a b
  a=$(osascript -e 'tell application id "com.apple.Terminal" to count windows' 2>/dev/null || echo 0)
  b=$(osascript -e 'if application id "com.googlecode.iterm2" is running then tell application id "com.googlecode.iterm2" to count windows' 2>/dev/null || echo 0)
  echo $(( ${a:-0} + ${b:-0} ))
}
wsnap() { mb snapshot --what window --out "$PWD/$OUT/$1.png" >/dev/null && echo "$OUT/$1.png"; }
snap() { mb snapshot --out "$PWD/$OUT/$1.png" >/dev/null && echo "$OUT/$1.png"; }
title_shown() { mb tabs | grep -Eq "title=$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')( \([^)]*\))? tty="; }

wait_for() { # wait_for SECONDS cmd...
  local t=$1; shift
  local end=$((SECONDS + t))
  while [ $SECONDS -lt $end ]; do "$@" && return 0; sleep 1; done
  return 1
}

cleanup_e2e() {
  mb group-delete --host "$HOST" --name e2e-grp >/dev/null 2>&1; mb group-delete --host "$HOST" --name e2e-grp2 >/dev/null 2>&1
  # Only our own sessions. Names are matched by prefix and killed by $id.
  rsh 'tmux list-sessions -F "#{session_id} #{session_name}" 2>/dev/null | while read id name; do
         case "$name" in muxbar-e2e-*) [ "$name" = muxbar-e2e-claude ] || tmux kill-session -t "$id";; esac
       done'
  mb refresh --host "$HOST" >/dev/null
  mb dismiss-ended --host "$HOST" >/dev/null
}

# Close Terminal windows whose title is one of ours and that sit at a prompt.
close_e2e_windows() {
  if [ "$TERMINAL" = iterm ]; then
    osascript -e 'tell application id "com.googlecode.iterm2" to repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if name of s starts with "muxbar-e2e" then tell s to close
        end repeat
      end repeat
    end repeat' >/dev/null 2>&1
  else
    osascript -e 'tell application id "com.apple.Terminal" to repeat with w in windows
      if custom title of selected tab of w starts with "muxbar-e2e" then close w saving no
    end repeat' >/dev/null 2>&1
  fi
}

simulate_vpn_drop() {
  # Kill only the local attach clients for muxbar-e2e-* sessions, plus the app's ssh ControlMaster.
  local id
  # tmux ids repeat across hosts, so match the host too: remote clients are
  # "ssh -t HOST tmux attach-session -t '$N'", local ones "tmux attach-session -t $N" (unquoted).
  for id in $(rsh 'tmux list-sessions -F "#{session_id} #{session_name}" 2>/dev/null' | awk '$2 ~ /^muxbar-e2e-/ {print $1}'); do
    if [ "$HOST" = local ]; then
      pat="tmux attach-session -t \\\$${id#\$}\$"
    else
      pat="ssh .*-t $HOST tmux attach-session -t '\\\$${id#\$}'\$"
    fi
    # SIGKILL: an ssh -t in a pty can survive SIGTERM, and a real network loss doesn't ask nicely.
    pkill -9 -f "$pat" 2>/dev/null
    for _ in 1 2 3 4 5; do pgrep -f "$pat" >/dev/null || break; sleep 0.5; done
  done
  for s in "$HOME"/.muxbar/cm/*; do [ -S "$s" ] && ssh -O exit -o "ControlPath=$s" "$HOST" 2>/dev/null; done
  pkill -f "ControlPath=$HOME/.muxbar/cm" 2>/dev/null
  sleep 2
}

# ---------------------------------------------------------------------------------------------

E1() {
  local h; h=$(mb probe --host "$HOST")
  echo "$h" > "$OUT/E1-probe.txt"
  local v; v=$(printf '%s' "$h" | sed -n 's/.*tmux=tmux \([0-9][0-9.a-z]*\).*/\1/p')
  if printf '%s' "$h" | grep -q "health=OK" && [ -n "$v" ]; then pass E1 "health OK, tmux $v"
  else fail E1 "$h"; fi
}

E2() {
  rsh "tmux new-session -d -s muxbar-e2e-manual 'sleep 900'"
  local t0=$SECONDS
  # No `refresh`: rely on the app's own background poll (≤30s).
  if wait_for 40 listed muxbar-e2e-manual; then pass E2 "hand-made session listed after $((SECONDS - t0))s"
  else fail E2 "muxbar-e2e-manual not listed within 40s"; fi
}

E3() {
  if [ "$TERMINAL" = embedded ]; then
    rsh "mkdir -p $DIR"
    local w0; w0=$(ext_windows)
    mb new --host "$HOST" --name muxbar-e2e-a --dir "$DIR" --cmd 'sleep 600' --json > "$OUT/E3-new.json"
    local id; id=$(idof muxbar-e2e-a)
    local path; path=$(rsh "tmux list-panes -t '$id' -F '#{pane_current_path}'" | head -1)
    if [ -n "$id" ] && [ "$path" = "$(rsh "cd $DIR && pwd -P")" ] && wait_for 25 is_attached muxbar-e2e-a \
       && [ "$(emb_state muxbar-e2e-a)" = running ] && [ "$(mb selected)" = muxbar-e2e-a ] && [ "$(ext_windows)" = "$w0" ]; then
      pass E3 "created $id in $path; attached in Muxbar's own pane and selected; no Terminal/iTerm window opened; ui=$(wsnap E3-window)"
    else fail E3 "id='$id' path='$path' pane=$(emb_state muxbar-e2e-a) selected=$(mb selected) extWindows ${w0}→$(ext_windows)"; fi
    return
  fi
  rsh "mkdir -p $DIR"
  local out; out=$(mb new --host "$HOST" --name muxbar-e2e-a --dir "$DIR" --cmd 'sleep 600' --json)
  echo "$out" > "$OUT/E3-new.json"
  local id; id=$(idof muxbar-e2e-a)
  local path; path=$(rsh "tmux list-panes -t '$id' -F '#{pane_current_path}'" | head -1)
  sleep 2
  mb tabs > "$OUT/E3-tabs.txt"
  if [ -n "$id" ] && [ "$path" = "$(rsh "cd $DIR && pwd -P")" ] && wait_for 8 title_shown muxbar-e2e-a; then
    pass E3 "created $id in $path; window titled muxbar-e2e-a; ui=$(snap E3-ui)"
  else fail E3 "id='$id' path='$path' (see E3-tabs.txt)"; fi
}

E4() {
  if [ "$TERMINAL" = embedded ]; then
    local id; id=$(idof muxbar-e2e-a)
    mb rename --host "$HOST" --id "$id" --name muxbar-e2e-b > "$OUT/E4-rename.txt"
    pane_running() { [ "$(emb_state muxbar-e2e-b)" = running ]; }
    wait_for 5 pane_running
    if listed muxbar-e2e-b && ! listed muxbar-e2e-a && tmux_has muxbar-e2e-b && [ "$(emb_state muxbar-e2e-b)" = running ] && is_attached muxbar-e2e-b; then
      pass E4 "renamed $id → muxbar-e2e-b in list, header and tmux; pane stayed attached; ui=$(wsnap E4-window)"
    else fail E4 "pane=$(emb_state muxbar-e2e-b)"; fi
    return
  fi
  local id; id=$(idof muxbar-e2e-a)
  mb rename --host "$HOST" --id "$id" --name muxbar-e2e-b > "$OUT/E4-rename.txt"
  if listed muxbar-e2e-b && ! listed muxbar-e2e-a && tmux_has muxbar-e2e-b && wait_for 6 title_shown muxbar-e2e-b; then
    pass E4 "renamed $id → muxbar-e2e-b in list, tmux and window title; ui=$(snap E4-ui)"
  else
    mb tabs > "$OUT/E4-tabs.txt"
    fail E4 "list/tmux/title mismatch (see E4-tabs.txt)"
  fi
}

E5() {
  local hostile="muxbar-e2e-'q \$x;y"
  rsh "tmux new-session -d -s muxbar-e2e-sentinel 'sleep 900'"
  rsh "tmux new-session -d -s \"muxbar-e2e-'q \\\$x;y\" 'sleep 900'"
  mb refresh --host "$HOST" >/dev/null
  local id; id=$(idof "$hostile")
  if [ -z "$id" ]; then fail E5 "hostile name not listed"; return; fi
  local f; f=$(mb focus --host "$HOST" --id "$id")
  sleep 1
  mb kill --host "$HOST" --id "$id" --yes > "$OUT/E5-kill.txt"
  if [ -n "$f" ] && ! tmux_has "$hostile" && tmux_has muxbar-e2e-sentinel; then
    pass E5 "listed as $id, focus=$f, killed; sentinel untouched"
  else fail E5 "focus='$f' still-present=$(tmux_has "$hostile" && echo y || echo n)"; fi
}

E6() {
  rsh "tmux new-session -d -s muxbar-e2e-ab 'sleep 900'; tmux new-session -d -s muxbar-e2e-a 'sleep 900'"
  mb refresh --host "$HOST" >/dev/null
  # Target by exact name (resolved to $id by the app), never tmux prefix matching.
  mb rename --host "$HOST" --id muxbar-e2e-a --name muxbar-e2e-a2 >/dev/null
  mb kill --host "$HOST" --id muxbar-e2e-a2 --yes >/dev/null
  if tmux_has muxbar-e2e-ab && ! tmux_has muxbar-e2e-a && ! tmux_has muxbar-e2e-a2; then
    pass E6 "actions on muxbar-e2e-a never touched muxbar-e2e-ab"
  else fail E6 "$(rsh "tmux ls" | grep e2e | tr '\n' ';')"; fi
}

E7() {
  if [ "$TERMINAL" = embedded ]; then
    rsh "mkdir -p $DIR"
    mb new --host "$HOST" --name muxbar-e2e-p1 --dir "$DIR" --cmd 'sleep 900' >/dev/null
    mb new --host "$HOST" --name muxbar-e2e-p2 --dir "$DIR" --cmd 'sleep 900' >/dev/null
    wait_for 25 is_attached muxbar-e2e-p2
    simulate_vpn_drop
    wait_for 10 sh -c "\"$M\" --cli embedded | grep -F 'name=muxbar-e2e-p1 ' | grep -q state=exited"
    local d1 d2; d1=$(emb_state muxbar-e2e-p1); d2=$(emb_state muxbar-e2e-p2)
    local ui; ui=$(wsnap E7-disconnected)
    mb refresh --host "$HOST" >/dev/null
    local s1 s2; s1=$(statof muxbar-e2e-p1); s2=$(statof muxbar-e2e-p2)
    local f1 f2; f1=$(mb focus --host "$HOST" --id muxbar-e2e-p1); f2=$(mb focus --host "$HOST" --id muxbar-e2e-p2)
    both() { is_attached muxbar-e2e-p1 && is_attached muxbar-e2e-p2; }
    wait_for 25 both
    if [ "$d1" = exited ] && [ "$d2" = exited ] && [ -n "$s1" ] && [ "$s1" != ended ] && [ -n "$s2" ] && [ "$s2" != ended ] \
       && [ "$f1" = reattachedInPlace ] && [ "$f2" = reattachedInPlace ] && both; then
      pass E7 "panes showed Disconnected after the drop, sessions survived; one focus each reattached in the same pane; ui=$ui"
    else fail E7 "panes after drop p1=$d1 p2=$d2; status p1=$s1 p2=$s2; focus p1=$f1 p2=$f2"; fi
    return
  fi
  # Two sessions with windows, then a simulated VPN drop. One window is then closed entirely.
  rsh "mkdir -p $DIR"
  mb new --host "$HOST" --name muxbar-e2e-p1 --dir "$DIR" --cmd 'sleep 900' >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-p2 --dir "$DIR" --cmd 'sleep 900' >/dev/null
  sleep 3
  simulate_vpn_drop
  mb refresh --host "$HOST" >/dev/null
  local s1 s2; s1=$(statof muxbar-e2e-p1); s2=$(statof muxbar-e2e-p2)
  if [ -z "$s1" ] || [ "$s1" = ended ] || [ -z "$s2" ] || [ "$s2" = ended ]; then
    fail E7 "sessions lost after drop: p1=$s1 p2=$s2"; return
  fi
  # p2: close its window completely (by the window id/session id Muxbar recorded).
  local tabref; tabref=$(mb status --host "$HOST" --id muxbar-e2e-p2 --json | python3 -c '
import json,sys; t=json.load(sys.stdin)["result"].get("tab",{}); print(t.get("windowID",-1), t.get("itermSessionID",""))')
  local wid=${tabref%% *} isid=${tabref#* }
  if [ "$TERMINAL" = iterm ]; then
    osascript -e "tell application id \"com.googlecode.iterm2\" to repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if unique ID of s is \"$isid\" then tell s to close
        end repeat
      end repeat
    end repeat" >/dev/null 2>&1
  else
    osascript -e "tell application id \"com.apple.Terminal\" to close (window id $wid) saving no" >/dev/null 2>&1
  fi
  sleep 1
  local gone=no
  if [ "$TERMINAL" = iterm ]; then mb tabs | grep -q "itermSessionID=$isid " || gone=yes
  else mb tabs | grep -q "windowID=$wid$" || gone=yes; fi
  sleep 1
  local f1 f2; f1=$(mb focus --host "$HOST" --id muxbar-e2e-p1); f2=$(mb focus --host "$HOST" --id muxbar-e2e-p2)
  both_attached() {
    local x; x=$(rsh "tmux list-sessions -F '#{session_name} #{session_attached}'" | grep -E '^muxbar-e2e-p[12] ' | tr '\n' ';')
    echo "$x" | grep -q "muxbar-e2e-p1 1" && echo "$x" | grep -q "muxbar-e2e-p2 1"
  }
  wait_for 25 both_attached   # remote attach over ssh can take several seconds
  local a; a=$(rsh "tmux list-sessions -F '#{session_name} #{session_attached}'" | grep -E '^muxbar-e2e-p[12] ' | tr '\n' ';')
  echo "p1=$f1 p2=$f2 p2WindowClosed=$gone attached=$a" > "$OUT/E7.txt"
  # Terminal.app after a hard drop still shows the dead tmux screen; Muxbar won't type into a
  # window that isn't at a prompt, so a fresh window (openedNew) is the correct, safe outcome too.
  local p1ok=no
  [ "$f1" = reattachedInPlace ] && p1ok=yes
  [ "$TERMINAL" = terminal ] && [ "$f1" = openedNew ] && p1ok=yes
  if [ "$gone" = yes ] && [ $p1ok = yes ] && [ "$f2" = openedNew ] && echo "$a" | grep -q "muxbar-e2e-p1 1" && echo "$a" | grep -q "muxbar-e2e-p2 1"; then
    pass E7 "both survived the drop; one focus each reattached them (p1 window reused=$f1, p2 window closed → $f2); ui=$(snap E7-ui)"
  else
    mb tabs > "$OUT/E7-tabs.txt"
    [ "$TERMINAL" = iterm ] && osascript -e 'tell application id "com.googlecode.iterm2"
      set out to ""
      repeat with wi from 1 to (count of windows)
        repeat with ti from 1 to (count of tabs of window wi)
          repeat with si from 1 to (count of sessions of tab ti of window wi)
            set s to session si of tab ti of window wi
            set out to out & "=== " & (name of s) & linefeed & (contents of s) & linefeed
          end repeat
        end repeat
      end repeat
      return out
    end tell' > "$OUT/E7-iterm-contents.txt" 2>&1
    fail E7 "p1=$f1 p2=$f2 p2WindowClosed=$gone attached=$a"
  fi
}

E8() {
  if [ "$TERMINAL" = embedded ]; then
    local w0 n0; w0=$(ext_windows); n0=$(mb embedded | grep -c "name=muxbar-e2e-p1 ")
    local st0; st0=$(emb_starts muxbar-e2e-p1)
    simulate_vpn_drop
    wait_for 10 sh -c "\"$M\" --cli embedded | grep -F 'name=muxbar-e2e-p1 ' | grep -q state=exited"
    local f; f=$(mb focus --host "$HOST" --id muxbar-e2e-p1)
    wait_for 25 is_attached muxbar-e2e-p1
    local n1; n1=$(mb embedded | grep -c "name=muxbar-e2e-p1 ")
    if [ "$f" = reattachedInPlace ] && [ "$n0" = 1 ] && [ "$n1" = 1 ] && [ "$(emb_starts muxbar-e2e-p1)" -gt "$st0" ] \
       && [ "$(ext_windows)" = "$w0" ] && is_attached muxbar-e2e-p1; then
      pass E8 "dead pane reused (focus=$f, panes for p1: $n0 → $n1, restarts $st0 → $(emb_starts muxbar-e2e-p1)); no external window"
    else fail E8 "focus=$f panes ${n0}→$n1 extWindows ${w0}→$(ext_windows)"; fi
    return
  fi
  # After E7, p1's window was reused. Drop again and check the window count stays the same.
  local before; before=$(mb tabs | grep -Ec "title=muxbar-e2e-p1( \([^)]*\))? tty=")
  simulate_vpn_drop
  local f; f=$(mb focus --host "$HOST" --id muxbar-e2e-p1)
  sleep 3
  local after; after=$(mb tabs | grep -Ec "title=muxbar-e2e-p1( \([^)]*\))? tty=")
  if [ "$f" = reattachedInPlace ] && [ "$after" -le "$before" ] && [ "$after" -ge 1 ]; then
    pass E8 "dead window reused (focus=$f, windows titled p1: $before → $after)"
  else fail E8 "focus=$f windows $before → $after"; fi
}

E10() {
  rsh "tmux new-session -d -s muxbar-e2e-k1 'sleep 900'; tmux new-session -d -s muxbar-e2e-k2 'sleep 900'"
  mb refresh --host "$HOST" >/dev/null
  local refused=0
  mb kill --host "$HOST" --id muxbar-e2e-k1 2> "$OUT/E10-refuse.txt" >/dev/null || refused=1
  local still; tmux_has muxbar-e2e-k1 && still=1 || still=0
  mb kill --host "$HOST" --id muxbar-e2e-k1 --yes >/dev/null
  if [ $refused = 1 ] && [ $still = 1 ] && ! tmux_has muxbar-e2e-k1 && tmux_has muxbar-e2e-k2; then
    pass E10 "refused without --yes ($(cat "$OUT/E10-refuse.txt")); --yes killed only k1"
  else fail E10 "refused=$refused stillAfterRefusal=$still"; fi
}

E11() {
  local cfg="$OUT/ssh-config-bogus"
  printf 'Include %s/.ssh/config\n\nHost muxbar-e2e-bogus\n  HostName 192.0.2.1\n  ProxyCommand none\n' "$HOME" > "$cfg"
  mb settings-set --ssh-config "$PWD/$cfg" >/dev/null
  mb hosts-add --host muxbar-e2e-bogus >/dev/null
  # While the bogus probe hangs (ConnectTimeout 10s), the app must keep answering and polling others.
  local t0 t1 before after
  before=$(mb hosts | awk '/host=local /{print}' | sed -n 's/.*lastRefresh=\([0-9]*\).*/\1/p')
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  mb hosts >/dev/null
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  mb refresh --host local >/dev/null
  after=$(mb hosts | awk '/host=local /{print}' | sed -n 's/.*lastRefresh=\([0-9]*\).*/\1/p')
  wait_for 40 sh -c "\"$M\" --cli hosts | grep 'host=muxbar-e2e-bogus' | grep -q Unreachable"
  local bogus; bogus=$(mb hosts | grep 'host=muxbar-e2e-bogus')
  local ui; ui=$(snap E11-ui)
  echo "$bogus" > "$OUT/E11-hosts.txt"
  mb hosts-remove --host muxbar-e2e-bogus >/dev/null
  mb settings-set --ssh-config "" >/dev/null
  local lat; lat=$(perl -e "printf '%.2f', $t1 - $t0")
  if echo "$bogus" | grep -q Unreachable && perl -e "exit !($lat < 2)" && [ "$after" -ge "$before" ]; then
    pass E11 "bogus host Unreachable; app answered in ${lat}s during the hang; local kept refreshing; ui=$ui"
  else fail E11 "bogus='$bogus' latency=$lat local ${before}→$after"; fi
}

E12() {
  local h; h=$(mb hosts | grep "host=$HOST ")
  if echo "$h" | grep -q "Auth expired"; then pass E12 "live: $h"
  else skip E12 "SSH auth did not expire during run; covered by unit test sshErrors() with captured ssh text"; fi
}

E13() {
  local sf="$HOME/Library/Application Support/Muxbar/state.json"
  cp "$sf" "$OUT/state-backup.json"
  mb quit >/dev/null; sleep 2
  printf '{ this is not json' > "$sf"
  open "$HOME/Applications/Muxbar.app"; wait_for 15 sh -c "\"$M\" --cli info >/dev/null 2>&1"
  local info; info=$(mb info)
  local bad; bad=$(ls "$sf".bad-* 2>/dev/null | tail -1)
  echo "$info" > "$OUT/E13-info.txt"
  # Restore the real state.
  mb quit >/dev/null; sleep 2
  cp "$OUT/state-backup.json" "$sf"; rm -f "$bad"
  open "$HOME/Applications/Muxbar.app"; wait_for 15 sh -c "\"$M\" --cli info >/dev/null 2>&1"
  if echo "$info" | grep -q "banner=Muxbar's saved state was unreadable" && [ -n "$bad" ]; then
    pass E13 "corrupt file moved aside ($(basename "$bad")), warning shown, app ran; state restored"
  else fail E13 "info=$info bad=$bad"; fi
}

E14() {
  mb simulate-sleep > "$OUT/E14-sleep.txt"
  sleep 3   # let a poll that was already in flight finish
  local b; b=$(mb hosts | grep "host=local " | sed -n 's/.*lastRefresh=\([0-9]*\).*/\1/p')
  sleep 35
  local a; a=$(mb hosts | grep "host=local " | sed -n 's/.*lastRefresh=\([0-9]*\).*/\1/p')
  mb simulate-wake > "$OUT/E14-wake.txt"
  sleep 3
  local w; w=$(mb hosts | grep "host=local " | sed -n 's/.*lastRefresh=\([0-9]*\).*/\1/p')
  if grep -q "active=0" "$OUT/E14-sleep.txt" && [ "$a" = "$b" ] && [ "$w" -gt "$a" ] && grep -q "active=1" "$OUT/E14-wake.txt"; then
    pass E14 "no polls for 35s while asleep; immediate refresh on wake ($a → $w)"
  else fail E14 "before=$b asleep=$a wake=$w"; fi
}

E17() {
  # L1: no local tmux → plain window, tracked by tty; focus brings it forward; kill just forgets it.
  mb settings-set --disable-local-tmux true >/dev/null
  local health; health=$(mb probe --host local)
  mb new --host local --name muxbar-e2e-plain --dir /tmp --cmd 'sleep 300' > "$OUT/E17-new.txt" 2>&1
  sleep 2
  local pane=""; [ "$TERMINAL" = embedded ] && pane=$(emb_state muxbar-e2e-plain)
  local r; r=$(row muxbar-e2e-plain)
  local f; f=$(mb focus --host local --id muxbar-e2e-plain)
  local ui; ui=$(snap E17-ui)
  local tty; tty=$(grep -o 'tty=[^ ]*' "$OUT/E17-new.txt" | head -1)
  mb kill --host local --id muxbar-e2e-plain --yes >/dev/null
  mb settings-set --disable-local-tmux false >/dev/null
  osascript -e 'tell application id "com.apple.Terminal" to repeat with w in windows
      if custom title of selected tab of w is "muxbar-e2e-plain" then close w saving no
    end repeat' >/dev/null 2>&1
  local paneok=yes; [ "$TERMINAL" = embedded ] && [ "$pane" != running ] && paneok=no
  if echo "$health" | grep -q "tmux missing" && [ -n "$r" ] && [ "$(echo "$r" | cut -f2)" = "" ] && [ "$f" = focused ] && [ $paneok = yes ] && ! listed muxbar-e2e-plain; then
    pass E17 "no-tmux mode: plain ${TERMINAL} session listed without tmux id (pane=${pane:-n/a}), focus=$f, kill forgot it; ui=$ui"
  else fail E17 "health=$health row=$r focus=$f"; fi
}

E18() {
  # Built-in mode: focusing a session while the main window is closed reopens it (no hang).
  [ "$TERMINAL" = embedded ] || { skip E18 "built-in terminal only"; return; }
  rsh "tmux new-session -d -s muxbar-e2e-w 'sleep 600'"
  mb refresh --host "$HOST" >/dev/null
  mb window --action close >/dev/null; sleep 1
  local before; before=$(mb window)
  local t0=$SECONDS f; f=$(mb focus --host "$HOST" --id muxbar-e2e-w 2>"$OUT/E18-focus.err")
  local dt=$((SECONDS - t0)); sleep 1
  local after sel; after=$(mb window); sel=$(mb selected)
  if [ "$before" = closed ] && [ -n "$f" ] && [ $dt -le 5 ] && [ "$after" = open ] && [ "$sel" = muxbar-e2e-w ]; then
    pass E18 "window closed → focus reopened it in ${dt}s and selected the session; ui=$(wsnap E18-window)"
  else fail E18 "before=$before focus='$f' (${dt}s) after=$after selected=$sel"; fi
}

E19() {
  # New session without a command = a plain shell; the user runs whatever they want in it.
  [ "$TERMINAL" = embedded ] || { skip E19 "built-in terminal only"; return; }
  rsh "mkdir -p $DIR; rm -f /tmp/muxbar-e2e-ran.txt"
  mb new --host "$HOST" --name muxbar-e2e-sh --dir "$DIR" > "$OUT/E19-new.txt"
  wait_for 25 is_attached muxbar-e2e-sh
  local id; id=$(idof muxbar-e2e-sh)
  local cmd; cmd=$(rsh "tmux list-panes -t '$id' -F '#{pane_current_command}'" | head -1)
  sleep 2
  # Typed through Muxbar's own terminal pane, like a user at the keyboard.
  mb type --host "$HOST" --id muxbar-e2e-sh --text 'echo "ran in $(pwd) as $(whoami)" > /tmp/muxbar-e2e-ran.txt' >/dev/null
  ran() { rsh "cat /tmp/muxbar-e2e-ran.txt 2>/dev/null" | grep -q "ran in"; }
  wait_for 15 ran
  local got; got=$(rsh "cat /tmp/muxbar-e2e-ran.txt 2>/dev/null")
  local ui; ui=$(wsnap E19-window)
  case "$cmd" in zsh|bash|sh|-zsh|-bash|fish) local isshell=yes;; *) local isshell=no;; esac
  # The shell may report the logical path (/tmp/…) or the resolved one (/private/tmp/…).
  if [ $isshell = yes ] && { echo "$got" | grep -q "ran in $DIR " || echo "$got" | grep -q "ran in $(rsh "cd $DIR && pwd -P") "; }; then
    pass E19 "no command asked; pane is a login shell ($cmd); typed command ran: '$got'; ui=$ui"
  else fail E19 "pane command='$cmd' file='$got'"; fi
}

E20() {
  # Groups live under one host: create on $HOST, move sessions in (incl. one created with --group),
  # reject a session from another host, rename, delete (sessions stay running under the host).
  [ "$TERMINAL" = embedded ] || { skip E20 "built-in terminal only"; return; }
  local other=local; [ "$HOST" = local ] && other=$REMOTE
  mb group-delete --host "$HOST" --name e2e-grp >/dev/null 2>&1; mb group-delete --host "$HOST" --name e2e-grp2 >/dev/null 2>&1
  # Groups hold Muxbar sessions (outside ones stay in Others), so create them through Muxbar.
  mb new --host "$HOST" --name muxbar-e2e-g1 --dir /tmp --cmd 'sleep 600' --no-attach >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-g2 --dir /tmp --cmd 'sleep 600' --no-attach >/dev/null
  mb group-create --host "$HOST" --name e2e-grp >/dev/null
  mb group-set --host "$HOST" --id muxbar-e2e-g1 --group e2e-grp >/dev/null 2>"$OUT/E20-set.err"
  mb group-set --host "$HOST" --id muxbar-e2e-g2 --group e2e-grp >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-g3 --dir /tmp --group e2e-grp --no-attach >/dev/null
  # A session on another host must not be able to join this host's group.
  # Uses its own throwaway session on the other host, never one of the user's.
  local cross="skipped"
  if HOST="$other" rsh "tmux new-session -d -s muxbar-e2e-xhost 'sleep 300'" 2>/dev/null; then
    mb refresh --host "$other" >/dev/null
    if mb group-set --host "$other" --id muxbar-e2e-xhost --group e2e-grp >/dev/null 2>"$OUT/E20-cross.err"; then cross=ACCEPTED; else cross=rejected; fi
    local xid; xid=$(mb list --host "$other" | awk -F'\t' '$4=="muxbar-e2e-xhost" {print $2}')
    [ -n "$xid" ] && mb kill --host "$other" --id "$xid" --yes >/dev/null
  fi
  grp_members() { mb groups --host "$HOST" --json | python3 -c "
import json,sys
for g in json.load(sys.stdin)['result']:
    if g['group'] == '$1': print(' '.join(sorted(g['sessions'])))"; }
  local g; g=$(grp_members e2e-grp)
  local onhost; onhost=$(mb groups --json | python3 -c "
import json,sys; print(sorted({g['host'] for g in json.load(sys.stdin)['result'] if g['group']=='e2e-grp'}))")
  local persisted; persisted=$(grep -c '"group" : "e2e-grp"' "$HOME/Library/Application Support/Muxbar/state.json")
  local ui; ui=$(wsnap E20-tree)
  mb group-rename --host "$HOST" --name e2e-grp --to e2e-grp2 >/dev/null
  local g2; g2=$(grp_members e2e-grp2)
  mb group-delete --host "$HOST" --name e2e-grp2 >/dev/null
  local after; after=$(mb groups --host "$HOST" | grep -c "e2e-grp")
  if [ "$g" = "muxbar-e2e-g1 muxbar-e2e-g2 muxbar-e2e-g3" ] && [ "$onhost" = "['$HOST']" ] && [ "$cross" != ACCEPTED ] \
     && [ "$persisted" -ge 3 ] && echo "$g2" | grep -q "muxbar-e2e-g1" && [ "$after" = 0 ] && listed muxbar-e2e-g1 && tmux_has muxbar-e2e-g1; then
    pass E20 "group on $HOST only ($onhost) with 3 sessions; $other session $cross ($(tr -d '\n' < "$OUT/E20-cross.err" 2>/dev/null | cut -c1-70)); renamed, deleted, sessions kept; ui=$ui"
  else fail E20 "members='$g' hosts=$onhost cross=$cross persisted=$persisted renamed='$g2' left=$after"; fi
}

E21() {
  # Continue sessions started outside Muxbar: (a) a tmux session, (b) a Claude conversation.
  [ "$TERMINAL" = embedded ] || { skip E21 "built-in terminal only"; return; }
  rsh "tmux new-session -d -s muxbar-e2e-outside -c /tmp"
  local f; f=$(mb focus --host "$HOST" --id muxbar-e2e-outside 2>/dev/null)
  [ -z "$f" ] && { mb refresh --host "$HOST" >/dev/null; f=$(mb focus --host "$HOST" --id muxbar-e2e-outside); }
  wait_for 25 is_attached muxbar-e2e-outside
  sleep 1
  mb type --host "$HOST" --id muxbar-e2e-outside --text 'echo outside-ok > /tmp/muxbar-e2e-outside.txt' >/dev/null
  oko() { rsh "cat /tmp/muxbar-e2e-outside.txt 2>/dev/null" | grep -q outside-ok; }
  local a=no; wait_for 15 oko && a=yes
  local b="n/a" detail=""
  if command -v claude >/dev/null 2>&1 && [ "$HOST" = local ]; then
    local cdir=/tmp/muxbar-e2e-conv marker="muxbar-e2e-marker-$RANDOM"
    mkdir -p "$cdir"
    local outabs="$PWD/$OUT"
    (cd "$cdir" && perl -e 'alarm 120; exec @ARGV' env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "Reply with exactly this word and nothing else: $marker" > "$outabs/E21-claude-p.txt" 2>&1)
    local cid; cid=$(mb conversations --host local --json | python3 -c "
import json,sys
for c in json.load(sys.stdin)['result']:
    if c['cwd'].endswith('/muxbar-e2e-conv') and '$marker' in c['prompt']: print(c['id']); break")
    if [ -n "$cid" ]; then
      mb resume --host local --id "$cid" --name muxbar-e2e-resume > "$OUT/E21-resume.txt"
      local rid; rid=$(idof muxbar-e2e-resume)
      shows() { tmux capture-pane -p -J -t "$rid" 2>/dev/null | grep -q "$marker"; }
      trusted() { tmux capture-pane -p -J -t "$rid" 2>/dev/null | grep -q "trust this folder\|Yes, I trust"; }
      for _ in $(seq 40); do shows && break; if trusted; then tmux send-keys -t "$rid" Down; sleep 0.3; tmux send-keys -t "$rid" Enter; fi; sleep 1; done
      tmux capture-pane -p -J -t "$rid" > "$OUT/E21-resumed-pane.txt" 2>/dev/null
      local path; path=$(tmux list-panes -t "$rid" -F '#{pane_current_path}' | head -1)
      mb refresh --host local >/dev/null
      local st; st=$(statof muxbar-e2e-resume)
      if shows && [ "$path" = "$(cd $cdir && pwd -P)" ] && [ "$st" != notClaude ]; then b=yes; else b=no; fi
      detail="claude id=$cid path=$path status=$st"
      local ui; ui=$(wsnap E21-resumed)
    else b=no; detail="conversation with marker not listed"; fi
  else
    local n; n=$(mb conversations --host "$HOST" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))' 2>/dev/null)
    detail="no claude on host: conversations listed=$n (handled without error)"
    [ -n "$n" ] && b="n/a"
  fi
  if [ $a = yes ] && [ "$b" != no ]; then
    pass E21 "outside tmux session: focus=$f, attached, typed command ran; outside Claude conversation resumed=$b ($detail)${ui:+; ui=$ui}"
  else fail E21 "tmux=$a claude=$b ($detail)"; fi
}

E22() {
  # Menu-bar glyph shuffles while a session waits for input, and stops when none waits.
  # A stand-in "claude" (a renamed sleep) shows a permission prompt, so no real Claude is needed.
  [ "$HOST" = local ] || { skip E22 "menu-bar glyph is host-independent; run on local"; return; }
  # macOS kills copies of system binaries, so compile a tiny stand-in named claude.
  mkdir -p /tmp/muxbar-e2e-bin && printf '#include <unistd.h>\nint main(void){sleep(300);return 0;}\n' | cc -x c - -o /tmp/muxbar-e2e-bin/claude
  # The user's own sessions may be waiting already; then only "animates while ours waits" is testable.
  local others; others=$(mb waiting --json | python3 -c "import json,sys; print(len([r for r in json.load(sys.stdin)['result'] if not r['name'].startswith('muxbar-e2e-')]))")
  local before; before=$(mb branding | grep -o 'menuGlyphAnimating=[01]')
  tmux new-session -d -s muxbar-e2e-wait "printf 'Bash command\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n'; exec /tmp/muxbar-e2e-bin/claude 300"
  waiting_now() { mb refresh --host local >/dev/null; mb branding | grep -q 'menuGlyphAnimating=1'; }
  local during=no; wait_for 20 waiting_now && during=yes
  local st; st=$(statof muxbar-e2e-wait)
  local wid; wid=$(idof muxbar-e2e-wait)
  mb kill --host local --id "$wid" --yes >/dev/null
  stopped() { mb refresh --host local >/dev/null; mb branding | grep -q 'menuGlyphAnimating=0'; }
  local after=no; wait_for 15 stopped && after=yes
  if [ "$others" -gt 0 ] && [ "$st" = waiting ] && [ $during = yes ]; then
    pass E22 "glyph animating while session waits (status=$st); $others of the user's own sessions also waiting, so the still-afterwards check was skipped"
  elif [ "$before" = "menuGlyphAnimating=0" ] && [ "$st" = waiting ] && [ $during = yes ] && [ $after = yes ]; then
    pass E22 "idle glyph still; session status=$st → glyph animating; killed → still again"
  else fail E22 "before=$before status=$st during=$during after=$after"; fi
}

E23() {
  # Continue a Claude session by typing folder + session id (no lookup in the list).
  [ "$TERMINAL" = embedded ] || { skip E23 "built-in terminal only"; return; }
  local bad; bad=$(mb resume --host "$HOST" --id "x'; id #" --dir /tmp 2>&1 >/dev/null)
  if [ "$HOST" = local ] && command -v claude >/dev/null 2>&1; then
    local cdir=/tmp/muxbar-e2e-conv2 marker="muxbar-e2e-manual-$RANDOM" outabs="$PWD/$OUT"
    mkdir -p "$cdir"
    (cd "$cdir" && perl -e 'alarm 120; exec @ARGV' env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "Reply with exactly this word and nothing else: $marker" < /dev/null > "$outabs/E23-claude-p.txt" 2>&1)
    # The id the user would paste: newest transcript in that project's folder.
    local proj; proj=$(ls -td "$HOME"/.claude/projects/*muxbar-e2e-conv2* 2>/dev/null | head -1)
    local cid; cid=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)
    mb resume --host local --id "$cid" --dir "$cdir" --name muxbar-e2e-manual > "$OUT/E23-resume.txt" 2>&1
    # The app may suffix the name (-2) if one is taken; use what it returns.
    local rname; rname=$(grep -o 'name=[^ ]*' "$OUT/E23-resume.txt" | head -1 | cut -d= -f2)
    local rid; rid=$(idof "$rname")
    shows() { tmux capture-pane -p -J -t "$rid" 2>/dev/null | grep -q "$marker"; }
    trusted() { tmux capture-pane -p -J -t "$rid" 2>/dev/null | grep -q "trust this folder\|Yes, I trust"; }
    for _ in $(seq 40); do shows && break; if trusted; then tmux send-keys -t "$rid" Down; sleep 0.3; tmux send-keys -t "$rid" Enter; fi; sleep 1; done
    local path; path=$(tmux list-panes -t "$rid" -F '#{pane_current_path}' 2>/dev/null | head -1)
    local ui; ui=$(wsnap E23-manual)
    if [ -n "$cid" ] && shows && [ "$path" = "$(cd $cdir && pwd -P)" ] && echo "$bad" | grep -q "isn't a valid"; then
      pass E23 "typed folder + id ($cid) started claude --resume in $path with history shown; bad id rejected; ui=$ui"
    else fail E23 "id=$cid path=$path bad='$bad' (see E23-resume.txt)"; fi
  else
    # No claude on this host: check the wiring — a session starts in the typed folder running the command.
    rsh "mkdir -p /tmp/muxbar-e2e-conv2"
    mb resume --host "$HOST" --id 11111111-2222-3333-4444-555555555555 --dir /tmp/muxbar-e2e-conv2 --name muxbar-e2e-manual > "$OUT/E23-resume.txt" 2>&1
    local rname; rname=$(grep -o 'name=[^ ]*' "$OUT/E23-resume.txt" | head -1 | cut -d= -f2)
    local rid; rid=$(idof "$rname")
    local path; path=$(rsh "tmux list-panes -t '$rid' -F '#{pane_current_path}'" | head -1)
    ran() { rsh "tmux capture-pane -p -J -t '$rid'" | grep -q "claude"; }
    wait_for 10 ran
    if [ -n "$rid" ] && [ "$path" = "$(rsh 'cd /tmp/muxbar-e2e-conv2 && pwd -P')" ] && echo "$bad" | grep -q "isn't a valid"; then
      pass E23 "typed folder + id started a session in $path running claude --resume (claude isn't installed here); bad id rejected"
    else fail E23 "rid=$rid path=$path bad='$bad'"; fi
  fi
}

E25() {
  # Needs-input across hosts and groups: pinned section (oldest first), group waiting badge, ⌘J cycling.
  [ "$HOST" = local ] && [ "$TERMINAL" = embedded ] || { skip E25 "local run (uses $REMOTE too), built-in terminal"; return; }
  mkdir -p /tmp/muxbar-e2e-bin
  [ -x /tmp/muxbar-e2e-bin/claude ] || printf '#include <unistd.h>\nint main(void){sleep(300);return 0;}\n' | cc -x c - -o /tmp/muxbar-e2e-bin/claude
  local prompt="printf 'Bash command\\n Do you want to proceed?\\n ❯ 1. Yes\\n'"
  mb group-delete --host local --name e2e-attn >/dev/null 2>&1
  mb group-create --host local --name e2e-attn >/dev/null
  mb new --host local --name muxbar-e2e-w1 --dir /tmp --cmd "$prompt; exec /tmp/muxbar-e2e-bin/claude 300" --no-attach >/dev/null
  wait_one() { mb refresh --host "$1" >/dev/null; mb waiting | grep -q "name=$2 "; }
  wait_for 20 wait_one local muxbar-e2e-w1
  sleep 2
  local remote=no
  if HOST=$REMOTE rsh "mkdir -p /tmp/muxbar-e2e-bin && cp /bin/sleep /tmp/muxbar-e2e-bin/claude && tmux new-session -d -s muxbar-e2e-w3 \"$prompt; exec /tmp/muxbar-e2e-bin/claude 300\""; then
    wait_for 30 wait_one $REMOTE muxbar-e2e-w3 && remote=yes
  fi
  sleep 2
  mb new --host local --name muxbar-e2e-w2 --dir /tmp --cmd "$prompt; exec /tmp/muxbar-e2e-bin/claude 300" --no-attach >/dev/null
  wait_for 20 wait_one local muxbar-e2e-w2
  mb group-set --host local --id muxbar-e2e-w1 --group e2e-attn >/dev/null
  mb group-set --host local --id muxbar-e2e-w2 --group e2e-attn >/dev/null
  local order; order=$(mb waiting --json | python3 -c "import json,sys; print(' '.join(r['name'] for r in json.load(sys.stdin)['result'] if r['name'].startswith('muxbar-e2e-w')))")
  local loc; loc=$(mb waiting --json | python3 -c "import json,sys; print([r['location'] for r in json.load(sys.stdin)['result'] if r['name']=='muxbar-e2e-w1'][0])")
  local gw; gw=$(mb groups --host local --json | python3 -c "import json,sys; print([g['waiting'] for g in json.load(sys.stdin)['result'] if g['group']=='e2e-attn'][0])")
  local ui; ui=$(wsnap E25-needs-input)
  # ⌘J from a non-waiting selection: oldest first, then onward, wrapping round.
  mb select >/dev/null 2>&1
  local jumps=""; for _ in 1 2 3 4; do jumps="$jumps $(mb next-waiting)"; done
  local expect
  if [ $remote = yes ]; then expect="muxbar-e2e-w1 muxbar-e2e-w3 muxbar-e2e-w2"; else expect="muxbar-e2e-w1 muxbar-e2e-w2"; fi
  # Only our sessions count for the comparison (the user may have real waiting sessions too).
  local ours; ours=$(echo $jumps | tr ' ' '\n' | grep '^muxbar-e2e-w' | tr '\n' ' ' | sed 's/ $//')
  for n in w1 w2; do local id; id=$(idof muxbar-e2e-$n); [ -n "$id" ] && mb kill --host local --id "$id" --yes >/dev/null; done
  [ $remote = yes ] && { local rid; rid=$(mb list --host $REMOTE | awk -F'\t' '$4=="muxbar-e2e-w3"{print $2}'); mb kill --host $REMOTE --id "$rid" --yes >/dev/null; }
  mb group-delete --host local --name e2e-attn >/dev/null
  local first3; first3=$(echo "$ours" | cut -d' ' -f1-3)
  local okcycle=no
  if [ $remote = yes ]; then [ "$first3" = "$expect" ] && okcycle=yes; else [ "$(echo "$ours" | cut -d' ' -f1-2)" = "$expect" ] && okcycle=yes; fi
  if [ "$order" = "$expect" ] && [ "$loc" = "This Mac · e2e-attn" ] && [ "$gw" = 2 ] && [ $okcycle = yes ]; then
    pass E25 "pinned order (oldest first, across hosts) = $order; location '$loc'; group badge = $gw; ⌘J cycle:$jumps; ui=$ui"
  else fail E25 "order='$order' expect='$expect' loc='$loc' groupWaiting=$gw jumps='$jumps' remote=$remote"; fi
}

E26() {
  # Workspace folders: <root>/<group>/<session> created on New Session (no folder given);
  # rename / move group / rename group / delete group move the folder; kill keeps it.
  [ "$TERMINAL" = embedded ] || { skip E26 "built-in terminal only"; return; }
  local root=/tmp/muxbar-e2e-ws
  local prev; prev=$(mb workspace-root --host "$HOST")
  rsh "rm -rf $root"
  mb settings-set --root-host "$HOST" --root "$root" >/dev/null
  mb group-delete --host "$HOST" --name ws-a >/dev/null 2>&1; mb group-delete --host "$HOST" --name ws-b >/dev/null 2>&1
  mb group-create --host "$HOST" --name ws-a >/dev/null; mb group-create --host "$HOST" --name ws-b >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-ws1 --group ws-a > "$OUT/E26-new.txt"
  wait_for 25 is_attached muxbar-e2e-ws1
  local id; id=$(idof muxbar-e2e-ws1)
  exists() { rsh "[ -d '$1' ] && echo y" | grep -q y; }
  cwd() { rsh "tmux list-panes -t '$id' -F '#{pane_current_path}'" | head -1; }
  local steps=""
  rsh "echo keep > $root/ws-a/muxbar-e2e-ws1/notes.txt"
  exists "$root/ws-a/muxbar-e2e-ws1" && [ "$(cwd)" = "$(rsh "cd $root/ws-a/muxbar-e2e-ws1 && pwd -P")" ] && steps="${steps}create "
  mb rename --host "$HOST" --id "$id" --name muxbar-e2e-ws2 >/dev/null
  exists "$root/ws-a/muxbar-e2e-ws2" && ! exists "$root/ws-a/muxbar-e2e-ws1" && steps="${steps}rename "
  mb group-set --host "$HOST" --id "$id" --group ws-b >/dev/null
  exists "$root/ws-b/muxbar-e2e-ws2" && ! exists "$root/ws-a/muxbar-e2e-ws2" && steps="${steps}move "
  mb group-rename --host "$HOST" --name ws-b --to ws-c >/dev/null
  exists "$root/ws-c/muxbar-e2e-ws2" && ! exists "$root/ws-b" && steps="${steps}grouprename "
  # Collision: a folder already at the target → refused, nothing moved.
  rsh "mkdir -p $root/ws-c/muxbar-e2e-taken"
  local coll; coll=$(mb rename --host "$HOST" --id "$id" --name muxbar-e2e-taken 2>&1 >/dev/null)
  exists "$root/ws-c/muxbar-e2e-ws2" && echo "$coll" | grep -q "already exists" && listed muxbar-e2e-ws2 && steps="${steps}collision "
  rsh "rmdir $root/ws-c/muxbar-e2e-taken"
  mb group-delete --host "$HOST" --name ws-c >/dev/null
  exists "$root/muxbar-e2e-ws2" && ! exists "$root/ws-c" && steps="${steps}groupdelete "
  local ui; ui=$(wsnap E26-workspace)
  mb kill --host "$HOST" --id "$id" --yes >/dev/null
  rsh "cat $root/muxbar-e2e-ws2/notes.txt" | grep -q keep && steps="${steps}killkeeps"
  # The session's own path in Muxbar follows too.
  mb group-delete --host "$HOST" --name ws-a >/dev/null 2>&1
  mb settings-set --root-host "$HOST" --root "" >/dev/null
  rsh "rm -rf $root"
  if [ "$steps" = "create rename move grouprename collision groupdelete killkeeps" ]; then
    pass E26 "folder followed every step: $steps (notes.txt survived all moves; collision refused); ui=$ui"
  else fail E26 "steps passed: '$steps' (collision msg: $coll)"; fi
}

E27() {
  # Sessions started outside Muxbar stay in "Others": listed, attachable, but can't join a group.
  [ "$TERMINAL" = embedded ] || { skip E27 "built-in terminal only"; return; }
  rsh "tmux new-session -d -s muxbar-e2e-out 'sleep 600'"
  mb refresh --host "$HOST" >/dev/null
  mb group-delete --host "$HOST" --name e2e-oth >/dev/null 2>&1; mb group-create --host "$HOST" --name e2e-oth >/dev/null
  local origin; origin=$(mb status --host "$HOST" --id muxbar-e2e-out | tr ' ' '\n' | sed -n 's/^origin=//p')
  local refuse; refuse=$(mb group-set --host "$HOST" --id muxbar-e2e-out --group e2e-oth 2>&1 >/dev/null)
  local grp; grp=$(mb status --host "$HOST" --id muxbar-e2e-out | tr ' ' '\n' | sed -n 's/^group=//p')
  local f; f=$(mb focus --host "$HOST" --id muxbar-e2e-out)
  wait_for 25 is_attached muxbar-e2e-out
  local att=no; is_attached muxbar-e2e-out && att=yes
  local ui; ui=$(wsnap E27-others)
  mb group-delete --host "$HOST" --name e2e-oth >/dev/null
  if [ "$origin" = outside ] && echo "$refuse" | grep -q "stays in Others" && [ -z "$grp" ] && [ $att = yes ]; then
    pass E27 "outside session marked '$origin', group join refused ('$(echo "$refuse" | cut -c8-80)'), still attachable (focus=$f); ui=$ui"
  else fail E27 "origin=$origin refuse='$refuse' group='$grp' attached=$att"; fi
}

E28() {
  # App restart: the panes that were open come back (local + remote host) and the selection is kept.
  [ "$HOST" = local ] && [ "$TERMINAL" = embedded ] || { skip E28 "local run (uses $REMOTE too), built-in terminal"; return; }
  mb new --host local --name muxbar-e2e-rl --dir /tmp --cmd 'sleep 900' >/dev/null
  local remote=no
  mb new --host $REMOTE --name muxbar-e2e-rr --dir /tmp --cmd 'sleep 900' >/dev/null 2>&1 && remote=yes
  mb focus --host local --id muxbar-e2e-rl >/dev/null
  sleep 2
  local before; before=$(mb restore-state)
  mb quit >/dev/null; sleep 3
  open "$HOME/Applications/Muxbar.app"
  wait_for 20 sh -c "\"$M\" --cli info >/dev/null 2>&1"
  back() { mb embedded | grep -F "name=muxbar-e2e-rl " | grep -q state=running && { [ $remote = no ] || mb embedded | grep -F "name=muxbar-e2e-rr " | grep -q state=running; }; }
  local ok=no; wait_for 60 back && ok=yes
  local sel; sel=$(mb selected)
  local ui; ui=$(wsnap E28-restored)
  for h in local $REMOTE; do for n in rl rr; do local id; id=$(mb list --host $h | awk -F'\t' -v n=muxbar-e2e-$n '$4==n{print $2}'); [ -n "$id" ] && mb kill --host $h --id "$id" --yes >/dev/null; done; done
  if [ $ok = yes ] && [ "$sel" = muxbar-e2e-rl ]; then
    pass E28 "after quit+relaunch: panes running again (local$( [ $remote = yes ] && echo " + $REMOTE")), selection kept ($sel); saved: $before; ui=$ui"
  else fail E28 "panes back=$ok selected='$sel' saved='$before'"; fi
}

E29() {
  # Ended session (tmux gone, as after a reboot) → Resume: same name, folder, group; claude continues.
  [ "$TERMINAL" = embedded ] || { skip E29 "built-in terminal only"; return; }
  local root=/tmp/muxbar-e2e-ws2
  rsh "rm -rf $root"; mb settings-set --root-host "$HOST" --root "$root" >/dev/null
  mb group-delete --host "$HOST" --name e2e-res >/dev/null 2>&1; mb group-create --host "$HOST" --name e2e-res >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-res --group e2e-res --no-attach >/dev/null
  local folder="$root/e2e-res/muxbar-e2e-res"
  local marker="muxbar-e2e-res-$RANDOM" haveclaude=no
  if [ "$HOST" = local ] && command -v claude >/dev/null 2>&1; then
    haveclaude=yes
    local outabs="$PWD/$OUT"
    (cd "$folder" && perl -e 'alarm 120; exec @ARGV' env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "Reply with exactly this word and nothing else: $marker" < /dev/null > "$outabs/E29-claude-p.txt" 2>&1)
  fi
  # Simulate a reboot: the tmux session disappears behind Muxbar's back.
  local id; id=$(idof muxbar-e2e-res)
  rsh "tmux kill-session -t '$id'"
  mb refresh --host "$HOST" >/dev/null
  local st; st=$(statof muxbar-e2e-res)
  mb resume-ended --host "$HOST" --id muxbar-e2e-res > "$OUT/E29-resume.txt" 2>&1
  local nid; nid=$(idof muxbar-e2e-res)
  local path; path=$(rsh "tmux list-panes -t '$nid' -F '#{pane_current_path}'" | head -1)
  local grp; grp=$(mb status --host "$HOST" --id muxbar-e2e-res | tr ' ' '\n' | sed -n 's/^group=//p')
  local shown=no
  if [ $haveclaude = yes ]; then
    seen() { tmux capture-pane -p -J -t "$nid" 2>/dev/null | grep -q "$marker"; }
    trusted() { tmux capture-pane -p -J -t "$nid" 2>/dev/null | grep -q "trust this folder\|Yes, I trust"; }
    for _ in $(seq 40); do seen && break; if trusted; then tmux send-keys -t "$nid" Down; sleep 0.3; tmux send-keys -t "$nid" Enter; fi; sleep 1; done
    seen && shown=yes
  else
    tried() { rsh "tmux capture-pane -p -J -t '$nid'" | grep -q "claude"; }
    wait_for 10 tried && shown="ran claude --continue (claude not installed here)"
  fi
  local ui; ui=$(wsnap E29-resumed)
  [ -n "$nid" ] && mb kill --host "$HOST" --id "$nid" --yes >/dev/null
  mb group-delete --host "$HOST" --name e2e-res >/dev/null; mb settings-set --root-host "$HOST" --root "" >/dev/null
  rsh "rm -rf $root"
  if [ "$st" = ended ] && [ -n "$nid" ] && [ "$path" = "$(rsh "mkdir -p $folder; cd $folder && pwd -P")" ] && [ "$grp" = e2e-res ] && [ "$shown" != no ]; then
    pass E29 "ended → resumed with same name, folder ($path) and group ($grp); conversation: $shown; ui=$ui"
  else fail E29 "status=$st newid=$nid path=$path group=$grp shown=$shown (see E29-resume.txt)"; fi
}

E30() {
  # History scroll bar / wheel: back, jump, down, live — driven through tmux copy mode.
  # Uses a session it doesn't attach, so the user's selected pane is never switched.
  [ "$TERMINAL" = embedded ] || { skip E30 "built-in terminal only"; return; }
  mb new --host "$HOST" --name muxbar-e2e-hist --dir /tmp --cmd 'seq 1 500' --no-attach >/dev/null
  sleep 3
  local pos=""
  pos="$pos $(mb scroll --host "$HOST" --id muxbar-e2e-hist --lines 40 | sed -n 's/.*position=\([0-9]*\).*/\1/p')"
  pos="$pos $(mb scroll --host "$HOST" --id muxbar-e2e-hist --to 300 | sed -n 's/.*position=\([0-9]*\).*/\1/p')"
  pos="$pos $(mb scroll --host "$HOST" --id muxbar-e2e-hist --lines -100 | sed -n 's/.*position=\([0-9]*\).*/\1/p')"
  local live; live=$(mb scroll --host "$HOST" --id muxbar-e2e-hist --to 0 | grep -o 'atLive=[01]')
  local id; id=$(idof muxbar-e2e-hist); mb kill --host "$HOST" --id "$id" --yes >/dev/null
  if [ "$pos" = " 40 300 200" ] && [ "$live" = atLive=1 ]; then
    pass E30 "history positions back 40 → jump 300 → down 100 = $pos; back to live ($live)"
  else fail E30 "positions='$pos' live='$live'"; fi
}

ALL=(E1 E2 E3 E4 E5 E6 E7 E8 E10 E11 E12 E18 E19 E20 E21 E23 E26 E27 E29 E30)
[ "$HOST" = local ] && ALL+=(E13 E14 E17 E22 E25 E28)

main() {
  [ -x "$M" ] || { echo "Muxbar not installed"; exit 2; }
  mb info >/dev/null || { echo "Muxbar not running"; exit 2; }
  mb hosts | grep -q "host=$HOST " || mb hosts-add --host "$HOST" >/dev/null
  mb settings-set --terminal "$TERMINAL" >/dev/null
  # Tests switch the main window's selected pane; put the user's selection back afterwards.
  local prev_sel; prev_sel=$(mb selected)
  log "=== Muxbar E2E — host=$HOST terminal=$TERMINAL — $(date -u +%FT%TZ)"
  cleanup_e2e
  local tests=("$@"); [ ${#tests[@]} -eq 0 ] && tests=("${ALL[@]}")
  for t in "${tests[@]}"; do "$t"; done
  cleanup_e2e
  sleep 2
  close_e2e_windows
  mb settings-set --terminal embedded >/dev/null
  if [ -n "$prev_sel" ]; then
    local h; h=$(mb list | awk -F'\t' -v n="$prev_sel" '$4==n {print $1; exit}')
    [ -n "$h" ] && mb focus --host "$h" --id "$prev_sel" >/dev/null
  fi
  log "=== done"
}
main "$@"
