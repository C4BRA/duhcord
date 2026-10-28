#!/bin/bash
# Fails if the app bundle lost its hardened runtime, sandbox, or gained entitlements
# beyond Duhcord.entitlements, or if the installer helper inside it isn't locked down the same way.
# Run by CI so a security regression can't ship silently.
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"

APP="${1:-build/Duhcord.app}"
cd "$(dirname "$0")/.."
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac

HELPER="$APP/Contents/XPCServices/com.duhcord.app.Updater.xpc"
VOICE="$APP/Contents/XPCServices/com.duhcord.app.Voice.xpc"
[ -d "$HELPER" ] || { echo "error: installer helper is missing" >&2; exit 1; }
[ -d "$VOICE" ] || { echo "error: voice helper is missing" >&2; exit 1; }

codesign --verify --strict --deep "$APP"

# Apple silicon native: every binary must be arm64 and nothing else.
for bin in "$APP/Contents/MacOS/Duhcord" "$HELPER/Contents/MacOS/DuhcordUpdater" "$VOICE/Contents/MacOS/DuhcordVoice"; do
    archs="$(lipo -archs "$bin")"
    if [ "$archs" != "arm64" ]; then
        echo "error: $bin is built for '$archs', expected arm64 only" >&2
        exit 1
    fi
done

for code in "$APP" "$HELPER" "$VOICE"; do
    info="$(codesign -d --verbose=2 "$code" 2>&1)"
    if ! grep -q "flags=.*runtime" <<<"$info"; then
        echo "error: hardened runtime is not enabled for $code" >&2
        exit 1
    fi
done

# The helper must carry no entitlements at all.
helper_entitlements="$(codesign -d --entitlements - --xml "$HELPER" 2>/dev/null || true)"
if [ -n "$helper_entitlements" ] && ! python3 -c 'import plistlib,sys; sys.exit(0 if plistlib.loads(sys.stdin.buffer.read()) == {} else 1)' <<<"$helper_entitlements"; then
    echo "error: the installer helper has entitlements: $helper_entitlements" >&2
    exit 1
fi

# The app and the voice helper must carry exactly the entitlements in their files: the app no microphone, the
# voice helper nothing beyond network and microphone.
check_entitlements() {
    codesign -d --entitlements - --xml "$1" > "$TMPDIR/duhcord-entitlements.plist" 2>/dev/null
    python3 - "$TMPDIR/duhcord-entitlements.plist" "$2" <<'PY'
import plistlib, sys
signed, expected = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
if signed != expected:
    sys.exit(f"error: signed entitlements {signed} differ from {sys.argv[2]} {expected}")
PY
}
check_entitlements "$APP" Duhcord.entitlements
check_entitlements "$VOICE" DuhcordVoice.entitlements

# Release builds must be signed by the published certificate, so a build signed by anyone else fails.
if [ "${DUHCORD_REQUIRE_RELEASE_SIGNATURE:-0}" = 1 ]; then
    [ -f signing/certificate.sha256 ] || { echo "error: signing/certificate.sha256 is missing; commit the certificate fingerprint first" >&2; exit 1; }
    expected_fp="$(tr -d '[:space:]' < signing/certificate.sha256)"
    certs="$TMPDIR/duhcord-certs"
    rm -rf "$certs" && mkdir -p "$certs"
    for code in "$APP" "$HELPER" "$VOICE"; do
        rm -f "$certs"/codesign*
        (cd "$certs" && codesign -d --extract-certificates "$code" 2>/dev/null)
        actual_fp="$(shasum -a 256 "$certs/codesign0" | cut -d' ' -f1)"
        if [ "$actual_fp" != "$expected_fp" ]; then
            echo "error: $code is signed by certificate $actual_fp, expected $expected_fp (signing/certificate.sha256)" >&2
            exit 1
        fi
    done
    echo "OK: signed by the published Duhcord Release Signing certificate"
fi

echo "OK: $APP and its voice helper are sandboxed, use the hardened runtime, and have only the expected entitlements"
