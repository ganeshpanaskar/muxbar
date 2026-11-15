#!/bin/bash
# Signs the app bundle with the persistent local identity (scripts/signing-identity.sh), so macOS
# privacy grants survive rebuilds. Falls back to ad-hoc signing if the identity can't be used.
set -uo pipefail
APP="$1"; BUNDLE_ID="$2"
cd "$(dirname "$0")/.."
if KC=$(scripts/signing-identity.sh 2>/dev/null) && SHA=$(security find-identity -p codesigning "$KC" | awk '/Muxbar Local Signing/ {print $2; exit}') && [ -n "$SHA" ]; then
  # codesign only finds identities in the user search list: add ours for the signing step, then
  # put the list back exactly as it was.
  saved=()
  while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"; [ -n "$line" ] && saved+=("$line"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "${saved[@]}" "$KC"
  codesign --force --sign "$SHA" --identifier "$BUNDLE_ID" "$APP"; rc=$?
  security list-keychains -d user -s "${saved[@]}"
  if [ $rc -eq 0 ]; then echo "signed with Muxbar Local Signing"; exit 0; fi
  echo "warning: local identity signing failed; using ad-hoc" >&2
fi
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "signed ad-hoc (privacy prompts may repeat after updates)"
