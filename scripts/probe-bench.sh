#!/bin/bash
# Times the app's status probe on a host with 10 test sessions (on the test tmux server only).
#   scripts/probe-bench.sh HOST LABEL [RUNS] [MODE]   → e2e-artifacts/v2/bench-LABEL-HOST.txt
#   MODE: status (default) or memory (the fast memory-only probe)
#   TRANSPORT (5th): stdin (default; how the v1 baseline was measured) or arg (how the app sends it:
#   the script as the ssh command, `sh -c <script>`)
# The script that's timed is exactly what the app runs (`--cli probe-script`), sent over the same
# kind of multiplexed ssh connection the app uses.
set -uo pipefail
cd "$(dirname "$0")/.."
HOST=${1:?host}; LABEL=${2:?label}; RUNS=${3:-15}; MODE=${4:-status}; TRANSPORT=${5:-stdin}
. scripts/e2e-env.sh
mb() { perl -e 'alarm 90; exec @ARGV' "$M" --cli "$@"; }
OUT=e2e-artifacts/v2; mkdir -p "$OUT"
rsh() {
  if [ "$HOST" = local ]; then PATH="/opt/homebrew/bin:$PATH" sh -c "$TMUX_FN
$1"
  else printf '%s\n%s\n' "$TMUX_FN" "$1" | ssh -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" \
         -o ControlPersist=10m -T "$HOST" sh -s 2>/dev/null; fi
}
rsh 'for i in 01 02 03 04 05 06 07 08 09 10; do tmux new-session -d -s muxbar-e2e-bench-$i -x 120 -y 40 "seq 1 200; sleep 900"; done'
sleep 2
S=$(mktemp /tmp/muxbar-e2e-bench.XXXX)
mb probe-script --host "$HOST" --mode "$MODE" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["script"])' > "$S"
times=()
for _ in $(seq "$RUNS"); do
  t0=$(perl -MTime::HiRes=time -e 'printf "%.4f", time')
  if [ "$HOST" = local ]; then PATH="/opt/homebrew/bin:$PATH" sh "$S" > /dev/null
  elif [ "$TRANSPORT" = arg ]; then ssh -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" -o ControlPersist=10m -T "$HOST" \
         "sh -c '$(sed "s/'/'\\\\''/g" "$S")'" > /dev/null 2>&1
  else ssh -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" -o ControlPersist=10m -T "$HOST" \
         sh -s < "$S" > /dev/null 2>&1; fi
  t1=$(perl -MTime::HiRes=time -e 'printf "%.4f", time')
  times+=("$(perl -e "printf '%.3f', $t1 - $t0")")
done
bytes=$(if [ "$HOST" = local ]; then PATH="/opt/homebrew/bin:$PATH" sh "$S" | wc -c; else ssh -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$CM_DIR/%C" -T "$HOST" sh -s < "$S" 2>/dev/null | wc -c; fi)
rsh 'tmux list-sessions -F "#{session_id} #{session_name}" 2>/dev/null | while read id n; do case "$n" in muxbar-e2e-bench-*) tmux kill-session -t "$id";; esac; done'
rm -f "$S"
sorted=$(printf '%s\n' "${times[@]}" | sort -n)
median=$(printf '%s\n' "$sorted" | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
p90=$(printf '%s\n' "$sorted" | awk '{a[NR]=$1} END {i=int(NR*0.9); if(i<1)i=1; print a[i]}')
line="$(date -u +%FT%TZ) host=$HOST label=$LABEL mode=$MODE transport=$TRANSPORT sessions=10 runs=$RUNS median=${median}s p90=${p90}s output=${bytes}B all=[$(echo ${times[*]})]"
echo "$line" | tee "$OUT/bench-$LABEL-$HOST.txt"
