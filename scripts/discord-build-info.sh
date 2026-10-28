#!/bin/bash
# Prints Discord's current web build number and macOS desktop app version, one per line, for
# ClientIdentity (bundle.sh puts them in Info.plist). Both change often, and a client that reports an
# old or missing build number stands out to Discord.
#
# The desktop version comes from Discord's update endpoint. The build number isn't published anywhere,
# so, like other clients, this reads it from the web app's scripts: discord.com/app lists them, and one
# carries "build_number". Only the first few are fetched, newest first, and the search stops at a match.
# Exits non-zero (printing nothing) if either can't be found; bundle.sh then falls back to the defaults.
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
fetch() { curl -fsSL --proto '=https' --max-time 30 --max-filesize 20000000 -A "$UA" "$1"; }

version="$(fetch "https://discord.com/api/updates/stable?platform=osx" | sed -nE 's/.*"name" *: *"([0-9.]+)".*/\1/p')"
[ -n "$version" ] || { echo "discord-build-info: no desktop version" >&2; exit 1; }

page="$(fetch "https://discord.com/app")"
build=""
# Script tags in page order; the build number has lived in one of the last few.
for asset in $(grep -oE '/assets/[A-Za-z0-9._-]+\.js' <<<"$page" | awk '!seen[$0]++' | tail -r | head -8); do
    build="$(fetch "https://discord.com$asset" | grep -oE '(build_number|buildNumber)[^0-9]{1,8}[0-9]{6,7}' | grep -oE '[0-9]{6,7}$' | head -1 || true)"
    [ -n "$build" ] && break
done
[ -n "$build" ] || { echo "discord-build-info: no build number" >&2; exit 1; }

echo "$build"
echo "$version"
