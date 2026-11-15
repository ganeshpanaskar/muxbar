#!/bin/bash
# Creates (once) and unlocks a local code-signing identity for Muxbar, so macOS privacy grants
# (Desktop/Documents/Downloads/Media/Automation) survive rebuilds: an ad-hoc signature is tied to
# the build's hash, so every rebuild looked like a new app and re-asked. The identity lives in its
# own keychain (~/Library/Keychains/muxbar-signing.keychain-db) whose password only this script
# knows (~/.muxbar/signing.pw, 0600), so signing never shows a keychain dialog.
# Prints the keychain path on success; prints nothing (and exits 1) if it can't, so the caller
# falls back to ad-hoc signing.
set -euo pipefail
NAME="Muxbar Local Signing"
KC="$HOME/Library/Keychains/muxbar-signing.keychain-db"
PWF="$HOME/.muxbar/signing.pw"
mkdir -p "$HOME/.muxbar"; chmod 700 "$HOME/.muxbar"
if [ ! -f "$KC" ] || [ ! -f "$PWF" ]; then
  rm -f "$KC"
  umask 077
  head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$PWF"
  PW=$(cat "$PWF")
  T=$(mktemp -d)
  # macOS's own LibreSSL writes a PKCS#12 that `security import` accepts (OpenSSL 3's default
  # SHA-256 MAC/AES format is rejected as "MAC verification failed").
  OSSL=/usr/bin/openssl
  "$OSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$T/key.pem" -out "$T/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  "$OSSL" pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -out "$T/id.p12" -passout pass:muxbar >/dev/null 2>&1
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC"            # no auto-lock
  security import "$T/id.p12" -k "$KC" -P muxbar -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
  rm -rf "$T"
fi
security unlock-keychain -p "$(cat "$PWF")" "$KC"
echo "$KC"
