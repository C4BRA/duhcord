#!/bin/bash
# Builds a release binary and wraps it in Duhcord.app, ad-hoc signed with the
# hardened runtime and the App Sandbox (see Duhcord.entitlements).
# Usage: scripts/bundle.sh [output-dir]   (default: ./build)
# DUHCORD_VERSION (e.g. 1.2.0) and DUHCORD_BUILD set the version; releases pass them from the tag.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Duhcord.app"
VERSION="${DUHCORD_VERSION:-0.1.0}"
BUILD="${DUHCORD_BUILD:-1}"
XPC="$APP/Contents/XPCServices/com.duhcord.app.Updater.xpc"
VOICE="$APP/Contents/XPCServices/com.duhcord.app.Voice.xpc"
MIC_REASON="Duhcord uses the microphone only while you're in a voice channel and unmuted."

# The voice helper links libdave; build it first (skipped when the pinned version is already built).
scripts/build-libdave.sh

# Apple silicon only: no Intel slice to download, store or page in.
# Optimise for size: this is a UI app that mostly waits on the network, so a smaller
# binary (less to load and keep in memory) beats a few percent of raw speed.
FLAGS=(-c release --arch arm64 -Xswiftc -Osize)
swift build "${FLAGS[@]}"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$XPC/Contents/MacOS" "$VOICE/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/Duhcord" "$APP/Contents/MacOS/Duhcord"
cp "$BIN_DIR/DuhcordUpdater" "$XPC/Contents/MacOS/DuhcordUpdater"
cp "$BIN_DIR/DuhcordVoice" "$VOICE/Contents/MacOS/DuhcordVoice"
strip -x "$APP/Contents/MacOS/Duhcord" "$XPC/Contents/MacOS/DuhcordUpdater" "$VOICE/Contents/MacOS/DuhcordVoice"
# Notices for the open-source code linked into the voice helper (libdave, mlspp, BoringSSL, nlohmann/json).
cp Vendor/libdave/licenses/* "$APP/Contents/Resources/Licenses/"

# The voice helper: an XPC service that runs calls in its own sandbox (see Sources/DuhcordVoice).
cat > "$VOICE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DuhcordVoice</string>
    <key>CFBundleIdentifier</key><string>com.duhcord.app.Voice</string>
    <key>CFBundleExecutable</key><string>DuhcordVoice</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSMicrophoneUsageDescription</key><string>$MIC_REASON</string>
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key><string>Application</string>
    </dict>
</dict>
</plist>
PLIST

# The installer helper: an XPC service that only Duhcord can start (see Sources/DuhcordUpdater).
cat > "$XPC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DuhcordUpdater</string>
    <key>CFBundleIdentifier</key><string>com.duhcord.app.Updater</string>
    <key>CFBundleExecutable</key><string>DuhcordUpdater</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key><string>Application</string>
    </dict>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Duhcord</string>
    <key>CFBundleDisplayName</key><string>Duhcord</string>
    <key>CFBundleIdentifier</key><string>com.duhcord.app</string>
    <key>CFBundleExecutable</key><string>Duhcord</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSRequiresNativeExecution</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>$MIC_REASON</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# --options runtime enables the hardened runtime with no exceptions: no JIT, no unsigned
# code, no injected libraries, no debugger attachment.
#
# Signing identity, in order: DUHCORD_SIGN_IDENTITY (set by CI), the "Duhcord Release Signing"
# certificate in your keychain (see scripts/create-signing-certificate.sh), else ad-hoc.
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
codesign "${SIGN_ARGS[@]}" "$APP"
[ -n "$IDENTITY" ] && echo "Signed with Duhcord Release Signing ($IDENTITY)" || echo "Signed ad-hoc (no release certificate found)"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
