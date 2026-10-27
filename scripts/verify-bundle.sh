#!/bin/bash
# Fails if the app bundle lost its hardened runtime, sandbox, or gained entitlements
# beyond Duhcord.entitlements. Run by CI so a security regression can't ship silently.
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"

APP="${1:-build/Duhcord.app}"
cd "$(dirname "$0")/.."
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac

codesign --verify --strict "$APP"

info="$(codesign -d --verbose=2 "$APP" 2>&1)"
if ! grep -q "flags=.*runtime" <<<"$info"; then
    echo "error: hardened runtime is not enabled" >&2
    exit 1
fi

codesign -d --entitlements - --xml "$APP" > "$TMPDIR/duhcord-entitlements.plist" 2>/dev/null
python3 - "$TMPDIR/duhcord-entitlements.plist" Duhcord.entitlements <<'PY'
import plistlib, sys
signed, expected = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
if signed != expected:
    sys.exit(f"error: signed entitlements {signed} differ from Duhcord.entitlements {expected}")
PY

# Release builds must be signed by the published certificate, so a build signed by anyone else fails.
if [ "${DUHCORD_REQUIRE_RELEASE_SIGNATURE:-0}" = 1 ]; then
    [ -f signing/certificate.sha256 ] || { echo "error: signing/certificate.sha256 is missing; commit the certificate fingerprint first" >&2; exit 1; }
    expected_fp="$(tr -d '[:space:]' < signing/certificate.sha256)"
    certs="$TMPDIR/duhcord-certs"
    rm -rf "$certs" && mkdir -p "$certs"
    (cd "$certs" && codesign -d --extract-certificates "$APP" 2>/dev/null)
    actual_fp="$(shasum -a 256 "$certs/codesign0" | cut -d' ' -f1)"
    if [ "$actual_fp" != "$expected_fp" ]; then
        echo "error: signed by certificate $actual_fp, expected $expected_fp (signing/certificate.sha256)" >&2
        exit 1
    fi
    echo "OK: signed by the published Duhcord Release Signing certificate"
fi

echo "OK: $APP is sandboxed, uses the hardened runtime, and has only the expected entitlements"
