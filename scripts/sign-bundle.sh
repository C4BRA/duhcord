#!/bin/bash
# --options runtime enables the hardened runtime with no exceptions: no JIT, no unsigned
# code, no injected libraries, no debugger attachment.
#
# Signing identity, in order: DUHCORD_SIGN_IDENTITY (set by CI), the "Duhcord Release Signing"
# certificate in your keychain (see scripts/create-signing-certificate.sh), else ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:?Usage: scripts/sign-bundle.sh <path/to/Duhcord.app>}"
XPC="$APP/Contents/XPCServices/com.duhcord.app.Updater.xpc"
VOICE="$APP/Contents/XPCServices/com.duhcord.app.Voice.xpc"
MEDIA_DECODER="$APP/Contents/XPCServices/com.duhcord.app.MediaDecoder.xpc"

IDENTITY="${DUHCORD_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Duhcord Release Signing"/ { print $2; exit }')"
fi
SIGN_ARGS=(--force --options runtime --entitlements Duhcord.entitlements --sign "${IDENTITY:--}")
[ -n "${DUHCORD_SIGN_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$DUHCORD_SIGN_KEYCHAIN")
# Apple's timestamp service only accepts Apple-issued certificates.
[ -n "$IDENTITY" ] && SIGN_ARGS+=(--timestamp=none)
# The helper is signed first (hardened runtime, no entitlements, so not sandboxed), then the app around it.
HELPER_ARGS=(--force --options runtime --sign "${IDENTITY:--}")
[ -n "${DUHCORD_SIGN_KEYCHAIN:-}" ] && HELPER_ARGS+=(--keychain "$DUHCORD_SIGN_KEYCHAIN")
[ -n "$IDENTITY" ] && HELPER_ARGS+=(--timestamp=none)
codesign "${HELPER_ARGS[@]}" "$XPC"
# The voice helper is sandboxed with its own, separate entitlements (network and microphone).
codesign "${HELPER_ARGS[@]}" --entitlements DuhcordVoice.entitlements "$VOICE"
# The media decoder runs ImageIO in a separate sandboxed process.
codesign "${HELPER_ARGS[@]}" --entitlements DuhcordMediaDecoder.entitlements "$MEDIA_DECODER"
codesign "${SIGN_ARGS[@]}" "$APP"
[ -n "$IDENTITY" ] && echo "Signed with Duhcord Release Signing ($IDENTITY)" || echo "Signed ad-hoc (no release certificate found)"
