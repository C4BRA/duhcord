#!/bin/bash
# Prints Discord's current web build number and macOS desktop app version, one per line, for
# ClientIdentity (bundle.sh puts them in Info.plist). Both change often, and a client that reports an
# old or missing build number stands out to Discord.
#
# The desktop version comes from Discord's update endpoint. The build number isn't published anywhere,
# so, like other clients, this reads it from the web app's scripts: discord.com/app lists them, and one
# carries "build_number". At most a dozen are fetched, and the search stops at a match.
# Exits non-zero (printing nothing) if either can't be found; bundle.sh then falls back to the defaults.
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
fetch() { curl -fsSL --proto '=https' --max-time 30 --max-filesize 20000000 -A "$UA" "$1"; }

version="$(fetch "https://discord.com/api/updates/stable?platform=osx" | sed -nE 's/.*"name" *: *"([0-9.]+)".*/\1/p')"
[ -n "$version" ] || { echo "discord-build-info: no desktop version" >&2; exit 1; }

page="$(fetch "https://discord.com/app")"
# Script tags in page order. Discord's error-reporting bundle ("sentry") has carried the build number, so it's
# tried first; then the rest, newest (last) first.
assets="$(grep -oE '/assets/[A-Za-z0-9._-]+\.js' <<<"$page" | awk '!seen[$0]++' || true)"
ordered="$(grep -i sentry <<<"$assets" || true)
$(grep -iv sentry <<<"$assets" | tail -r || true)"
echo "discord-build-info: page ${#page} bytes, $(grep -c . <<<"$assets" || true) scripts" >&2
build=""
tried=0
for asset in $ordered; do
    [ "$tried" -lt 12 ] || break
    tried=$((tried + 1))
    build="$(fetch "https://discord.com$asset" | grep -oE '(build_number|buildNumber|BUILD_NUMBER)[^0-9]{1,8}[0-9]{6,7}' | grep -oE '[0-9]{6,7}$' | head -1 || true)"
    [ -n "$build" ] && break
done
# Some page versions put it in the HTML itself.
[ -n "$build" ] || build="$(grep -oE '(build_number|buildNumber|BUILD_NUMBER)[^0-9]{1,8}[0-9]{6,7}' <<<"$page" | grep -oE '[0-9]{6,7}$' | head -1 || true)"
if [ -z "$build" ]; then
    echo "discord-build-info: no build number in $tried scripts; first scripts: $(head -3 <<<"$assets" | tr '\n' ' ')" >&2
    head -c 300 <<<"$page" | tr '\n' ' ' >&2; echo >&2
    exit 1
fi

echo "$build"
echo "$version"
