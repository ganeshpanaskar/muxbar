#!/bin/bash
# Muxbar installer: builds from source with Command Line Tools and installs to ~/Applications.
#   ./install.sh               build + install (also the update path: git pull && ./install.sh)
#   ./install.sh --uninstall   remove the app (asks before deleting your data)
#   ./install.sh --reset-permissions   also clear Muxbar's Automation grant so macOS asks again
#   ./install.sh --root PATH   root folder for session workspaces (default ~/muxbar-sessions; asked on first install)
#   ./install.sh --no-tmux     don't install tmux (local sessions then won't survive being closed)
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Muxbar.app"
BUNDLE_ID="io.github.ganeshpanaskar.muxbar"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

uninstall() {
  say "Quitting Muxbar"
  "$APP/Contents/MacOS/Muxbar" --cli quit >/dev/null 2>&1 || true
  pkill -f 'Muxbar.app/Contents/MacOS/Muxbar$' >/dev/null 2>&1 || true
  if [ -d "$APP" ]; then
    # Remove the login item if Muxbar registered one (SMAppService entries vanish with the app).
    rm -rf "$APP"
    say "Removed $APP"
  fi
  local data=("$HOME/Library/Application Support/Muxbar" "$HOME/.muxbar" "$HOME/Library/Logs/Muxbar")
  echo "Your Muxbar data (session names, notes, settings, logs):"
  printf '  %s\n' "${data[@]}"
  local answer="n"
  if [ -t 0 ]; then read -r -p "Delete it too? [y/N] " answer || true; fi
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "${data[@]}"
    say "Data deleted"
  else
    say "Data kept"
  fi
  echo "Your tmux sessions on remote hosts were not touched."
  exit 0
}

reset_tcc=false
root_arg=""
install_tmux=true
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall ;;
    --reset-permissions) reset_tcc=true ;;
    --no-tmux) install_tmux=false ;;
    --root) shift; [ -n "${1:-}" ] || die "--root needs a path"; root_arg="$1" ;;
    --root=*) root_arg="${1#--root=}" ;;
    *) die "unknown option $1 (use --uninstall, --reset-permissions, --root PATH, --no-tmux or nothing)" ;;
  esac
  shift
done

# 1. macOS version (Swift 6 Command Line Tools need macOS 14.5+).
os=$(sw_vers -productVersion)
major=${os%%.*}; rest=${os#*.}; minor=${rest%%.*}
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 5 ]; }; then
  die "Muxbar needs macOS 14.5 or later (you have $os)."
fi

# 2. Command Line Tools (the first `git` usually installs them already).
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Apple Command Line Tools (a system dialog will appear)"
  xcode-select --install || true
  die "Re-run ./install.sh when the Command Line Tools install has finished."
fi

# 3. Swift 6+.
sv=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\..*/\1/p' | head -1)
[ -n "$sv" ] && [ "$sv" -ge 6 ] || die "Swift 6 or later is required (found: ${sv:-none}). Update Command Line Tools via Software Update."

# 4. tmux keeps local sessions alive when a pane or Muxbar closes. Muxbar looks in the
#    Homebrew and MacPorts locations, so install it with whichever one is present.
find_tmux() {
  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /usr/bin/tmux; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
if find_tmux >/dev/null; then
  say "tmux found: $(find_tmux)"
elif ! $install_tmux; then
  say "Skipping tmux (--no-tmux): local sessions won't survive being closed"
else
  brew_bin=$(command -v brew || { [ -x /opt/homebrew/bin/brew ] && echo /opt/homebrew/bin/brew; } || { [ -x /usr/local/bin/brew ] && echo /usr/local/bin/brew; } || true)
  if [ -n "$brew_bin" ]; then
    say "Installing tmux with Homebrew"
    "$brew_bin" install tmux || die "brew install tmux failed. Fix it and re-run, or use --no-tmux."
  elif command -v port >/dev/null 2>&1; then
    say "Installing tmux with MacPorts (asks for your password)"
    sudo port install tmux || die "port install tmux failed. Fix it and re-run, or use --no-tmux."
  else
    die "tmux isn't installed and neither Homebrew nor MacPorts was found.
  Install Homebrew (https://brew.sh) and re-run, or run ./install.sh --no-tmux to continue without it
  (local sessions then won't survive being closed)."
  fi
  find_tmux >/dev/null || die "tmux still not found after installing it."
  say "tmux installed: $(find_tmux)"
fi

updating=false
[ -d "$APP" ] && updating=true

# Workspace root: sessions get <root>/<group>/<session> folders on this Mac (remote hosts have
# their own root, set in Muxbar → Settings). Asked once; kept on updates unless --root is given.
CONF="$HOME/.muxbar/install.conf"
mkdir -p "$HOME/.muxbar"
current_root=$( { sed -n "s/^root=//p" "$CONF" 2>/dev/null || true; } | head -1)
if [ -n "$root_arg" ]; then
  ws_root="$root_arg"
elif [ -n "$current_root" ]; then
  ws_root="$current_root"
elif [ -t 0 ]; then
  read -r -p "Root folder for session workspaces [~/muxbar-sessions]: " ws_root || true
  ws_root="${ws_root:-~/muxbar-sessions}"
else
  ws_root="~/muxbar-sessions"
fi
case "$ws_root" in "~"|"~/"*|/*) ;; *) die "--root must be an absolute path or start with ~/ (got: $ws_root)";; esac
# Session folders must not land inside this source checkout (macOS paths are case-insensitive).
repo=$(pwd -P | tr '[:upper:]' '[:lower:]')
ws_abs=$(printf '%s' "${ws_root/#\~/$HOME}" | sed 's#/*$##' | tr '[:upper:]' '[:lower:]')
case "$ws_abs/" in
  "$repo/"*)
    [ -n "$root_arg" ] && die "--root $ws_root is inside the Muxbar source folder; pick another folder."
    say "Workspace root $ws_root is inside the Muxbar source folder; switching to ~/muxbar-sessions"
    ws_root="~/muxbar-sessions" ;;
esac
printf '# Written by install.sh\nroot=%s\n' "$ws_root" > "$CONF"
mkdir -p "${ws_root/#\~/$HOME}"
say "Workspace root: $ws_root"

say "Building Muxbar (first build takes a minute or two)"
make install

# Each rebuild has a new ad-hoc signature. On macOS 26 the existing Automation grant kept working
# after rebuilds (verified 2026-10-04), so it's kept by default. If Muxbar ever reports it isn't
# allowed to control your terminal, run ./install.sh --reset-permissions (or use the banner button).
if $reset_tcc; then
  tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 || true
  say "Automation permission reset — macOS will ask again the next time Muxbar opens a terminal."
fi

say "Muxbar is installed at $APP and running in your menu bar."
cat <<'MSG'

Next steps:
  • Click the Muxbar icon in the menu bar → gear → tick any remote hosts (from ~/.ssh/config).
  • The first time Muxbar opens a terminal, macOS asks to let it control Terminal (or iTerm2). Click OK.
  • Optional: Settings → "Open Muxbar at login".
  • Default command for new sessions is `claude` — change it in Settings (codex, gemini, any CLI, or empty for a shell).
  • Remote hosts need tmux 2.6+ (e.g. sudo apt install tmux / sudo dnf install tmux).

Update later with:   git pull && ./install.sh
Uninstall with:      ./install.sh --uninstall
MSG
