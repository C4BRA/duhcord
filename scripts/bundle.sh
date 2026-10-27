#!/bin/bash
# Builds a release binary and wraps it in Duhcord.app, ad-hoc signed with the
# hardened runtime and the App Sandbox (see Duhcord.entitlements).
# Usage: scripts/bundle.sh [output-dir]   (default: ./build)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/Duhcord.app"

# Optimise for size: this is a UI app that mostly waits on the network, so a smaller
# binary (less to load and keep in memory) beats a few percent of raw speed.
FLAGS=(-c release --arch arm64 --arch x86_64 -Xswiftc -Osize)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Duhcord"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Duhcord"
strip -x "$APP/Contents/MacOS/Duhcord"

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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# --options runtime enables the hardened runtime with no exceptions: no JIT, no unsigned
# code, no injected libraries, no debugger attachment.
codesign --force --options runtime --entitlements Duhcord.entitlements --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
