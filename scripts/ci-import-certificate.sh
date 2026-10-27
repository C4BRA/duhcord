#!/bin/bash
# CI only: puts the signing certificate from GitHub secrets into a throwaway keychain and tells
# bundle.sh to use it. The keychain is deleted at the end of the job.
set -euo pipefail
: "${DUHCORD_SIGNING_P12:?}" "${DUHCORD_SIGNING_PASSWORD:?}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"

KEYCHAIN="$RUNNER_TEMP/duhcord-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
P12="$RUNNER_TEMP/duhcord-signing.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 1800 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

printf '%s' "$DUHCORD_SIGNING_P12" | base64 --decode > "$P12"
security import "$P12" -k "$KEYCHAIN" -P "$DUHCORD_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -P "$P12"
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign looks keys up through the search list, so the throwaway keychain has to be on it.
existing=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    existing+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"

# Self-signed certificates are "not trusted", so look them up without -v.
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/"Duhcord Release Signing"/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "error: signing identity not found in the imported certificate" >&2; exit 1; }

echo "DUHCORD_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "DUHCORD_SIGN_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
echo "Imported signing identity $IDENTITY"
