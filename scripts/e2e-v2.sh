# Muxbar v2 end-to-end rows (E32–E53), loaded by scripts/e2e.sh (same helpers, same guardrails:
# only muxbar-e2e-* sessions on the test tmux server; the installed Muxbar is never contacted).

# The installed Muxbar, observed from outside only (no requests to it): pid, socket, children.
user_app_pid() { pgrep -f 'Applications/Muxbar.app/Contents/MacOS/Muxbar$' | head -1; }
# Its panes' attach clients (tmux/ssh attach); the probes it runs every few seconds come and go.
user_app_children() { local p c; p=$(user_app_pid); [ -n "$p" ] || return 0
  for c in $(pgrep -P "$p"); do case "$(ps -o args= -p "$c")" in /bin/sh*|sh\ *) ;; *tmux*attach-session*|*ssh\ *attach-session*) echo "$c" ;; esac; done | sort | tr '\n' ' '; }

E32() {
  # Test-instance isolation: different pid, socket, bundle id and tmux server from the user's app;
  # stopping the test instance leaves the user's app (and its panes) exactly as they were.
  [ "$TARGET" = test ] || { skip E32 "only meaningful with TARGET=test"; return; }
  [ "$HOST" = local ] || { skip E32 "run on local"; return; }
  local upid; upid=$(user_app_pid)
  local ukids0; ukids0=$(user_app_children)
  local usock="$HOME/.muxbar/ctl.sock"
  local usock_m0; usock_m0=$(stat -f %m "$usock" 2>/dev/null)
  local info; info=$(mb info --json)
  echo "$info" > "$OUT/E32-test-info.json"
  local tpid tbid tsock tts
  tpid=$(echo "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pid"])')
  tbid=$(echo "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["bundleID"])')
  tsock=$(echo "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["socket"])')
  tts=$(echo "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["tmuxSocket"])')
  local ubid; ubid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOME/Applications/Muxbar.app/Contents/Info.plist" 2>/dev/null)
  # The user's own sessions (default tmux server) must not show up in the test instance.
  local theirs; theirs=$(command tmux list-sessions -F '#{session_name}' 2>/dev/null | sort)
  mb refresh --host local >/dev/null
  local listed_names; listed_names=$(mb list --host local | cut -f4 | sort)
  local leaked=""; for n in $theirs; do echo "$listed_names" | grep -Fxq "$n" && leaked="$leaked $n"; done
  local nonours; nonours=$(echo "$listed_names" | grep -v '^muxbar-e2e-' | grep -v '^$' | tr '\n' ' ')
  # Stop the test instance: the user's app must be unaffected.
  app_quit
  local upid2 ukids1 usock_m1; upid2=$(user_app_pid); ukids1=$(user_app_children); usock_m1=$(stat -f %m "$usock" 2>/dev/null)
  app_start
  local ok=yes reasons=""
  [ -n "$upid" ] || { ok=no; reasons="$reasons user-app-not-running"; }
  [ "$tpid" != "$upid" ] || { ok=no; reasons="$reasons same-pid"; }
  [ "$tbid" = io.github.ganeshpanaskar.muxbar.test ] && [ "$ubid" = io.github.ganeshpanaskar.muxbar ] || { ok=no; reasons="$reasons bundle:$tbid/$ubid"; }
  [ "$tsock" != "$usock" ] || { ok=no; reasons="$reasons same-socket"; }
  [ "$tts" = muxbar-e2e ] || { ok=no; reasons="$reasons tmux-socket:$tts"; }
  [ -z "$leaked" ] && [ -z "$nonours" ] || { ok=no; reasons="$reasons leaked:[$leaked] non-e2e:[$nonours]"; }
  [ "$upid2" = "$upid" ] && [ "$ukids1" = "$ukids0" ] && [ "$usock_m1" = "$usock_m0" ] || { ok=no; reasons="$reasons user-app-changed pid ${upid}→${upid2} kids [${ukids0}]→[${ukids1}]"; }
  if [ $ok = yes ]; then
    pass E32 "test pid $tpid ≠ user pid $upid; bundle $tbid vs $ubid; socket $tsock vs $usock; tmux -L $tts; the user's $(echo $theirs | wc -w | tr -d ' ') sessions not listed; after stopping the test instance the user's app kept pid, children ($(echo $ukids0 | wc -w | tr -d ' ') panes) and socket"
  else fail E32 "$reasons"; fi
}

# ---------------------------------------------------------------------------------------------
# Shared v2 helpers

STATE_DIR=/tmp/muxbar-e2e-state
PLUG=/tmp/muxbar-e2e-plugin/plugins/muxbar-status
HOOK=$PLUG/bin/muxbar-hook
FAKE=/tmp/muxbar-e2e-fake/bin

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
screen() { rsh "tmux capture-pane -p -J -t $(sq "$(idof "$1")")"; }
send_text() { local id; id=$(idof "$1"); rsh "tmux send-keys -t $(sq "$id") -l $(sq "$2")"; sleep 0.4; rsh "tmux send-keys -t $(sq "$id") Enter"; }
send_key() { rsh "tmux send-keys -t $(sq "$(idof "$1")") $2"; }
# "status source agent reason event" of a session, as Muxbar reports it.
stf() { mb status --host "$HOST" --id "$1" --json 2>/dev/null | python3 -c 'import json,sys
r=json.load(sys.stdin).get("result",{}); print(r.get("status","?"), r.get("source","?"), r.get("agent","") or "-", r.get("reason","") or "-", r.get("hookEvent","") or "-")'; }
field() { mb status --host "$HOST" --id "$1" --json 2>/dev/null | python3 -c "import json,sys
v=json.load(sys.stdin).get('result',{}).get('$2',''); print(int(v) if isinstance(v,bool) else v)"; }
deploy_helpers() { scripts/e2e-deploy.sh "$HOST" >/dev/null 2>&1; }
# Starts the trust prompt's "Yes" when a real Claude asks about a new folder.
# Returns 2 if Claude on that host first needs the user to sign in again.
accept_trust() { local i; for i in $(seq 30); do
    local t; t=$(screen "$1")
    if echo "$t" | grep -qi "please run /login\|session has expired"; then send_text "$1" n; return 2; fi
    if echo "$t" | grep -q "Yes, I trust this folder"; then send_key "$1" Down; sleep 0.4; send_key "$1" Enter; return 0; fi
    echo "$t" | grep -Eq '^(❯|›)[^A-Za-z0-9]*$' && return 0
    sleep 1; done; return 1; }
# What a person sees on an agent's screen: working | waiting | idle | shell | other.
# True if an agent (claude/codex, real or stand-in) runs anywhere in the pane's process tree.
# (pane_current_command can't tell: shell wrappers can hide the foreground job.)
agent_in_pane() {
  rsh "root=\$(tmux display -p -t $(sq "$(idof "$1")") '#{pane_pid}'); ps -A -o pid= -o ppid= -o args= | awk -v r=\"\$root\" '
    { pp[\$1] = \$2; a = \$0; sub(/^[ \\t]*[0-9]+[ \\t]+[0-9]+[ \\t]+/, \"\", a); ar[\$1] = a }
    END { for (p in pp) { q = p; d = 0
            while (d < 64 && (q in pp)) { if (q == r) { if (ar[p] ~ /(^|\\/)(claude|codex)( |$)|fake_agent/) f = 1; break }; q = pp[q]; d++ } }
          exit !f }'"
}
screen_state() {
  # Back at the shell = no agent process left in the pane (any prompt style).
  agent_in_pane "$1" || { echo shell; return; }
  local t; t=$(screen "$1" | sed '/^[[:space:]]*$/d' | tail -n 25)
  if echo "$t" | grep -q "Do you want to proceed"; then echo waiting
  elif echo "$t" | grep -Eq '^[[:space:]]*[·✢✳✶✻✽*•][[:space:]].*(…|esc to interrupt)'; then echo working
  elif echo "$t" | tail -n 6 | grep -Eq '^(❯|›)[^A-Za-z0-9]*$'; then echo idle
  else echo other; fi
}
# Samples Muxbar's status while the screen stays in state $2; every kept sample must say $3 (and
# come from the hooks unless $4=screen). Prints "matched/kept".
SAMPLES=""
take() { # take NAME SCREEN_STATE EXPECTED_STATUS COUNT [SOURCE]
  local n=0 ok=0 tries=0 want_src=${5:-hooks}
  while [ $n -lt "$4" ] && [ $tries -lt $(( $4 * 6 )) ]; do
    tries=$((tries + 1))
    local b; b=$(screen_state "$1")
    [ "$b" = "$2" ] || { sleep 0.7; continue; }
    mb refresh --host "$HOST" >/dev/null
    local got; got=$(stf "$1")
    local a; a=$(screen_state "$1")
    [ "$a" = "$2" ] || continue
    n=$((n + 1))
    local st=${got%% *} src; src=$(echo "$got" | cut -d' ' -f2)
    printf '%s\t%s\tscreen=%s\tmuxbar=%s\n' "$(date +%T)" "$3" "$b" "$got" >> "$SAMPLES"
    { [ "$st" = "$3" ] && [ "$src" = "$want_src" ]; } && ok=$((ok + 1))
    sleep 1
  done
  echo "$ok/$n"
}
wait_screen() { local t=$1 name=$2 want=$3; local end=$((SECONDS + t)); while [ $SECONDS -lt $end ]; do [ "$(screen_state "$name")" = "$want" ] && return 0; sleep 0.5; done; return 1; }

E33() {
  # Exact status from real Claude Code hooks: the plugin is loaded for this session only
  # (claude --plugin-dir), so the user's Claude configuration is never touched.
  deploy_helpers
  rsh 'zsh -lic "command -v claude" >/dev/null 2>&1' || { skip E33 "claude not installed on $HOST"; return; }
  local n=muxbar-e2e-hooks dir=/tmp/muxbar-e2e-hooks
  rsh "mkdir -p $dir $STATE_DIR"
  mb new --host "$HOST" --name "$n" --dir "$dir" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR claude --plugin-dir $PLUG --permission-mode default" --no-attach >/dev/null
  accept_trust "$n"; local at=$?
  if [ $at = 2 ]; then skip E33 "BLOCKED: claude on $HOST needs you to sign in again on $HOST"; kill_named "$n"; return; fi
  [ $at = 0 ] || { fail E33 "claude didn't start (see screen)"; screen "$n" > "$OUT/E33-screen.txt"; return; }
  wait_screen 40 "$n" idle
  SAMPLES="$OUT/E33-samples.tsv"; : > "$SAMPLES"
  local r="" lag=""
  r="$r idle:$(take "$n" idle idle 3)"
  # Working: a tool call that runs for a known time. Lag = prompt sent → Muxbar says working (no forced refresh).
  local t0; t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  send_text "$n" 'Use the Bash tool to run exactly this command and nothing else: sleep 25'
  local i; for i in $(seq 40); do [ "$(stf "$n" | cut -d' ' -f1,2)" = "working hooks" ] && break; sleep 0.25; done
  lag=$(perl -MTime::HiRes=time -e "printf '%.1f', time - $t0")
  wait_screen 20 "$n" working || { [ "$(screen_state "$n")" = waiting ] && send_key "$n" Enter; wait_screen 15 "$n" working; }
  r="$r working:$(take "$n" working working 4)"
  wait_screen 40 "$n" idle
  r="$r idle:$(take "$n" idle idle 3)"
  # Waiting: a file write needs permission in default mode.
  send_text "$n" "Use the Bash tool to run exactly this command and nothing else: touch $dir/perm-\$RANDOM.txt"
  wait_screen 40 "$n" waiting
  r="$r waiting:$(take "$n" waiting waiting 3)"
  local why; why=$(stf "$n" | cut -d' ' -f4)
  send_key "$n" Enter
  wait_screen 40 "$n" idle
  r="$r idle:$(take "$n" idle idle 3)"
  # Interrupt: Esc fires no hook; Muxbar must still reach idle (screen idle + 20s quiet).
  send_text "$n" 'Use the Bash tool to run exactly this command and nothing else: sleep 90'
  local w=no; for i in $(seq 40); do case "$(screen_state "$n")" in working) w=yes; break ;; waiting) send_key "$n" Enter ;; esac; sleep 1; done
  sleep 2; mb refresh --host "$HOST" >/dev/null
  local before_esc; before_esc=$(stf "$n" | cut -d' ' -f1,2)
  screen "$n" > "$OUT/E33-before-esc.txt"
  send_key "$n" Escape
  local ti=$SECONDS
  local ok_int=no; for i in $(seq 45); do [ "$(stf "$n" | cut -d' ' -f1)" = idle ] && { ok_int=yes; break; }; sleep 1; done
  local int_s=$((SECONDS - ti))
  screen "$n" > "$OUT/E33-after-esc.txt"
  [ "$w" = yes ] && [ "$before_esc" = "working hooks" ] || ok_int="no (not working before Esc: screen=$w muxbar=$before_esc)"
  r="$r interrupted:$(take "$n" idle idle 2)"
  # Ended: the agent exits; the pane is a shell again. (Claude puts the interrupted prompt back
  # into the input box, so clear it first.)
  send_key "$n" C-u; sleep 0.5
  send_text "$n" '/exit'
  wait_screen 20 "$n" shell
  r="$r ended:$(take "$n" shell notClaude 2 screen)"
  local id; id=$(idof "$n"); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
  local matched total; matched=$(echo "$r" | grep -o '[0-9]*/' | tr -d / | paste -sd+ - | bc); total=$(echo "$r" | grep -o '/[0-9]*' | tr -d / | paste -sd+ - | bc)
  echo "$r lag=${lag}s interrupt→idle=${int_s}s waitingReason=$why" > "$OUT/E33-summary.txt"
  # Lag = prompt sent → Muxbar shows working, without a forced refresh: Claude's own submit time
  # plus at most one poll (2 s on the test instance) plus the probe.
  if [ "$matched" = "$total" ] && [ "$total" -ge 20 ] && [ "$ok_int" = yes ] && [ "$why" = permission ] && perl -e "exit !($lag <= 4.0)"; then
    pass E33 "real Claude via hooks: $matched/$total samples match ($r); prompt→working lag ${lag}s (2s poll); Esc → idle after ${int_s}s; waiting reason=$why; samples: $SAMPLES"
  else fail E33 "matched $matched/$total ($r) lag=${lag}s interrupt=$ok_int(${int_s}s) reason=$why; see $SAMPLES"; fi
}

E34() {
  # Codex status from its hooks. Always with the stand-in codex (same hook script, Codex payloads);
  # with the real Codex only when it's installed.
  deploy_helpers
  local n=muxbar-e2e-cx
  mb new --host "$HOST" --name "$n" --dir /tmp --cmd "env MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK $FAKE/codex -m gpt-x" --no-attach >/dev/null
  wait_screen 20 "$n" idle
  SAMPLES="$OUT/E34-samples.tsv"; : > "$SAMPLES"
  local r=""
  r="$r idle:$(take "$n" idle idle 3)"
  send_text "$n" 'work 14'
  wait_screen 10 "$n" working
  r="$r working:$(take "$n" working working 4)"
  wait_screen 20 "$n" idle
  r="$r idle:$(take "$n" idle idle 3)"
  send_text "$n" 'ask'
  wait_screen 10 "$n" waiting
  r="$r waiting:$(take "$n" waiting waiting 3)"
  send_text "$n" '1'
  wait_screen 15 "$n" idle
  r="$r idle:$(take "$n" idle idle 3)"
  send_text "$n" 'work 60'
  wait_screen 10 "$n" working
  send_key "$n" C-c
  local ti=$SECONDS ok_int=no i; for i in $(seq 10); do mb refresh --host "$HOST" >/dev/null; [ "$(stf "$n" | cut -d' ' -f1,5)" = "idle Interrupt" ] && { ok_int=yes; break; }; sleep 0.5; done
  r="$r interrupted:$(take "$n" idle idle 2)"
  send_text "$n" 'quit'
  wait_screen 15 "$n" shell
  { echo "after quit:"; rsh "tmux list-sessions -F '#{session_id} #{session_name} #{session_created}'"; mb list --host "$HOST" | grep "$n"; } >> "$OUT/E34-debug.txt" 2>&1
  r="$r ended:$(take "$n" shell notClaude 2 screen)"
  local id; id=$(idof "$n"); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
  local matched total; matched=$(echo "$r" | grep -o '[0-9]*/' | tr -d / | paste -sd+ - | bc); total=$(echo "$r" | grep -o '/[0-9]*' | tr -d / | paste -sd+ - | bc)
  local real="real Codex: not installed on $HOST (SKIP)"
  rsh 'zsh -lic "command -v codex" >/dev/null 2>&1' && real="real Codex installed: run E34-real by hand"
  if [ "$matched" = "$total" ] && [ "$total" -ge 20 ] && [ $ok_int = yes ]; then
    pass E34 "stand-in codex via hooks: $matched/$total samples match ($r); Interrupt hook → idle in $((SECONDS - ti))s; $real"
  else fail E34 "matched $matched/$total ($r) interrupt=$ok_int; see $SAMPLES"; fi
}

E35() {
  # Exact resume: the conversation id recorded from the hooks is what Resume continues.
  deploy_helpers
  local ok_c="skipped (no claude)" ok_x=no
  if rsh 'zsh -lic "command -v claude" >/dev/null 2>&1'; then
    local n=muxbar-e2e-res1 dir=/tmp/muxbar-e2e-res1
    rsh "mkdir -p $dir"
    mb new --host "$HOST" --name "$n" --dir "$dir" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR claude --plugin-dir $PLUG" --no-attach >/dev/null
    accept_trust "$n"; local at=$?
    if [ $at = 2 ]; then ok_c="skipped (BLOCKED: claude on $HOST needs sign-in)"; kill_named "$n"; else
    wait_screen 40 "$n" idle
    send_text "$n" 'Reply with just the word OK.'
    local i; for i in $(seq 40); do [ "$(stf "$n" | cut -d' ' -f5)" = Stop ] && break; mb refresh --host "$HOST" >/dev/null; sleep 1; done
    local sid; sid=$(field "$n" agentSessionID)
    local tr; tr=$(rsh "ls ~/.claude/projects/*/$sid.jsonl 2>/dev/null | head -1")
    ok_c="sid=$sid transcript=$( [ -n "$tr" ] && echo found || echo missing)"
    # Simulate a reboot: the tmux session disappears behind Muxbar's back.
    rsh "tmux kill-session -t $(sq "$(idof "$n")")"
    mb refresh --host "$HOST" >/dev/null
    local st; st=$(field "$n" status)
    mb resume-ended --host "$HOST" --id "$n" > "$OUT/E35-claude-resume.txt" 2>&1
    local start; start=$(rsh "tmux display -p -t $(sq "$(idof "$n")") '#{pane_start_command}'")
    # (The id is shell-quoted inside the quoted login-shell command, so match the parts.)
    if [ -n "$sid" ] && [ -n "$tr" ] && [ "$st" = ended ] && echo "$start" | grep -q "claude --resume" && echo "$start" | grep -qF "$sid"; then ok_c="yes ($sid)"; else ok_c="no: $ok_c status=$st start=$start"; fi
    local id; id=$(idof "$n"); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
    fi
  fi
  local n2=muxbar-e2e-res2 dir2=/tmp/muxbar-e2e-res2
  rsh "mkdir -p $dir2"
  mb new --host "$HOST" --name "$n2" --dir "$dir2" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK $FAKE/codex" --no-attach >/dev/null
  wait_screen 20 "$n2" idle; mb refresh --host "$HOST" >/dev/null
  local xsid; xsid=$(field "$n2" agentSessionID)
  rsh "tmux kill-session -t $(sq "$(idof "$n2")")"
  mb refresh --host "$HOST" >/dev/null
  mb resume-ended --host "$HOST" --id "$n2" > "$OUT/E35-codex-resume.txt" 2>&1
  wait_screen 20 "$n2" idle
  local xstart; xstart=$(rsh "tmux display -p -t $(sq "$(idof "$n2")") '#{pane_start_command}'")
  # The resume command is what Muxbar controls; the stand-in itself only runs where `codex` is on
  # the login PATH (it isn't here), so the screen check is informational.
  local shown="codex not on PATH"; rsh 'zsh -lic "command -v codex" >/dev/null 2>&1' && shown=$(screen "$n2" | grep -cF "resumed $xsid")
  if [ -n "$xsid" ] && echo "$xstart" | grep -q "codex resume" && echo "$xstart" | grep -qF "$xsid" \
     && echo "$xstart" | grep -q -- " -C " && echo "$xstart" | grep -qF "$dir2"; then ok_x="yes ($xsid; screen: $shown)"; else ok_x="no: sid=$xsid start=$xstart"; fi
  local id2; id2=$(idof "$n2"); [ -n "$id2" ] && mb kill --host "$HOST" --id "$id2" --yes >/dev/null
  if { [ "${ok_c%% *}" = yes ] || [ "${ok_c%% *}" = skipped ]; } && [ "${ok_x%% *}" = yes ]; then
    pass E35 "resume uses the exact recorded conversation: claude=$ok_c; codex(stand-in)=$ok_x"
  else fail E35 "claude=$ok_c codex=$ok_x (see E35-*-resume.txt)"; fi
}

E36() {
  # Hook install/uninstall, against stub agent CLIs and throwaway folders only (the test instance
  # is started with MUXBAR_TEST_AGENT_BIN / _CODEX_HOME / _PLUGIN_DIR, never the real config).
  [ "$HOST" = local ] || { skip E36 "run on local"; return; }
  local S=/tmp/muxbar-e2e-stub CX=/tmp/muxbar-e2e-codex-home PD=/tmp/muxbar-e2e-plugin-installed
  mkdir -p "$S/bin" "$CX"; : > "$S/log"; echo ok > "$S/mode"; echo no > "$S/installed"
  cat > "$S/bin/claude" <<'STUB'
#!/bin/sh
S=/tmp/muxbar-e2e-stub
echo "$*" >> "$S/log"
case "$*" in
  "plugin list --json") if [ "$(cat $S/installed)" = yes ]; then echo '[{"id":"muxbar-status@muxbar","enabled":true}]'; else echo '[]'; fi ;;
  "plugin marketplace add"*) echo "Added marketplace muxbar" ;;
  "plugin install"*) case "$(cat $S/mode)" in policy) echo "Error: blocked by managed policy (strictKnownMarketplaces)" >&2; exit 1;; esac
                     echo yes > "$S/installed"; echo "Installed muxbar-status" ;;
  "plugin uninstall"*) echo no > "$S/installed"; echo "Uninstalled" ;;
  "plugin marketplace remove"*) echo "Removed" ;;
esac
STUB
  chmod +x "$S/bin/claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/my-notifier"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/guard"}]}]}}' > "$CX/hooks.json"
  local orig; orig=$(python3 -c "import json; print(json.dumps(json.load(open('$CX/hooks.json')), sort_keys=True))")
  local steps=""
  local o; o=$(mb hooks-install --host local --agent claude 2>&1); echo "$o" | grep -q "without --yes" && steps="${steps}refused-without-yes "
  mb hooks-install --host local --agent claude --yes > "$OUT/E36-install.txt" 2>&1
  [ "$(sed -n 1p "$S/log")" = "plugin marketplace add $PD" ] && [ "$(sed -n 2p "$S/log")" = "plugin install muxbar-status@muxbar" ] && steps="${steps}claude-install-cmds "
  [ -x "$PD/plugins/muxbar-status/bin/muxbar-hook" ] && cmp -s "$PD/plugins/muxbar-status/bin/muxbar-hook" agent-plugin/plugins/muxbar-status/bin/muxbar-hook && steps="${steps}plugin-copied "
  mb hooks-status --host local | grep -q "claude=installed" && steps="${steps}status-installed "
  : > "$S/log"; mb hooks-uninstall --host local --agent claude --yes > "$OUT/E36-uninstall.txt" 2>&1
  [ "$(sed -n 1p "$S/log")" = "plugin uninstall muxbar-status@muxbar" ] && [ "$(sed -n 2p "$S/log")" = "plugin marketplace remove muxbar" ] && steps="${steps}claude-uninstall-cmds "
  mb hooks-status --host local | grep -q "claude=notInstalled" && steps="${steps}status-removed "
  echo policy > "$S/mode"; mb hooks-install --host local --agent claude --yes > "$OUT/E36-policy.txt" 2>&1
  grep -q "outcome=blocked" "$OUT/E36-policy.txt" && steps="${steps}policy-blocked "
  # Codex: merge into hooks.json, keep the user's own handlers, back up, remove exactly ours.
  mb hooks-install --host local --agent codex --yes > "$OUT/E36-codex.txt" 2>&1
  local ours foreign backup
  ours=$(python3 -c "import json; d=json.load(open('$CX/hooks.json'))['hooks']; print(sum(1 for gs in d.values() for g in gs for h in g['hooks'] if h.get('statusMessage')=='muxbar-status'))")
  foreign=$(python3 -c "import json; d=json.load(open('$CX/hooks.json'))['hooks']; print([h['command'] for gs in d.values() for g in gs for h in g['hooks'] if h.get('statusMessage')!='muxbar-status'])")
  backup=$(ls "$CX"/hooks.json.muxbar-backup-* 2>/dev/null | head -1)
  [ "$ours" = 10 ] && echo "$foreign" | grep -q my-notifier && echo "$foreign" | grep -q guard && [ -n "$backup" ] && steps="${steps}codex-merged "
  mb hooks-uninstall --host local --agent codex --yes > "$OUT/E36-codex-un.txt" 2>&1
  local after; after=$(python3 -c "import json; print(json.dumps(json.load(open('$CX/hooks.json')), sort_keys=True))")
  [ "$after" = "$orig" ] && steps="${steps}codex-removed-exactly "
  local want="refused-without-yes claude-install-cmds plugin-copied status-installed claude-uninstall-cmds status-removed policy-blocked codex-merged codex-removed-exactly "
  if [ "$steps" = "$want" ]; then
    pass E36 "hook install/uninstall against stubs: $steps(the user's real ~/.claude and ~/.codex untouched)"
  else fail E36 "steps: '$steps' want '$want' (see E36-*.txt, $S/log)"; fi
}

# A stand-in agent session that reports through the real hook script.
fake_session() { # fake_session NAME claude|codex
  mb new --host "$HOST" --name "$1" --dir /tmp --cmd "env MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK $FAKE/$2" --no-attach >/dev/null
  wait_screen 20 "$1" idle
}
kill_named() { local n id; for n in "$@"; do id=$(idof "$n"); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null; done; }
unread_of() { field "$1" unread; }
inbox_names() { mb inbox --json | python3 -c "import json,sys; print(' '.join(r['name']+':'+r['kind'] for r in json.load(sys.stdin)['result'] if r['name'].startswith('muxbar-e2e-')))"; }
wait_field() { # wait_field SECONDS NAME FIELD VALUE
  local end=$((SECONDS + $1)); while [ $SECONDS -lt $end ]; do mb refresh --host "$HOST" >/dev/null; [ "$(field "$2" "$3")" = "$4" ] && return 0; sleep 0.5; done; return 1; }

E37() {
  # Unread + Inbox: finished or waiting while you look elsewhere → unread and in the Inbox (waiting
  # first); looking at it clears it; Mark as Unread; survives a restart.
  deploy_helpers
  kill_named muxbar-e2e-u1 muxbar-e2e-u2 muxbar-e2e-u3
  fake_session muxbar-e2e-u1 claude; fake_session muxbar-e2e-u2 claude; fake_session muxbar-e2e-u3 codex
  mb deselect >/dev/null
  mb mark-all-read >/dev/null   # start clean: earlier rows (e.g. E9) can leave unread sessions
  mb refresh --host "$HOST" >/dev/null
  local steps=""
  send_text muxbar-e2e-u1 'work 3'
  wait_field 20 muxbar-e2e-u1 unread 1 && steps="${steps}finished→unread "
  send_text muxbar-e2e-u2 'ask'
  wait_field 15 muxbar-e2e-u2 status waiting && sleep 1
  local inbox; inbox=$(inbox_names)
  [ "$inbox" = "muxbar-e2e-u2:waiting muxbar-e2e-u1:finished" ] && steps="${steps}inbox-order "
  [ "$(unread_of muxbar-e2e-u3)" = 0 ] && steps="${steps}quiet-session-untouched "
  local badge; badge=$(mb branding --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['dockBadge'])")
  [ "$badge" = 2 ] && steps="${steps}badge=2 "
  local ui; ui=$(wsnap E37-inbox)
  # Looking at it marks it read.
  mb focus --host "$HOST" --id muxbar-e2e-u1 >/dev/null
  local t0=$SECONDS; wait_field 5 muxbar-e2e-u1 unread 0 && steps="${steps}viewed→read($((SECONDS - t0))s) "
  mb mark-unread --host "$HOST" --id muxbar-e2e-u1 >/dev/null; sleep 2.5
  [ "$(unread_of muxbar-e2e-u1)" = 1 ] && steps="${steps}mark-unread-sticks "
  mb deselect >/dev/null
  app_quit; app_start; mb refresh --host "$HOST" >/dev/null
  [ "$(unread_of muxbar-e2e-u1)" = 1 ] && steps="${steps}survives-restart "
  send_text muxbar-e2e-u2 '2'
  kill_named muxbar-e2e-u1 muxbar-e2e-u2 muxbar-e2e-u3
  local want="finished→unread inbox-order quiet-session-untouched badge=2 viewed→read mark-unread-sticks survives-restart "
  if [ "$(echo "$steps" | sed 's/viewed→read([0-9]*s)/viewed→read/')" = "$want" ]; then
    pass E37 "unread/Inbox: $steps; inbox='$inbox'; ui=$ui"
  else fail E37 "steps '$steps' want '$want' (inbox='$inbox' badge=$badge)"; fi
}

E38() {
  # Finish notifications: title "<name> finished", body = start of the reply; never for the
  # session you're looking at; more than 3 at once → one notification.
  deploy_helpers
  local before; before=$(mb notified --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  new_notes() { mb notified --json | python3 -c "import json,sys; r=json.load(sys.stdin)['result'][$before:]; print('\n'.join(n['title']+' | '+n['body'] for n in r))"; }
  local claude_ok="skipped (no claude)"
  if rsh 'zsh -lic "command -v claude" >/dev/null 2>&1'; then
    local n=muxbar-e2e-fin dir=/tmp/muxbar-e2e-fin
    rsh "mkdir -p $dir"
    mb new --host "$HOST" --name "$n" --dir "$dir" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR claude --plugin-dir $PLUG" --no-attach >/dev/null
    accept_trust "$n"; local at=$?
    if [ $at = 2 ]; then claude_ok="skipped (BLOCKED: claude on $HOST needs sign-in)"
    elif [ $at = 0 ] && wait_screen 40 "$n" idle; then
      mb deselect >/dev/null
      send_text "$n" 'Reply with just the word OK and nothing else.'
      local i; for i in $(seq 40); do mb refresh --host "$HOST" >/dev/null; new_notes | grep -q "^$n finished" && break; sleep 1; done
      sleep 2
      new_notes | grep -q "^$n finished | .*OK" && claude_ok="yes ($(new_notes | grep "^$n finished" | head -1))" || claude_ok="no: $(new_notes | tr '\n' ';')"
    else claude_ok="no: claude didn't start ($(screen "$n" | grep -v '^$' | tail -2 | tr '\n' ' '))"; fi
    kill_named "$n"
  fi
  # Codex: the Stop payload's last_assistant_message is the preview.
  fake_session muxbar-e2e-fx codex
  mb deselect >/dev/null
  send_text muxbar-e2e-fx 'reply Shipped the fix; all tests pass'
  local i; for i in $(seq 20); do mb refresh --host "$HOST" >/dev/null; new_notes | grep -q "^muxbar-e2e-fx finished" && break; sleep 0.5; done
  sleep 2.5
  local codex_ok=no
  new_notes | grep -q "^muxbar-e2e-fx finished | Shipped the fix; all tests pass" && [ "$(field muxbar-e2e-fx lastReply)" = "Shipped the fix; all tests pass" ] && codex_ok=yes
  # Viewing: no notification for the session on screen.
  mb focus --host "$HOST" --id muxbar-e2e-fx >/dev/null; sleep 1
  local c1; c1=$(new_notes | grep -c "^muxbar-e2e-fx finished")
  send_text muxbar-e2e-fx 'reply second answer'
  sleep 5; mb refresh --host "$HOST" >/dev/null; sleep 2.5
  local viewed_ok=no; [ "$(new_notes | grep -c "^muxbar-e2e-fx finished")" = "$c1" ] && viewed_ok=yes
  mb deselect >/dev/null
  # Coalescing: four sessions finish together → one "4 sessions finished".
  local k; for k in 1 2 3 4; do fake_session muxbar-e2e-c$k claude; done
  local mark; mark=$(mb notified --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  for k in 1 2 3 4; do send_text muxbar-e2e-c$k 'work 2' & done; wait
  sleep 6; mb refresh --host "$HOST" >/dev/null; sleep 3
  local batch; batch=$(mb notified --json | python3 -c "import json,sys; r=json.load(sys.stdin)['result'][$mark:]; print(';'.join(n['title'] for n in r))")
  local coalesce_ok=no; [ "$batch" = "4 sessions finished" ] && coalesce_ok=yes
  kill_named muxbar-e2e-fx muxbar-e2e-c1 muxbar-e2e-c2 muxbar-e2e-c3 muxbar-e2e-c4
  if { [ "${claude_ok%% *}" = yes ] || [ "${claude_ok%% *}" = skipped ]; } && [ $codex_ok = yes ] && [ $viewed_ok = yes ] && [ $coalesce_ok = yes ]; then
    pass E38 "finish notifications: claude=$claude_ok; codex preview from payload=$codex_ok; none while viewing=$viewed_ok; 4 at once → '$batch'"
  else fail E38 "claude=$claude_ok codex=$codex_ok viewed=$viewed_ok batch='$batch'"; fi
}

memj() { mb memory --host "$HOST" --json; }
memsess() { memj | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(next((s['memoryKB'] for s in r['sessions'] if s['name']=='$1'), 0))"; }

E39() {
  # Memory: the host's totals match what the host itself reports, and a session's memory counts
  # its processes (a 512 MB allocation — under the 1 GB / 5% test cap).
  kill_named muxbar-e2e-mem
  mb new --host "$HOST" --name muxbar-e2e-mem --dir /tmp --cmd "python3 -c 'a = bytearray(512 * 1024 * 1024); import time; time.sleep(240)'" --no-attach >/dev/null
  local kb=0 i; for i in $(seq 20); do sleep 1; mb refresh --host "$HOST" >/dev/null; kb=$(memsess muxbar-e2e-mem); [ "$kb" -ge 491520 ] && break; done
  memj > "$OUT/E39-memory.json"
  local ours theirs total
  read -r ours total < <(python3 -c "import json; r=json.load(open('$OUT/E39-memory.json'))['result']; print(r['availableKB'], r['totalKB'])")
  if [ "$HOST" = local ]; then
    theirs=$(vm_stat | awk 'NR==1 { if (match($0, /page size of [0-9]+/)) ps = substr($0, RSTART + 13, RLENGTH - 13) }
      /^Pages free:/ { f = $3 } /^Pages inactive:/ { i = $3 } /^Pages speculative:/ { s = $3 } /^Pages purgeable:/ { p = $3 }
      END { gsub(/\./, "", f); gsub(/\./, "", i); gsub(/\./, "", s); gsub(/\./, "", p); printf "%d", (f + i + s + p) * ps / 1024 }')
  else
    theirs=$(rsh "awk '/^MemAvailable:/ {print \$2}' /proc/meminfo")
  fi
  local diff; diff=$(python3 -c "print(abs($ours - $theirs) * 100 / $total)")
  local tol=2; [ "$HOST" = local ] && tol=5
  local ui; ui=$(wsnap E39-memory)
  if [ "$kb" -ge 491520 ] && python3 -c "import sys; sys.exit(0 if $diff <= $tol else 1)"; then
    pass E39 "session memory $((kb / 1024)) MB for a 512 MB allocation; host available ${ours} KB vs host's own ${theirs} KB (diff ${diff}% of RAM, ≤ ${tol}%); ui=$ui"
  else fail E39 "session ${kb} KB; available ours=$ours theirs=$theirs diff=${diff}%"; fi
}

E40() {
  # A big process that left its session's process tree (setsid nohup … &) is still counted for
  # that session, via TMUX/TMUX_PANE in its environment (Linux only).
  [ "$HOST" = local ] && { skip E40 "Linux only (macOS has no /proc environ)"; return; }
  kill_named muxbar-e2e-mem2
  mb new --host "$HOST" --name muxbar-e2e-mem2 --dir /tmp --no-attach >/dev/null
  sleep 2
  send_text muxbar-e2e-mem2 "(setsid nohup python3 -c 'a = bytearray(300 * 1024 * 1024); import time; time.sleep(300)' >/dev/null 2>&1 &); echo started"
  sleep 4
  local pid; pid=$(rsh "pgrep -f 'bytearray\\(300 \\* 1024' | head -1")
  local ppid; ppid=$(rsh "ps -o ppid= -p $pid" | tr -d ' ')
  local owner kb i
  for i in $(seq 15); do
    mb refresh --host "$HOST" >/dev/null
    owner=$(memj | python3 -c "import json,sys; r=json.load(sys.stdin)['result']; print(next((t['session'] for t in r['top'] if t['pid']==${pid:-0}), ''))")
    kb=$(memsess muxbar-e2e-mem2)
    [ "$owner" = muxbar-e2e-mem2 ] && [ "$kb" -ge 296000 ] && break; sleep 1
  done
  local stopped=no
  [ -n "$pid" ] && mb stop-process --host "$HOST" --pid "$pid" --yes >/dev/null && sleep 2 && ! rsh "kill -0 $pid 2>/dev/null" && stopped=yes
  kill_named muxbar-e2e-mem2
  if [ -n "$pid" ] && [ "$ppid" != "$(rsh 'echo $PPID')" ] && [ "$owner" = muxbar-e2e-mem2 ] && [ "$kb" -ge 296000 ] && [ $stopped = yes ]; then
    pass E40 "pid $pid (parent $ppid, outside the pane's tree) attributed to $owner via TMUX_PANE; session memory $((kb / 1024)) MB; Stop… sent SIGTERM and it exited"
  else fail E40 "pid=$pid ppid=$ppid owner='$owner' kb=$kb stopped=$stopped"; fi
}

E41() {
  # Memory alerts: lowered thresholds (never by filling memory) → exactly one critical alert and a
  # red header; re-armed after raising them; a steep synthetic decline → "may run out" warning.
  local mark; mark=$(mb notified --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  alerts() { mb notified --json | python3 -c "import json,sys; r=json.load(sys.stdin)['result'][$mark:]; print('\n'.join(n['title']+' | '+n['body'] for n in r if 'memory' in n['title']))"; }
  local label; [ "$HOST" = local ] && label="This Mac" || label="$HOST"
  mb test-memory-thresholds --warn 1 --crit 2 >/dev/null
  mb refresh --host "$HOST" >/dev/null
  local n1; n1=$(alerts | grep -c "^$label memory")
  local lvl; lvl=$(memj | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['level'])")
  local ui; ui=$(wsnap E41-red)
  local k; for k in 1 2 3; do mb refresh --host "$HOST" >/dev/null; sleep 1; done
  local n2; n2=$(alerts | grep -c "^$label memory")
  mb test-memory-thresholds --warn 98 --crit 99 >/dev/null; mb refresh --host "$HOST" >/dev/null
  mb test-memory-thresholds --warn 1 --crit 2 >/dev/null; mb refresh --host "$HOST" >/dev/null
  local n3; n3=$(alerts | grep -c "^$label memory")
  mb test-memory-thresholds --clear >/dev/null
  # 1 GB/min decline over the last 2 minutes on an 8 GB host with 3 GB left → ~3 minutes left.
  local f="$OUT/E41-samples.json"
  python3 -c "import json; json.dump({'totalKB': 8388608, 'samples': [{'ago': a, 'availableKB': 3145728 + a * 17476} for a in (120, 90, 60, 30, 0)]}, open('$f','w'))"
  local tr; tr=$(mb test-memory-samples --host "$HOST" --file "$PWD/$f" --json)
  local warn; warn=$(echo "$tr" | python3 -c "import json,sys; print(';'.join(json.load(sys.stdin)['result']['alerts']))")
  mb refresh --host "$HOST" >/dev/null
  if [ "$n1" = 1 ] && [ "$lvl" = critical ] && [ "$n2" = 1 ] && [ "$n3" = 2 ] && echo "$warn" | grep -q "may run out of memory in ~3 min"; then
    pass E41 "lowered thresholds → 1 critical alert ($(alerts | head -1)), level=$lvl, none on 3 more polls, re-armed after raising (2 total); synthetic decline → '$warn'; ui=$ui"
  else fail E41 "alerts first=$n1 level=$lvl after3polls=$n2 rearmed=$n3 trend='$warn'"; fi
}

sleeping_of() { field "$1" sleeping; }
# A refused sleep exits non-zero; with pipefail, grep its message from a variable.
refuse_msg() { local o; o=$(mb sleep --host "$HOST" --id "$1" 2>&1); printf '%s\n' "$o"; }

E42() {
  # Sleep/wake with the stand-ins: sleep exits the agent (shell stays), wake resumes the same
  # conversation with the user's flags (wrapper --settings dropped); every refusal reason.
  deploy_helpers
  local res="" ag
  for ag in claude codex; do
    local n=muxbar-e2e-z$ag flags
    kill_named "$n"
    if [ $ag = claude ]; then flags="--model x --settings '{\"a\":1}'"; else flags="-m gpt-x"; fi
    mb new --host "$HOST" --name "$n" --dir /tmp --cmd "env MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK $FAKE/$ag $flags" --no-attach >/dev/null
    wait_screen 20 "$n" idle
    screen "$n" > "$OUT/E42-$ag-start.txt"
    send_text "$n" 'work 1'; sleep 4; mb refresh --host "$HOST" >/dev/null
    local steps=""
    mb sleep-check --host "$HOST" --id "$n" --json > "$OUT/E42-$ag-check.json" 2>&1
    rsh "tmux send-keys -t $(sq "$(idof "$n")") -l 'half typed'"; sleep 1.5
    refuse_msg "$n" | grep -q "typed text" && steps="${steps}refuse-typed "
    send_key "$n" C-u; sleep 1
    send_text "$n" 'work 12'; wait_screen 10 "$n" working; mb refresh --host "$HOST" >/dev/null
    refuse_msg "$n" | grep -q "is working" && steps="${steps}refuse-working "
    wait_screen 20 "$n" idle
    send_text "$n" 'ask'; wait_screen 10 "$n" waiting; mb refresh --host "$HOST" >/dev/null
    refuse_msg "$n" | grep -q "waiting" && steps="${steps}refuse-waiting "
    send_text "$n" '2'; wait_screen 15 "$n" idle
    send_text "$n" 'bg'; sleep 1.5
    local bgpid; bgpid=$(screen "$n" | sed -n 's/.*started background job \([0-9]*\).*/\1/p' | tail -1)
    refuse_msg "$n" | grep -q "background job is running (sleep)" && steps="${steps}refuse-bgjob "
    [ -n "$bgpid" ] && rsh "pkill -P $bgpid; kill $bgpid"; sleep 1; mb refresh --host "$HOST" >/dev/null
    local sid; sid=$(field "$n" agentSessionID)
    local out; out=$(mb sleep --host "$HOST" --id "$n" --json)
    printf 'bgpid=%s\n%s\n' "$bgpid" "$out" > "$OUT/E42-$ag-sleep.json"
    local freed; freed=$(echo "$out" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('result',{}).get('freedKB',0))")
    sleep 1
    { ! agent_in_pane "$n" && [ "$(sleeping_of "$n")" = 1 ] && [ "${freed:-0}" -gt 0 ]; } && steps="${steps}slept(${freed}KB) "
    # The stand-in must be what `claude`/`codex` means in this shell, as an installed agent would be.
    send_text "$n" "export PATH=$FAKE:\$PATH MUXBAR_STATE_DIR=$STATE_DIR MUXBAR_FAKE_HOOK=$HOOK"; sleep 1
    mb wake --host "$HOST" --id "$n" >/dev/null
    local i; for i in $(seq 20); do screen "$n" | grep -qF "resumed $sid" && break; sleep 0.5; done
    local fl; fl=$(screen "$n" | grep '^flags:' | tail -1)
    if [ $ag = claude ]; then echo "$fl" | grep -q -- "--model x" && ! echo "$fl" | grep -q -- "--settings" && steps="${steps}woke-with-flags "
    else echo "$fl" | grep -q -- "-m gpt-x" && echo "$fl" | grep -q -- "-C " && steps="${steps}woke-with-flags "; fi
    screen "$n" | grep -qF "resumed $sid" && [ "$(sleeping_of "$n")" = 0 ] && steps="${steps}same-conversation "
    res="$res $ag:[${steps}]"
    kill_named "$n"
  done
  local want="refuse-typed refuse-working refuse-waiting refuse-bgjob slept woke-with-flags same-conversation "
  local norm; norm=$(echo "$res" | sed 's/slept([0-9]*KB)/slept/g')
  if [ "$norm" = " claude:[$want] codex:[$want]" ]; then pass E42 "sleep/wake (stand-ins):$res"
  else fail E42 "got:$res want claude/codex:[$want]"; fi
}

E43() {
  # Real Claude: sleep frees its memory; waking continues the same conversation.
  rsh 'zsh -lic "command -v claude" >/dev/null 2>&1' || { skip E43 "claude not installed on $HOST"; return; }
  deploy_helpers
  local n=muxbar-e2e-pel dir=/tmp/muxbar-e2e-pel
  kill_named "$n"; rsh "mkdir -p $dir"
  mb new --host "$HOST" --name "$n" --dir "$dir" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR claude --plugin-dir $PLUG" --no-attach >/dev/null
  accept_trust "$n"; local at=$?
  if [ $at = 2 ]; then skip E43 "BLOCKED: claude on $HOST needs you to sign in again on $HOST"; kill_named "$n"; return; fi
  wait_screen 40 "$n" idle
  send_text "$n" 'Remember the word PELICAN. Reply with just OK.'
  local i; for i in $(seq 60); do mb refresh --host "$HOST" >/dev/null; [ "$(stf "$n" | cut -d' ' -f1,5)" = "idle Stop" ] && break; sleep 1; done
  local out; out=$(mb sleep --host "$HOST" --id "$n" --json)
  local freed; freed=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('freedKB',0))")
  local err; err=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',''))")
  sleep 1
  local gone=no; agent_in_pane "$n" || gone=yes
  send_text "$n" "export MUXBAR_STATE_DIR=$STATE_DIR"; sleep 1
  mb wake --host "$HOST" --id "$n" >/dev/null
  wait_screen 60 "$n" idle
  sleep 2
  send_text "$n" 'What word did I ask you to remember? Reply with just the word.'
  for i in $(seq 60); do mb refresh --host "$HOST" >/dev/null; [ "$(stf "$n" | cut -d' ' -f1,5)" = "idle Stop" ] && break; sleep 1; done
  sleep 2
  local reply; reply=$(field "$n" lastReply)
  screen "$n" > "$OUT/E43-screen.txt"
  kill_named "$n"
  # Not `echo … | grep -q`: under pipefail, grep exiting early fails the pipe (SIGPIPE) on long text.
  if [ $gone = yes ] && [ "${freed:-0}" -gt 0 ] && grep -q PELICAN <<< "$reply $(cat "$OUT/E43-screen.txt")"; then
    pass E43 "real Claude slept (freed $((freed / 1024)) MB, process gone) and woke into the same conversation: reply '$reply'"
  else fail E43 "gone=$gone freed=$freed err='$err' reply='$reply' (see E43-screen.txt)"; fi
}

E44() {
  # Auto-sleep: only an idle agent that isn't on screen, has no input since it finished, no
  # background job and isn't marked Never Sleep goes to sleep.
  [ "$HOST" = local ] || { skip E44 "run on local"; return; }
  deploy_helpers
  local k; for k in 1 2 3 4 5; do kill_named muxbar-e2e-y$k; fake_session muxbar-e2e-y$k claude; done
  mb settings-set --auto-sleep-min 1 >/dev/null
  # y5: open in Muxbar's pane, finish, then type in it (input since it finished).
  mb focus --host "$HOST" --id muxbar-e2e-y5 >/dev/null; sleep 2
  for k in 1 2 3 4 5; do send_text muxbar-e2e-y$k 'work 1'; done
  sleep 4
  mb type --host "$HOST" --id muxbar-e2e-y5 --text ' ' --no-enter >/dev/null
  send_text muxbar-e2e-y3 'bg'
  mb never-sleep --host "$HOST" --id muxbar-e2e-y4 --value on >/dev/null
  mb focus --host "$HOST" --id muxbar-e2e-y2 >/dev/null   # y2 on screen
  local t0=$SECONDS i
  for i in $(seq 150); do [ "$(sleeping_of muxbar-e2e-y1)" = 1 ] && break; sleep 1; done
  local dt=$((SECONDS - t0))
  sleep 12
  local got=""; for k in 1 2 3 4 5; do got="$got y$k=$(sleeping_of muxbar-e2e-y$k)"; done
  mb settings-set --auto-sleep-min 0 >/dev/null
  local bg; bg=$(screen muxbar-e2e-y3 | sed -n 's/.*started background job \([0-9]*\).*/\1/p' | tail -1)
  [ -n "$bg" ] && rsh "pkill -P $bg; kill $bg" 2>/dev/null
  for k in 1 2 3 4 5; do kill_named muxbar-e2e-y$k; done
  mb deselect >/dev/null
  if [ "$got" = " y1=1 y2=0 y3=0 y4=0 y5=0" ]; then
    pass E44 "auto-sleep after 1 min idle: y1 slept after ${dt}s; on screen (y2), background job (y3), Never Sleep (y4), typed since finishing (y5) stayed awake"
  else fail E44 "got:$got (after ${dt}s)"; fi
}

# ---------------------------------------------------------------------------------------------
# F5: drops

DROPS=/tmp/muxbar-e2e-drops
host_sha() { rsh "sha256sum $(sq "$1") 2>/dev/null || shasum -a 256 $(sq "$1")" | awk '{print $1}'; }
wait_prompt() { local i; sleep 1; for i in $(seq 30); do [ -n "$(input_line "$1")" ] && return 0; sleep 0.5; done; return 1; }
input_line() { screen "$1" | grep -v '^[[:space:]]*$' | tail -1; }
# A 2 MB PNG of noise (incompressible), written locally.
make_png() { python3 - "$1" "$2" <<'PY'
import os, struct, sys, zlib
out, side = sys.argv[1], int(sys.argv[2])
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\0" + os.urandom(side * 3) for _ in range(side))
open(out, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
                       + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
PY
}

E45() {
  # Drop to a remote session: the file arrives intact under ~/.muxbar/drops, its path is pasted
  # (not run), and drops older than 7 days are cleaned up on the next probe.
  [ "$HOST" != local ] || { skip E45 "run on a remote host"; return; }
  local n=muxbar-e2e-drop; kill_named "$n"
  mkdir -p "$DROPS"; make_png "$DROPS/noise shot.png" 820
  mb new --host "$HOST" --name "$n" --dir /tmp --no-attach >/dev/null; wait_prompt "$n"
  local steps="" out p
  out=$(mb drop --host "$HOST" --id "$n" --file "$DROPS/noise shot.png" --json)
  echo "$out" > "$OUT/E45-drop.json"
  p=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0])" 2>/dev/null)
  case "$p" in */.muxbar/drops/20??-??-??/[0-9][0-9][0-9][0-9][0-9][0-9]-noise-shot.png) steps="${steps}named " ;; esac
  [ -n "$p" ] && [ "$(host_sha "$p")" = "$(shasum -a 256 "$DROPS/noise shot.png" | awk '{print $1}')" ] && steps="${steps}sha256-equal "
  [ "$(rsh "stat -c %a $(sq "$p") 2>/dev/null || stat -f %Lp $(sq "$p")")" = 600 ] && steps="${steps}private "
  sleep 1; screen "$n" > "$OUT/E45-screen.txt"
  input_line "$n" | grep -qF "$p" && steps="${steps}path-on-input-line "
  ! grep -qiE "denied|not found|no such|cannot execute" "$OUT/E45-screen.txt" && steps="${steps}nothing-ran "
  send_key "$n" C-u; sleep 0.5
  # The pane's drag handler: raw PNG data (a screenshot thumbnail) is saved, copied and pasted.
  mb focus --host "$HOST" --id "$n" >/dev/null; sleep 2
  mb test-drag --host "$HOST" --id "$n" --png "$DROPS/noise shot.png" >/dev/null
  local q="" i; for i in $(seq 30); do q=$(input_line "$n" | grep -o '/[^ ]*-dropped\.png' | tail -1); [ -n "$q" ] && break; sleep 0.5; done
  [ -n "$q" ] && [ "$(host_sha "$q")" = "$(shasum -a 256 "$DROPS/noise shot.png" | awk '{print $1}')" ] && steps="${steps}drag-image "
  send_key "$n" C-u; sleep 0.5; [ -n "$q" ] && rsh "rm -f $(sq "$q")"
  mb deselect >/dev/null
  # Folders are refused; > 100 MB asks before copying.
  local msg; msg=$(mb drop --host "$HOST" --id "$n" --file "$DROPS" 2>&1)
  echo "$msg" | grep -q "not folders" && steps="${steps}folder-refused "
  mkfile -n 101m "$DROPS/big.bin"; msg=$(mb drop --host "$HOST" --id "$n" --file "$DROPS/big.bin" 2>&1); rm -f "$DROPS/big.bin"
  echo "$msg" | grep -q "confirm" && steps="${steps}big-asks "
  # Cleanup: an 8-day-old drop goes on the next probe; a fresh one stays.
  local d=~/.muxbar/drops t; t=$(( $(date +%s) - 8 * 86400 ))
  rsh "mkdir -p $d/2026-01-01 && echo old > $d/2026-01-01/e2e-old.txt && (touch -d @$t $d/2026-01-01/e2e-old.txt 2>/dev/null || touch -t \$(date -r $t +%Y%m%d%H%M.%S) $d/2026-01-01/e2e-old.txt)"
  mb refresh --host "$HOST" >/dev/null
  rsh "test -e $d/2026-01-01/e2e-old.txt || test -d $d/2026-01-01 || echo gone" | grep -q gone && rsh "test -f $(sq "$p") && echo kept" | grep -q kept && steps="${steps}cleanup "
  rsh "rm -f $(sq "$p")"
  kill_named "$n"
  local want="named sha256-equal private path-on-input-line nothing-ran drag-image folder-refused big-asks cleanup "
  if [ "$steps" = "$want" ]; then pass E45 "2 MB drop → $p (sha256 equal, mode 600), path pasted not run, dragged image data copied intact, folder refused, 101 MB asks first, 8-day-old drop cleaned, fresh kept"
  else fail E45 "steps '$steps' want '$want' (see E45-*.txt)"; fi
}

E46() {
  # Drop to a local session: the local path is pasted as is (quoted), the file is untouched;
  # >100 MB asks first.
  [ "$HOST" = local ] || { skip E46 "run on local"; return; }
  local n=muxbar-e2e-dropl; kill_named "$n"
  mkdir -p "$DROPS"; make_png "$DROPS/my shot.png" 64
  local f="$DROPS/my shot.png" sha0 m0; sha0=$(shasum -a 256 "$f" | awk '{print $1}'); m0=$(stat -f %m "$f")
  mb new --host local --name "$n" --dir /tmp --no-attach >/dev/null; wait_prompt "$n"
  local steps="" out
  out=$(mb drop --host local --id "$n" --file "$f" --json); echo "$out" > "$OUT/E46-drop.json"
  [ "$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0])" 2>/dev/null)" = "$f" ] && steps="${steps}local-path "
  sleep 1; screen "$n" > "$OUT/E46-screen.txt"
  input_line "$n" | grep -qF "'$f'" && steps="${steps}quoted-on-input-line "
  [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$sha0" ] && [ "$(stat -f %m "$f")" = "$m0" ] && steps="${steps}untouched "
  send_key "$n" C-u; sleep 0.5
  # The pane's drag handler with Finder-style file URLs.
  mb focus --host local --id "$n" >/dev/null; sleep 2
  mb test-drag --host local --id "$n" --file "$f" >/dev/null; sleep 1.5
  input_line "$n" | grep -qF "'$f'" && steps="${steps}drag-file "
  send_key "$n" C-u; sleep 0.5; mb deselect >/dev/null
  # A big local file isn't copied, so it doesn't ask.
  mkfile -n 101m "$DROPS/big.bin"
  mb drop --host local --id "$n" --file "$DROPS/big.bin" >/dev/null 2>&1 && sleep 1 && input_line "$n" | grep -qF "big.bin" && steps="${steps}big-no-ask "
  send_key "$n" C-u; rm -f "$DROPS/big.bin"
  kill_named "$n"
  local want="local-path quoted-on-input-line untouched drag-file big-no-ask "
  if [ "$steps" = "$want" ]; then pass E46 "local drop pasted '$f' (quoted, not submitted), file untouched; a 101 MB local file pasted without copying or asking"
  else fail E46 "steps '$steps' want '$want' (see E46-*.txt)"; fi
}

E47() {
  # A real Claude reads an image dropped into its session.
  rsh 'zsh -lic "command -v claude" >/dev/null 2>&1' || { skip E47 "claude not installed on $HOST"; return; }
  deploy_helpers
  local n=muxbar-e2e-img dir=/tmp/muxbar-e2e-img
  kill_named "$n"; rsh "mkdir -p $dir"; mkdir -p "$DROPS"
  mb test-render-text --text MUXBAR-42 --out "$PWD/$OUT/E47-muxbar42.png" >/dev/null
  mb new --host "$HOST" --name "$n" --dir "$dir" --cmd "env MUXBAR_STATE_DIR=$STATE_DIR claude --plugin-dir $PLUG" --no-attach >/dev/null
  accept_trust "$n"; local at=$?
  if [ $at = 2 ]; then skip E47 "BLOCKED: claude on $HOST needs you to sign in again on $HOST"; kill_named "$n"; return; fi
  wait_screen 40 "$n" idle; sleep 2
  local out; out=$(mb drop --host "$HOST" --id "$n" --file "$PWD/$OUT/E47-muxbar42.png" --json); echo "$out" > "$OUT/E47-drop.json"
  sleep 2; screen "$n" > "$OUT/E47-after-drop.txt"
  local attached=no; grep -q "\[Image #1\]" "$OUT/E47-after-drop.txt" && attached=yes
  send_text "$n" 'What text is in this image? Reply with just the text.'
  local i; for i in $(seq 90); do
    mb refresh --host "$HOST" >/dev/null
    [ "$(stf "$n" | cut -d' ' -f1,5)" = "idle Stop" ] && break
    [ "$(screen_state "$n")" = waiting ] && send_key "$n" Enter   # e.g. permission to read the file
    sleep 1
  done
  sleep 2
  local reply; reply=$(field "$n" lastReply)
  screen "$n" > "$OUT/E47-screen.txt"
  kill_named "$n"
  local p; p=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0])" 2>/dev/null)
  [ "$HOST" != local ] && [ -n "$p" ] && rsh "rm -f $(sq "$p")"
  if grep -q "MUXBAR-42" <<< "$reply $(cat "$OUT/E47-screen.txt")"; then
    pass E47 "real Claude read the dropped image: reply '$reply' (pasted path attached as an image: $attached)"
  else fail E47 "reply '$reply' attached=$attached (see E47-*.txt)"; fi
}

# ---------------------------------------------------------------------------------------------
# F11: first-launch setup, adding/removing remote hosts, root changes

# A second test instance with a fresh home of its own; the main test instance keeps running.
fresh_start() { F=/tmp/mbxf-$1; mkdir -p "$F"; MUXBAR_HOME="$F" scripts/test-instance.sh start >/dev/null; }
fresh_stop() { MUXBAR_HOME="$F" scripts/test-instance.sh stop >/dev/null; }
mbf() { MUXBAR_HOME="$F" perl -e 'alarm 90; exec @ARGV' "$M" --cli "$@"; }
# jget a.b.0 < json: a value from {"result": …} (strings bare, everything else as JSON).
jget() { python3 -c "import json,sys
r=json.load(sys.stdin); r=r.get('result', r)
for k in sys.argv[1].split('.'): r = r[int(k)] if isinstance(r, list) else r[k]
print(r if isinstance(r, str) else json.dumps(r))" "$1" 2>/dev/null; }
host_names() { python3 -c "import json,sys; print(' '.join(h['host'] for h in json.load(sys.stdin)['result']))"; }
SETUP_HOST=${SETUP_HOST:-devbox}

E54() {
  # First-launch setup: only a fresh home asks; Done saves the root and the remote host and it
  # isn't asked again; Skip adds nothing. The main test instance (existing state) never asked.
  [ "$HOST" = local ] || { skip E54 "run on local"; return; }
  local steps="" st i
  st=$(mb setup-status --json)
  [ "$(echo "$st" | jget needsSetup)" = false ] && [ "$(echo "$st" | jget setupDone)" = true ] && [ "$(echo "$st" | jget windowOpen)" = false ] && steps="${steps}existing-not-asked "
  fresh_start e54-$$
  for i in $(seq 20); do [ "$(mbf setup-status --json | jget windowOpen)" = true ] && break; sleep 0.5; done
  st=$(mbf setup-status --json); echo "$st" > "$OUT/E54-fresh.json"
  [ "$(echo "$st" | jget needsSetup)" = true ] && [ "$(echo "$st" | jget windowOpen)" = true ] && steps="${steps}fresh-asked "
  mbf snapshot --what setup --out "$PWD/$OUT/E54-setup.png" >/dev/null && steps="${steps}snapshot "
  mbf setup-apply --root /tmp/muxbar-e2e-root --host "$SETUP_HOST" --host-root /tmp/muxbar-e2e-root --json > "$OUT/E54-apply.json"
  st=$(mbf setup-status --json); echo "$st" > "$OUT/E54-after.json"
  [ "$(echo "$st" | jget needsSetup)" = false ] && [ "$(echo "$st" | jget windowOpen)" = false ] \
    && [ "$(echo "$st" | jget hosts)" = "[\"local\", \"$SETUP_HOST\"]" ] \
    && [ "$(echo "$st" | jget roots.local)" = /tmp/muxbar-e2e-root ] && [ "$(echo "$st" | jget "roots.$SETUP_HOST")" = /tmp/muxbar-e2e-root ] \
    && steps="${steps}applied "
  MUXBAR_HOME="$F" scripts/test-instance.sh restart >/dev/null; sleep 3
  st=$(mbf setup-status --json)
  [ "$(echo "$st" | jget needsSetup)" = false ] && [ "$(echo "$st" | jget windowOpen)" = false ] && [ "$(echo "$st" | jget hosts.1)" = "$SETUP_HOST" ] && steps="${steps}not-asked-again "
  fresh_stop
  fresh_start e54s-$$; sleep 2
  mbf setup-apply --skip >/dev/null
  st=$(mbf setup-status --json)
  [ "$(echo "$st" | jget needsSetup)" = false ] && [ "$(echo "$st" | jget hosts)" = '["local"]' ] && [ "$(echo "$st" | jget windowOpen)" = false ] && steps="${steps}skip "
  fresh_stop
  local want="existing-not-asked fresh-asked snapshot applied not-asked-again skip "
  if [ "$steps" = "$want" ]; then pass E54 "setup window only on a fresh home ($OUT/E54-setup.png); Done saved root /tmp/muxbar-e2e-root and $SETUP_HOST; not asked after a restart; Skip added nothing"
  else fail E54 "steps '$steps' want '$want' (see E54-*.json)"; fi
}

E55() {
  # Adding, checking and removing remote hosts: plain-words results, addresses that could inject
  # ssh options refused, and removing a host keeps its tmux sessions running there.
  [ "$HOST" != local ] || { skip E55 "run with a remote HOST"; return; }
  local steps="" c m1 m2
  c=$(mb host-check --host "$HOST" --json); echo "$c" > "$OUT/E55-check-ok.json"
  [ "$(echo "$c" | jget kind)" = ok ] && echo "$c" | jget message | grep -q "^Connected · Linux · tmux " && steps="${steps}check-ok "
  c=$(mb host-check --host nonexistent.invalid --json); echo "$c" > "$OUT/E55-check-dns.json"
  [ "$(echo "$c" | jget kind)" = dns ] && steps="${steps}check-dns "
  m1=$(mb hosts-add --host '-oProxyCommand=touch /tmp/muxbar-e2e-pwned' 2>&1); m2=$(mb host-check --host '-oProxyCommand=touch /tmp/muxbar-e2e-pwned' 2>&1)
  sleep 1
  echo "$m1" | grep -q "no options" && echo "$m2" | grep -q "no options" && [ ! -e /tmp/muxbar-e2e-pwned ] && steps="${steps}injection-refused "
  m1=$(mb hosts-add --host "$HOST" 2>&1); m2=$(mb hosts-add --host local 2>&1)
  echo "$m1" | grep -q "already added" && echo "$m2" | grep -q "this Mac" && steps="${steps}dup-and-local-refused "
  # Remove and re-add on a fresh instance (the main one keeps its hosts).
  fresh_start e55-$$; sleep 2
  mbf setup-apply --skip >/dev/null; mbf hosts-add --host "$HOST" >/dev/null
  local n=muxbar-e2e-rm; mbf new --host "$HOST" --name $n --dir /tmp --no-attach >/dev/null; mbf refresh --host "$HOST" >/dev/null
  m1=$(mbf hosts-remove --host "$HOST" 2>&1)
  echo "$m1" | grep -q "Pass --yes" && steps="${steps}remove-asks "
  mbf hosts-remove --host "$HOST" --yes >/dev/null
  ! mbf hosts --json | host_names | grep -qw "$HOST" && tmux_has $n && steps="${steps}removed-session-kept "
  mbf hosts-add --host "$HOST" >/dev/null; mbf refresh --host "$HOST" >/dev/null
  mbf list --host "$HOST" | cut -f4 | grep -Fxq $n && steps="${steps}re-added-found "
  fresh_stop
  mb refresh --host "$HOST" >/dev/null; kill_named $n
  local want="check-ok check-dns injection-refused dup-and-local-refused remove-asks removed-session-kept re-added-found "
  if [ "$steps" = "$want" ]; then pass E55 "check: '$(jget message < "$OUT/E55-check-ok.json")', nonexistent.invalid → dns; -oProxyCommand refused (nothing ran); duplicates and 'local' refused; remove asks, keeps the tmux session, re-adding finds it"
  else fail E55 "steps '$steps' want '$want' (see E55-*.json)"; fi
}

E56() {
  # A root change affects new sessions only: an old session stays under its own root through
  # rename, group moves and group renames (one group folder per root); nothing lands in the new root.
  [ "$HOST" != local ] || { skip E56 "run with a remote HOST"; return; }
  local A=/tmp/muxbar-e2e-rootA B=/tmp/muxbar-e2e-rootB g=e2e-rg steps=""
  kill_named muxbar-e2e-ra muxbar-e2e-ra2 muxbar-e2e-rb
  mb group-delete --host "$HOST" --name $g >/dev/null 2>&1; mb group-delete --host "$HOST" --name ${g}2 >/dev/null 2>&1
  rsh "rm -rf $A $B"
  mb settings-set --root-host "$HOST" --root $A >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-ra --no-attach >/dev/null
  mb settings-set --root-host "$HOST" --root $B >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-rb --no-attach >/dev/null
  [ "$(field muxbar-e2e-ra path)" = $A/muxbar-e2e-ra ] && [ "$(field muxbar-e2e-rb path)" = $B/muxbar-e2e-rb ] && steps="${steps}new-uses-current-root "
  mb rename --host "$HOST" --id muxbar-e2e-ra --name muxbar-e2e-ra2 >/dev/null
  [ "$(field muxbar-e2e-ra2 path)" = $A/muxbar-e2e-ra2 ] && [ "$(rsh "test -d $A/muxbar-e2e-ra2 && test ! -e $B/muxbar-e2e-ra2 && echo y")" = y ] && steps="${steps}rename-stays "
  mb group-create --host "$HOST" --name $g >/dev/null
  mb group-set --host "$HOST" --id muxbar-e2e-ra2 --group $g >/dev/null; mb group-set --host "$HOST" --id muxbar-e2e-rb --group $g >/dev/null
  [ "$(field muxbar-e2e-ra2 path)" = $A/$g/muxbar-e2e-ra2 ] && [ "$(field muxbar-e2e-rb path)" = $B/$g/muxbar-e2e-rb ] && steps="${steps}group-move-stays "
  mb group-rename --host "$HOST" --name $g --to ${g}2 >/dev/null
  [ "$(field muxbar-e2e-ra2 path)" = $A/${g}2/muxbar-e2e-ra2 ] && [ "$(field muxbar-e2e-rb path)" = $B/${g}2/muxbar-e2e-rb ] \
    && [ "$(rsh "test -d $A/${g}2/muxbar-e2e-ra2 && test -d $B/${g}2/muxbar-e2e-rb && test ! -e $A/$g && test ! -e $B/$g && echo y")" = y ] && steps="${steps}group-rename-per-root "
  mb group-delete --host "$HOST" --name ${g}2 >/dev/null
  [ "$(field muxbar-e2e-ra2 path)" = $A/muxbar-e2e-ra2 ] && [ "$(field muxbar-e2e-rb path)" = $B/muxbar-e2e-rb ] \
    && [ "$(rsh "test ! -e $A/${g}2 && test ! -e $B/${g}2 && echo y")" = y ] && steps="${steps}group-delete-per-root "
  rsh "ls -R $A $B" > "$OUT/E56-tree.txt" 2>&1
  kill_named muxbar-e2e-ra2 muxbar-e2e-rb
  mb settings-set --root-host "$HOST" --root "" >/dev/null
  rsh "rm -rf $A $B"
  local want="new-uses-current-root rename-stays group-move-stays group-rename-per-root group-delete-per-root "
  if [ "$steps" = "$want" ]; then pass E56 "root A → B: new sessions under B; the old one renamed, grouped, group-renamed and ungrouped entirely within A (one group folder per root); nothing moved into B"
  else fail E56 "steps '$steps' want '$want' (see E56-tree.txt)"; fi
}

# ---------------------------------------------------------------------------------------------
# F7 ⌘K switcher, F10 grid

tmux_width() { rsh "tmux display-message -p -t $(sq "$(idof "$1")") '#{window_width}'" | tr -d ' \n'; }

E48() {
  # ⌘K switcher: fuzzy match on name and group, needs-you first on an empty query, opening a row
  # selects it; snapshot of the palette with a query.
  deploy_helpers
  local steps="" r
  kill_named muxbar-e2e-alpha muxbar-e2e-beta muxbar-e2e-gamma
  mb group-delete --host "$HOST" --name e2e-grp >/dev/null 2>&1
  fake_session muxbar-e2e-alpha claude; fake_session muxbar-e2e-beta claude; fake_session muxbar-e2e-gamma claude
  mb group-create --host "$HOST" --name e2e-grp >/dev/null; mb group-set --host "$HOST" --id muxbar-e2e-beta --group e2e-grp >/dev/null
  r=$(mb switcher --query bet --json); echo "$r" > "$OUT/E48-bet.json"
  [ "$(echo "$r" | jget 0.name)" = muxbar-e2e-beta ] && steps="${steps}bet "
  r=$(mb switcher --query "grp bet" --json)
  [ "$(echo "$r" | jget 0.name)" = muxbar-e2e-beta ] && steps="${steps}grp-bet "
  send_text muxbar-e2e-gamma 'ask'; wait_screen 15 muxbar-e2e-gamma waiting; wait_field 20 muxbar-e2e-gamma status waiting
  r=$(mb switcher --query "" --json); echo "$r" > "$OUT/E48-empty.json"
  [ "$(echo "$r" | jget 0.name)" = muxbar-e2e-gamma ] && [ "$(echo "$r" | jget 0.section)" = "Needs you" ] && steps="${steps}needs-you-first "
  mb switcher-open --query "" --index 0 >/dev/null; sleep 1
  [ "$(mb layout --json | jget selected)" = muxbar-e2e-gamma ] && steps="${steps}opened "
  mb switcher-show --query "e2e alp" >/dev/null; sleep 1.5
  wsnap E48-switcher >/dev/null && steps="${steps}snapshot "
  mb switcher-hide >/dev/null
  send_text muxbar-e2e-gamma '2'; sleep 1
  mb deselect >/dev/null
  kill_named muxbar-e2e-alpha muxbar-e2e-beta muxbar-e2e-gamma; mb group-delete --host "$HOST" --name e2e-grp >/dev/null 2>&1
  local want="bet grp-bet needs-you-first opened snapshot "
  if [ "$steps" = "$want" ]; then pass E48 "'bet' and 'grp bet' → beta first; empty query → gamma (waiting) first under Needs you; opening row 0 selected gamma ($OUT/E48-switcher.png)"
  else fail E48 "steps '$steps' want '$want' (see E48-*.json)"; fi
}

E51() {
  # Grid: 4 live tiles, each tmux window sized to its tile; keystrokes go only to the focused
  # tile; the grid survives a restart; clearing it gives every pane the single-view size back.
  local steps="" k i w ok
  deploy_helpers
  # g4 is a stand-in agent (for the unread rule); the others are plain shells.
  for k in 1 2 3 4; do kill_named muxbar-e2e-g$k; done
  for k in 1 2 3; do mb new --host "$HOST" --name muxbar-e2e-g$k --dir /tmp --no-attach >/dev/null; done
  fake_session muxbar-e2e-g4 claude
  for k in 1 2 3; do wait_prompt muxbar-e2e-g$k; done
  mb focus --host "$HOST" --id muxbar-e2e-g1 >/dev/null
  # The single-view width: the pane's own columns, once tmux has resized to them (a remote attach
  # takes a moment; until then a detached session is 80 wide).
  local single="" pc
  for i in $(seq 40); do pc=$(mb layout --json | jget selectedSize.cols); w=$(tmux_width muxbar-e2e-g1)
    [ -n "$pc" ] && [ "$w" = "$pc" ] && { single=$w; break; }; sleep 0.5; done
  : > "$OUT/E51-sizes.txt"
  mb grid --host "$HOST" --ids muxbar-e2e-g1,muxbar-e2e-g2,muxbar-e2e-g3,muxbar-e2e-g4 --json > "$OUT/E51-grid.json"; sleep 3
  local L; L=$(mb layout --json); echo "$L" > "$OUT/E51-layout.json"
  [ "$(echo "$L" | jget mode)" = grid ] && [ "$(echo "$L" | jget tiles | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 4 ] && steps="${steps}4-tiles "
  ok=yes
  for i in 0 1 2 3; do
    local nm cols; nm=$(echo "$L" | jget tiles.$i.name); cols=$(echo "$L" | jget tiles.$i.cols); w=$(tmux_width "$nm")
    echo "$nm tile-cols=$cols tmux=$w single=$single" >> "$OUT/E51-sizes.txt"
    { [ -n "$w" ] && [ -n "$cols" ] && [ $((w - cols)) -le 1 ] && [ $((cols - w)) -le 1 ] && [ "$w" -lt "$single" ]; } || ok=no
  done
  [ $ok = yes ] && steps="${steps}tmux-sized-to-tiles "
  mb grid-focus --index 2 >/dev/null; sleep 1
  local to; to=$(mb test-type-focused --text 'echo GRIDKEY-51' --json | jget to); sleep 1.5
  # zsh may break a long line at the margin itself (not a tmux wrap), so join lines first.
  local hits=""; for k in 1 2 3 4; do grep -q GRIDKEY-51 <<< "$(screen muxbar-e2e-g$k | tr -d '\n')" && hits="$hits g$k"; done
  [ "$to" = muxbar-e2e-g3 ] && [ "$hits" = " g3" ] && steps="${steps}keys-to-focused-only "
  send_key muxbar-e2e-g3 C-u
  # Unread: g4 finishes while g3 has focus → unread, then read after ~3 s on screen.
  send_text muxbar-e2e-g4 'work 1'
  local t0=$SECONDS got=""
  for i in $(seq 30); do mb refresh --host "$HOST" >/dev/null; [ "$(unread_of muxbar-e2e-g4)" = 1 ] && { got=unread; break; }; sleep 0.5; done
  local t1=$SECONDS
  for i in $(seq 20); do [ "$(unread_of muxbar-e2e-g4)" = 0 ] && { got="$got-read"; break; }; sleep 0.5; done
  echo "g4 $got after $((SECONDS - t1))s (finished after $((t1 - t0))s)" >> "$OUT/E51-sizes.txt"
  [ "$got" = unread-read ] && [ $((SECONDS - t1)) -ge 2 ] && steps="${steps}visible-tile-read "
  wsnap E51-grid >/dev/null && steps="${steps}snapshot "
  app_quit; app_start; sleep 8
  L=$(mb layout --json); echo "$L" > "$OUT/E51-restored.json"
  [ "$(echo "$L" | jget mode)" = grid ] && [ "$(echo "$L" | jget tiles.3.name)" = muxbar-e2e-g4 ] && steps="${steps}restored "
  mb grid-clear >/dev/null; sleep 2
  ok=yes
  for k in 1 2 3 4; do w=$(tmux_width muxbar-e2e-g$k); echo "after clear g$k=$w" >> "$OUT/E51-sizes.txt"
    { [ -n "$w" ] && [ $((single - w)) -le 1 ] && [ $((w - single)) -le 1 ]; } || ok=no; done
  [ $ok = yes ] && steps="${steps}clear-restores-size "
  mb deselect >/dev/null
  for k in 1 2 3 4; do kill_named muxbar-e2e-g$k; done
  local want="4-tiles tmux-sized-to-tiles keys-to-focused-only visible-tile-read snapshot restored clear-restores-size "
  if [ "$steps" = "$want" ]; then pass E51 "4 tiles; each tmux window = its tile's width (single $single cols, see E51-sizes.txt); typing reached only the focused tile; a visible unfocused tile that finished went unread, then read after ~3 s; restored after restart; clear gave all 4 the single width back ($OUT/E51-grid.png)"
  else fail E51 "steps '$steps' want '$want' (see E51-*.json, E51-sizes.txt)"; fi
}

# ---------------------------------------------------------------------------------------------
# F8: port forwarding

port_field() { mb ports --host "$HOST" --json | python3 -c "import json,sys
r=[x for x in json.load(sys.stdin).get('result',[]) if x['port']==$1]; v=r[0]['$2'] if r else ''
print(int(v) if isinstance(v,bool) else v)"; }
curl_tok() { curl -s --max-time 4 "http://127.0.0.1:$1/" 2>/dev/null | tr -d '\n'; }

E49() {
  # A server in a session is listed with its owner; forward → curl through localhost; it comes
  # back after the ssh master drops and after a restart; unforward → gone. 0.0.0.0 listed, 22 not.
  [ "$HOST" != local ] || { skip E49 "run with a remote HOST"; return; }
  local n=muxbar-e2e-ports n2=muxbar-e2e-ports2 www=/tmp/muxbar-e2e-dir/www tok="muxbar-port-token-$$" steps="" i L
  kill_named "$n" "$n2"; mb unforward --host "$HOST" --port 8765 >/dev/null 2>&1
  rsh "mkdir -p $www && echo $tok > $www/index.html"
  mb new --host "$HOST" --name "$n" --dir "$www" --no-attach >/dev/null; wait_prompt "$n"
  send_text "$n" "python3 -m http.server 8765 --bind 127.0.0.1"
  mb new --host "$HOST" --name "$n2" --dir "$www" --no-attach >/dev/null; wait_prompt "$n2"
  send_text "$n2" "python3 -m http.server 8766 --bind 0.0.0.0"
  local polls=0; for i in 1 2 3 4 5; do mb refresh --host "$HOST" >/dev/null; polls=$i; [ "$(port_field 8765 owner)" = "$n" ] && break; sleep 1; done
  mb ports --host "$HOST" --json > "$OUT/E49-ports.json"
  [ "$(port_field 8765 owner)" = "$n" ] && [ "$(port_field 8765 process)" = python3 ] && steps="${steps}listed-with-owner "
  [ "$(port_field 8766 owner)" = "$n2" ] && [ -z "$(port_field 22 port)" ] && steps="${steps}any-addr-listed-22-not "
  L=$(mb forward --host "$HOST" --port 8765 --json | jget local)
  [ -n "$L" ] && [ "$(curl_tok "$L")" = "$tok" ] && steps="${steps}forwarded "
  wsnap E49-ports >/dev/null
  [ "$(lsof -nP -iTCP:"$L" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')" = "127.0.0.1:$L " ] && steps="${steps}loopback-only "
  # Drop the ssh master (its forwards go with it); the next poll brings the forward back.
  ssh -o "ControlPath=$CM_DIR/%C" -O exit "$HOST" >/dev/null 2>&1; sleep 1
  local gone=no; [ "$(curl_tok "$L")" = "$tok" ] || gone=yes
  for i in $(seq 15); do mb refresh --host "$HOST" >/dev/null; sleep 1; [ "$(curl_tok "$L")" = "$tok" ] && break; done
  [ $gone = yes ] && [ "$(curl_tok "$L")" = "$tok" ] && steps="${steps}back-after-drop "
  app_quit; local down=no; [ "$(curl_tok "$L")" = "$tok" ] || down=yes
  app_start
  for i in $(seq 30); do sleep 1; [ "$(curl_tok "$L")" = "$tok" ] && break; done
  [ "$(curl_tok "$L")" = "$tok" ] && steps="${steps}back-after-restart "
  echo "local=$L polls=$polls gone-after-drop=$gone down-while-quit=$down" > "$OUT/E49-notes.txt"
  mb unforward --host "$HOST" --port 8765 >/dev/null; sleep 1
  [ -z "$(curl_tok "$L")" ] && [ "$(port_field 8765 local)" = 0 ] && steps="${steps}unforwarded "
  # Auto-forward (off by default): a new server in one of your sessions is forwarded by itself.
  mb settings-set --auto-forward true >/dev/null
  send_key "$n2" C-c; sleep 0.5; send_text "$n2" "python3 -m http.server 8767 --bind 127.0.0.1"
  local AL=""; for i in $(seq 10); do mb refresh --host "$HOST" >/dev/null; AL=$(port_field 8767 local); [ -n "$AL" ] && [ "$AL" != 0 ] && break; sleep 1; done
  [ -n "$AL" ] && [ "$AL" != 0 ] && [ "$(curl_tok "$AL")" = "$tok" ] && steps="${steps}auto-forward "
  mb settings-set --auto-forward false >/dev/null
  [ -n "$AL" ] && [ "$AL" != 0 ] && mb unforward --host "$HOST" --port 8767 >/dev/null
  send_key "$n" C-c; send_key "$n2" C-c; sleep 0.5
  kill_named "$n" "$n2"; rsh "rm -rf $www"
  local want="listed-with-owner any-addr-listed-22-not forwarded loopback-only back-after-drop back-after-restart unforwarded auto-forward "
  if [ "$steps" = "$want" ]; then pass E49 "8765 listed (owner $n, $polls poll(s)); 0.0.0.0:8766 listed, 22 not; localhost:$L served the token (bound on 127.0.0.1 only); back on its own after the master dropped and after a restart; unforward closed it; with auto-forward on, a new server (8767) was forwarded by itself"
  else fail E49 "steps '$steps' want '$want' (see E49-*)"; fi
}

# ---------------------------------------------------------------------------------------------
# F9: history search

HIST=/tmp/muxbar-e2e-history
hist_seed() {
  local fx=Tests/MuxbarCoreTests/Fixtures/history t=$(( $(date +%s) - 3 * 86400 ))
  local old=claude/-tmp-muxbar-e2e-hist/33333333-cccc-4ccc-8ccc-333333333333.jsonl
  if [ "$HOST" = local ]; then
    mkdir -p "$HIST" /tmp/muxbar-e2e-hist && tar -C "$fx" -cf - . | tar -C "$HIST" -xf - && echo canary > "$HIST/canary"
  else
    tar -C "$fx" -cf - . | ssh -o BatchMode=yes -o "ControlPath=$CM_DIR/%C" -T "$HOST" "mkdir -p $HIST /tmp/muxbar-e2e-hist && tar -C $HIST -xf - && echo canary > $HIST/canary"
  fi
  # tar keeps the fixtures' checkout dates: the fresh ones are made fresh, the old one 3 days old.
  rsh "find $HIST -name '*.jsonl' -exec touch {} + && { touch -d @$t $HIST/$old 2>/dev/null || touch -t \$(date -r $t +%Y%m%d%H%M.%S) $HIST/$old; }"
}
hsearch() { mb history-search --host "$HOST" --query "$1" --claude-root "$HIST/claude" --codex-root "$HIST/codex" ${2:+--days $2} --json; }

E50() {
  # History search on the host: token hits with snippets (reply and prompt, Claude and Codex), the
  # days filter, a hostile query does nothing, preview, resume runs the right command; and a
  # read-only search of the real local history.
  local steps="" r
  hist_seed
  r=$(hsearch zebra-quartz-7731); echo "$r" > "$OUT/E50-search.json"
  echo "$r" | python3 -c "
import json,sys; h=json.load(sys.stdin)['result']; by={x['id'][:4]:x for x in h}
a=by.get('1111'); b=by.get('2222')
ok = len(h)==3 and a and b and a['role']=='assistant' and a['match'].lower()=='zebra-quartz-7731' and 'build id is' in a['before'] \
     and a['firstPrompt']=='Explain how the release build works' and b['agent']=='codex' and b['role']=='user'
sys.exit(0 if ok else 1)" && steps="${steps}hits-with-snippets "
  r=$(hsearch zebra-quartz-7731 1)
  echo "$r" | python3 -c "import json,sys; h=json.load(sys.stdin)['result']; sys.exit(0 if len(h)==2 and not any(x['id'].startswith('3333') for x in h) else 1)" && steps="${steps}days-filter "
  local before; before=$(rsh "ls -la $HIST $HIST/claude/-tmp-muxbar-e2e-hist | md5sum 2>/dev/null || ls -la $HIST $HIST/claude/-tmp-muxbar-e2e-hist | md5")
  r=$(hsearch "'\"; rm -rf ~; echo \"" 2>&1); echo "$r" > "$OUT/E50-hostile.json"
  local after; after=$(rsh "ls -la $HIST $HIST/claude/-tmp-muxbar-e2e-hist | md5sum 2>/dev/null || ls -la $HIST $HIST/claude/-tmp-muxbar-e2e-hist | md5")
  [ "$(echo "$r" | jget ok 2>/dev/null)" != false ] && [ "$(echo "$r" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')" = 0 ] \
    && [ "$before" = "$after" ] && [ "$(rsh "cat $HIST/canary")" = canary ] && steps="${steps}hostile-harmless "
  if [ "$HOST" = local ]; then
    mb history-show --host local --query zebra-quartz-7731 --claude-root "$HIST/claude" --codex-root "$HIST/codex" >/dev/null; sleep 4
    mb snapshot --what history --out "$PWD/$OUT/E50-history.png" >/dev/null
  fi
  r=$(mb history-preview --host "$HOST" --agent claude --path "$HIST/claude/-tmp-muxbar-e2e-hist/11111111-aaaa-4aaa-8aaa-111111111111.jsonl" --json); echo "$r" > "$OUT/E50-preview.json"
  [ "$(echo "$r" | jget firstPrompt)" = "Explain how the release build works" ] && echo "$r" | grep -q "⏺ Bash: make -n release" && [ "$(echo "$r" | jget gitBranch)" = main ] && steps="${steps}preview "
  r=$(mb history-resume --host "$HOST" --agent claude --id 11111111-aaaa-4aaa-8aaa-111111111111 --cwd /tmp/muxbar-e2e-hist --prompt "muxbar-e2e-hres" --json)
  local nm; nm=$(echo "$r" | jget name); sleep 1.5
  local sc; sc=$(rsh "tmux display-message -p -t $(sq "$(idof "$nm")") '#{pane_start_command}'")
  local pa; pa=$(rsh "ps -A -o args= | grep -F -- '--resume' | grep -F 11111111-aaaa | grep -v grep | head -3")
  echo "session=$nm start=$sc ps=$pa" > "$OUT/E50-resume.txt"
  # The agent process itself: `claude --resume <id>` (ps -o args), started in the conversation's folder.
  echo "$pa" | grep -qE "(^|/)claude --resume '?11111111-aaaa-4aaa-8aaa-111111111111" && [ "$(rsh "tmux display-message -p -t $(sq "$(idof "$nm")") '#{pane_current_path}'" | sed 's|^/private||')" = /tmp/muxbar-e2e-hist ] && steps="${steps}resume-command "
  kill_named "$nm"
  if [ "$HOST" = local ]; then
    # Read-only on real data: files not touched in the last 10 minutes keep their mtimes.
    local m0 m1 t0 t1 n
    m0=$(find ~/.claude/projects -type f -name '*.jsonl' -mmin +10 -exec stat -f '%m %N' {} + 2>/dev/null | sort | shasum)
    t0=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
    n=$(mb history-search --host local --query Muxbar --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
    t1=$(perl -MTime::HiRes=time -e 'printf "%.1f", time')
    m1=$(find ~/.claude/projects -type f -name '*.jsonl' -mmin +10 -exec stat -f '%m %N' {} + 2>/dev/null | sort | shasum)
    echo "real: $n hits in $(perl -e "printf '%.1f', $t1 - $t0")s" >> "$OUT/E50-resume.txt"
    [ "${n:-0}" -ge 1 ] && [ "$m0" = "$m1" ] && perl -e "exit(($t1 - $t0) <= 10 ? 0 : 1)" && steps="${steps}real-readonly "
  fi
  rsh "rm -rf $HIST /tmp/muxbar-e2e-hist"
  local want="hits-with-snippets days-filter hostile-harmless preview resume-command "; [ "$HOST" = local ] && want="${want}real-readonly "
  if [ "$steps" = "$want" ]; then pass E50 "token found in a Claude reply and a Codex prompt with snippets; --days 1 dropped the 3-day-old one; hostile query: no error, no hits, nothing changed; preview first prompt + '⏺ Bash: make -n release'; resume ran claude --resume <id> in its folder$([ "$HOST" = local ] && echo "; $(tail -1 "$OUT/E50-resume.txt") (read-only)")"
  else fail E50 "steps '$steps' want '$want' (see E50-*)"; fi
}

# ---------------------------------------------------------------------------------------------
# E52: performance

bench_median() { scripts/probe-bench.sh "$HOST" "$1" 15 "$2" "${3:-stdin}" | sed -n 's/.* median=\([0-9.]*\)s.*/\1/p'; }
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{ if (NF == 3) print $1*3600 + $2*60 + $3; else print $1*60 + $2 }'; }

E52() {
  # Status probe within budget (§3.2: max(1.3 × v1, v1 + 0.3 s)); memory-only probe ≤ 0.3 s; on
  # local, the test app's idle CPU ≤ 3% over 60 s with ≥ 10 sessions (production poll intervals).
  local base budget st me steps="" note=""
  base=$(sed -n 's/.* median=\([0-9.]*\)s.*/\1/p' "e2e-artifacts/v2/bench-v1-baseline-$HOST.txt")
  budget=$(perl -e "my \$b = $base; my \$x = 1.3 * \$b; my \$y = \$b + 0.3; printf '%.3f', \$x > \$y ? \$x : \$y")
  # Status: the same transport as the v1 baseline (stdin). Memory-only: the way the app sends it.
  st=$(bench_median v2 status); me=$(bench_median v2-memory memory arg)
  perl -e "exit($st <= $budget ? 0 : 1)" && steps="${steps}status-probe "
  perl -e "exit($me <= 0.3 ? 0 : 1)" && steps="${steps}memory-probe "
  note="status ${st}s (v1 ${base}s, budget ${budget}s); memory-only ${me}s"
  local want="status-probe memory-probe "
  if [ "$HOST" = local ]; then
    app_quit; MUXBAR_FAST_POLL=off app_start; sleep 3
    local k; for k in 01 02 03 04 05 06 07 08 09 10; do rsh "tmux new-session -d -s muxbar-e2e-idle-$k 'sleep 900'"; done
    mb refresh --host local >/dev/null
    local n; n=$(mb list --host local | cut -f4 | grep -c '^muxbar-e2e-idle-')
    sleep 10
    local pid c0 c1; pid=$(mb info --json | jget pid); c0=$(cpu_seconds "$pid"); sleep 60; c1=$(cpu_seconds "$pid")
    local pct; pct=$(perl -e "printf '%.2f', ($c1 - $c0) / 60 * 100")
    rsh 'tmux list-sessions -F "#{session_id} #{session_name}" | while read id nm; do case "$nm" in muxbar-e2e-idle-*) tmux kill-session -t "$id";; esac; done'
    app_quit; app_start
    [ "$n" -ge 10 ] && perl -e "exit($pct <= 3 ? 0 : 1)" && steps="${steps}idle-cpu "
    note="$note; idle CPU ${pct}% over 60 s with $n sessions listed"
    want="${want}idle-cpu "
  fi
  echo "$note" > "$OUT/E52.txt"
  if [ "$steps" = "$want" ]; then pass E52 "$note"; else fail E52 "steps '$steps' want '$want': $note"; fi
}

E57() {
  # Wheel over an attached pane whose app has mouse reporting on (Claude Code's fullscreen view):
  # the wheel reports go through the attached client, at the pane's middle cell (a tmux command
  # would send them at column 2), arrive in order, and never put tmux in copy mode.
  [ "$TERMINAL" = embedded ] || { skip E57 "built-in terminal only"; return; }
  local log=/tmp/muxbar-e2e-wheel.log app=/tmp/muxbar-e2e-wheel.py
  local py='import os,sys,time,tty
sys.stdout.write("\033[?1049h\033[?1000h\033[?1006hmouse app\r\n"); sys.stdout.flush()
tty.setraw(0); f=open(sys.argv[1],"ab")
while True:
    b=os.read(0,4096); f.write(b); f.flush()'
  rsh "rm -f $log; printf %s $(sq "$py") > $app"
  mb new --host "$HOST" --name muxbar-e2e-wheel --dir /tmp --cmd "python3 $app $log" >/dev/null
  wait_for 25 is_attached muxbar-e2e-wheel
  sleep 2
  local id; id=$(idof muxbar-e2e-wheel)
  local info; info=$(mb scroll --host "$HOST" --id muxbar-e2e-wheel)
  local t0=$SECONDS
  mb scroll --host "$HOST" --id muxbar-e2e-wheel --lines 5 >/dev/null
  mb scroll --host "$HOST" --id muxbar-e2e-wheel --lines -2 >/dev/null
  local got; got=$(rsh "cat $log 2>/dev/null" | tr '\033' '~')
  local mode; mode=$(rsh "tmux display -p -t '$id' '#{pane_in_mode}'")
  mb kill --host "$HOST" --id "$id" --yes >/dev/null
  rsh "rm -f $log $app"
  local ups downs col
  ups=$(grep -o '~\[<64;[0-9]*;[0-9]*M' <<< "$got" | wc -l | tr -d ' ')
  downs=$(grep -o '~\[<65;[0-9]*;[0-9]*M' <<< "$got" | wc -l | tr -d ' ')
  col=$(grep -o '~\[<6[45];[0-9]*' <<< "$got" | head -1 | cut -d';' -f2)
  if grep -q 'alternate=1' <<< "$info" && [ "$ups" = 5 ] && [ "$downs" = 2 ] && [ -n "$col" ] && [ "$col" != 2 ] && [ "$mode" = 0 ]; then
    pass E57 "wheel through the attached client: 5 up + 2 down reports at column $col (the pane's middle), in $((SECONDS - t0))s for both CLI calls incl. their fixed 0.9 s waits; copy mode never entered"
  else fail E57 "info='$info' ups=$ups downs=$downs col=$col copyMode=$mode got='${got:0:200}'"; fi
}

E58() {
  # New Session with a folder that doesn't exist yet: it's reported as new, created (nested, with a
  # space), and the session starts in it. Without the option the old error stays; a hostile-looking
  # name is just a folder name (nothing runs).
  local base=/tmp/muxbar-e2e-newdir steps=""
  rsh "rm -rf $base"
  local d="$base/a b/proj"
  [ "$(mb folder-exists --host "$HOST" --path "$d" | grep -o 'exists=[a-z]*')" = exists=no ] && steps="${steps}reported-new "
  mb new --host "$HOST" --name muxbar-e2e-nd --dir "$d" --no-attach --create-folder >/dev/null && steps="${steps}created "
  local id; id=$(idof muxbar-e2e-nd)
  local path; path=$(rsh "tmux list-panes -t '$id' -F '#{pane_current_path}'" | head -1)
  [ -n "$path" ] && [ "$path" = "$(rsh "cd $(sq "$d") && pwd -P")" ] && steps="${steps}started-there "
  [ "$(mb folder-exists --host "$HOST" --path "$d" | grep -o 'exists=[a-z]*')" = exists=yes ] && steps="${steps}reported-existing "
  [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
  mb new --host "$HOST" --name muxbar-e2e-nd2 --dir "$base/missing" --no-attach >/dev/null 2>&1 || steps="${steps}no-option-still-refused "
  local evil="$base/x; touch $base/pwned"
  mb new --host "$HOST" --name muxbar-e2e-nd3 --dir "$evil" --no-attach --create-folder >/dev/null
  id=$(idof muxbar-e2e-nd3); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
  rsh "[ -d $(sq "$evil") ] && [ ! -e $base/pwned ]" && steps="${steps}hostile-name-literal "
  rsh "rm -rf $base"
  local want="reported-new created started-there reported-existing no-option-still-refused hostile-name-literal "
  if [ "$steps" = "$want" ]; then pass E58 "new folder '$d' reported as new, created, session started in it; missing folder without the option still refused; hostile name created literally, nothing ran"
  else fail E58 "steps '$steps' want '$want' (path=$path)"; fi
}

E59() {
  # Clicks in a pane: a plain click (or ⌘-click) on a link opens it (recorded, not opened, in a
  # test instance), including a URL wrapped onto the next row; a click on a word opens nothing; a
  # drag and a double-click copy the selection; the user's clipboard is left exactly as it was.
  [ "$TERMINAL" = embedded ] || { skip E59 "built-in terminal only"; return; }
  local long="https://example.com/$(printf 'segment%02d/' $(seq 1 14))end" app=/tmp/muxbar-e2e-click.sh steps=""
  rsh "printf '%s\n' 'clear; printf \"%s\\n\" \"hello world plain text\" \"docs at https://wiki.example/bin/view/Muxbar/ for more\" \"$long\"; exec sleep 600' > $app"
  local clip0; clip0=$(pbpaste 2>/dev/null | shasum | cut -c1-12)
  mb new --host "$HOST" --name muxbar-e2e-click --dir /tmp --cmd "sh $app" >/dev/null
  wait_for 25 is_attached muxbar-e2e-click; sleep 3
  local wrap; wrap=$(rsh "tmux capture-pane -p -t '$(idof muxbar-e2e-click)'" | grep -n '^nt\|^[a-z0-9/]*end$' | head -1 | cut -d: -f1)
  ck() { mb test-click --host "$HOST" --id muxbar-e2e-click "$@"; }
  [[ "$(ck --row 1 --col 12)" == *"opened=https://wiki.example/bin/view/Muxbar/"* ]] && steps="${steps}link-opens "
  [[ "$(ck --row 1 --col 12 --command)" == *"opened=https://wiki.example/bin/view/Muxbar/"* ]] && steps="${steps}cmd-click-opens "
  [ -n "$wrap" ] && [[ "$(ck --row $((wrap - 1)) --col 5)" == *"opened=$long"* ]] && steps="${steps}wrapped-link-opens "
  [[ "$(ck --row 0 --col 2)" == *"opened= "* || "$(ck --row 0 --col 2)" == *"opened=" ]] && steps="${steps}word-opens-nothing "
  [[ "$(ck --row 0 --col 0 --to-col 11)" == "copied=hello world opened="* ]] && steps="${steps}drag-copies "
  [[ "$(ck --row 0 --col 13 --count 2)" == "copied=plain opened="* ]] && steps="${steps}double-click-copies "
  [ "$(pbpaste 2>/dev/null | shasum | cut -c1-12)" = "$clip0" ] && steps="${steps}clipboard-untouched "
  local id; id=$(idof muxbar-e2e-click); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null
  rsh "rm -f $app"
  local want="link-opens cmd-click-opens wrapped-link-opens word-opens-nothing drag-copies double-click-copies clipboard-untouched "
  if [ "$steps" = "$want" ]; then pass E59 "click opens links (plain, ⌘, wrapped over 2 rows); words open nothing; drag and double-click copy; user's clipboard untouched"
  else fail E59 "steps '$steps' want '$want' (wrap row=$wrap)"; fi
}

E60() {
  # After the host's tmux server goes away (a restart): an attached pane's session shows as ended
  # by itself within seconds; removing a session Muxbar hasn't seen end yet works; Resume All
  # brings back each agent session with its own conversation, skipping a duplicate conversation and
  # a session with no agent.
  [ "$TERMINAL" = embedded ] || { skip E60 "built-in terminal only"; return; }
  local steps="" c1=11111111-1111-4111-8111-111111111111 c2=22222222-2222-4222-8222-222222222222
  mb new --host "$HOST" --name muxbar-e2e-ra --dir /tmp --cmd 'sleep 900' >/dev/null
  for n in rb rc rd; do mb new --host "$HOST" --name muxbar-e2e-$n --dir /tmp --cmd 'sleep 900' --no-attach >/dev/null; done
  mb set-conversation --host "$HOST" --id muxbar-e2e-ra --conversation $c1 --agent claude >/dev/null
  mb set-conversation --host "$HOST" --id muxbar-e2e-rb --conversation $c2 --agent codex >/dev/null
  mb set-conversation --host "$HOST" --id muxbar-e2e-rc --conversation $c1 --agent claude >/dev/null   # same conversation as ra
  wait_for 25 is_attached muxbar-e2e-ra; sleep 2
  # The host "restarts": its tmux server goes away. No refresh from here on: the pane's exit has to do it.
  rsh "tmux kill-server" >/dev/null 2>&1
  local i ended=no; for i in $(seq 16); do mb list --json | python3 -c 'import json,sys; sys.exit(0 if any(s["name"]=="muxbar-e2e-ra" and s["ended"] for s in json.load(sys.stdin)["result"]) else 1)' && { ended=yes; break; }; sleep 0.5; done
  [ $ended = yes ] && steps="${steps}ended-on-its-own "
  # A session Muxbar still lists as running, whose tmux server is gone: removing it works.
  mb new --host "$HOST" --name muxbar-e2e-re --dir /tmp --cmd 'sleep 900' --no-attach >/dev/null
  rsh "tmux kill-server" >/dev/null 2>&1
  mb kill --host "$HOST" --id muxbar-e2e-re --yes >/dev/null 2>&1 && ! mb list | grep -q muxbar-e2e-re && steps="${steps}remove-gone-works "
  mb refresh --host "$HOST" >/dev/null
  local r; r=$(mb resume-all --host "$HOST")
  # Other rows may have left ended sessions too: ours must be in the right lists.
  local res sk; res=$(sed -n 's/.*resumed=\([^ ]*\).*/\1/p' <<< "$r"); sk=$(sed -n 's/.*skipped=\([^ ]*\).*/\1/p' <<< "$r")
  [[ ",$res," == *",muxbar-e2e-ra,"* && ",$res," == *",muxbar-e2e-rb,"* && ",$sk," == *",muxbar-e2e-rc,"* && ",$sk," == *",muxbar-e2e-rd,"* \
     && ",$res," != *",muxbar-e2e-rc,"* && ",$res," != *",muxbar-e2e-rd,"* ]] && steps="${steps}resume-all-picks "
  grep -q "resumed ended session muxbar-e2e-ra on $HOST with: claude --resume '$c1'" "$MUXBAR_HOME/logs/app.log" \
    && grep -q "resumed ended session muxbar-e2e-rb on $HOST with: codex resume '$c2'" "$MUXBAR_HOME/logs/app.log" && steps="${steps}own-conversations "
  rsh "tmux list-sessions -F '#{session_name}'" | grep -qx muxbar-e2e-ra && rsh "tmux list-sessions -F '#{session_name}'" | grep -qx muxbar-e2e-rb && steps="${steps}running-again "
  for n in ra rb rc rd; do local id; id=$(idof muxbar-e2e-$n); [ -n "$id" ] && mb kill --host "$HOST" --id "$id" --yes >/dev/null 2>&1; done
  mb dismiss-ended --host "$HOST" >/dev/null
  local want="ended-on-its-own remove-gone-works resume-all-picks own-conversations running-again "
  if [ "$steps" = "$want" ]; then pass E60 "tmux server gone: attached session ended by itself in ≤ $((i / 2 + 1)) s (no refresh), removing a not-yet-noticed one works; Resume All resumed ra (claude) and rb (codex) with their own conversations, skipped the duplicate and the no-agent one"
  else fail E60 "steps '$steps' want '$want' (resume-all: $r)"; fi
}

V2_LOCAL=(E32 E36 E44 E46 E54)
V2_ALL=(E33 E34 E35 E37 E38 E39 E40 E41 E42 E43 E45 E47 E48 E49 E50 E51 E52 E55 E56 E57 E58 E59 E60)
