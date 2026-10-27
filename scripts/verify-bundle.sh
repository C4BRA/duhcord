#!/bin/bash
# Fails if the app bundle lost its hardened runtime, sandbox, or gained entitlements
# beyond Duhcord.entitlements. Run by CI so a security regression can't ship silently.
set -euo pipefail
TMPDIR="${TMPDIR:-/tmp}"

APP="${1:-build/Duhcord.app}"
cd "$(dirname "$0")/.."

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

echo "OK: $APP is sandboxed, uses the hardened runtime, and has only the expected entitlements"
