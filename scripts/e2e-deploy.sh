#!/bin/bash
# Puts the test helpers on a host, under /tmp/muxbar-e2e-* only:
#   /tmp/muxbar-e2e-fake/bin/{claude,codex}   stand-in agents (scripts/fake-agent/fake_agent.py)
#   /tmp/muxbar-e2e-plugin                    the status-hook plugin (agent-plugin/), when present
# `ps` must report the stand-ins as `claude` / `codex`, like real installs:
#   Linux: the script itself is named claude/codex (#!/usr/bin/python3 → that name in ps);
#   macOS: python3 is a shim that re-execs, so exec the real interpreter with argv0 = claude/codex.
#
#   scripts/e2e-deploy.sh local|devbox
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${1:?usage: e2e-deploy.sh local|HOST}
CM="${MUXBAR_HOME:-/tmp/mbx-e2e}/cm"
mkdir -p "$CM"

if [ "$HOST" = local ]; then
  B=/tmp/muxbar-e2e-fake/bin
  mkdir -p "$B"
  cp scripts/fake-agent/fake_agent.py "$B/fake_agent.py"
  PYAPP=$(/usr/bin/python3 -c 'import os,sys; print(os.path.join(sys.base_prefix, "Resources/Python.app/Contents/MacOS/Python"))')
  [ -x "$PYAPP" ] || PYAPP=$(/usr/bin/python3 -c 'import sys; print(sys.executable)')
  for a in claude codex; do
    printf '#!/bin/bash\nexec -a %s "%s" "%s/fake_agent.py" --as %s "$@"\n' "$a" "$PYAPP" "$B" "$a" > "$B/$a"
    chmod +x "$B/$a"
  done
  if [ -d agent-plugin ]; then rm -rf /tmp/muxbar-e2e-plugin; cp -R agent-plugin /tmp/muxbar-e2e-plugin; fi
else
  ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$CM/%C" \
             -o ControlPersist=10m -T "$HOST" "$@"; }
  ssh_ 'mkdir -p /tmp/muxbar-e2e-fake/bin'
  for a in claude codex; do
    ssh_ "cat > /tmp/muxbar-e2e-fake/bin/$a && chmod +x /tmp/muxbar-e2e-fake/bin/$a" < scripts/fake-agent/fake_agent.py
  done
  if [ -d agent-plugin ]; then
    COPYFILE_DISABLE=1 tar --no-xattrs -C agent-plugin -cf - . | ssh_ 'rm -rf /tmp/muxbar-e2e-plugin && mkdir -p /tmp/muxbar-e2e-plugin && tar -C /tmp/muxbar-e2e-plugin -xf -'
  fi
fi
echo "deployed test helpers to $HOST"
