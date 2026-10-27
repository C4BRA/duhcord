#!/bin/bash
# Run ONCE, on your own Mac, to create Duhcord's release-signing certificate.
#
# It creates a self-signed code-signing certificate, imports it into your login keychain (so
# scripts/bundle.sh signs local builds with it), and writes a password-protected .p12 for the
# GitHub Actions secret. The private key never leaves your Mac except inside that encrypted .p12.
#
# Usage: scripts/create-signing-certificate.sh [output-folder]   (default: ~/Duhcord-signing)
set -euo pipefail

NAME="Duhcord Release Signing"
OUT="${1:-$HOME/Duhcord-signing}"
OPENSSL=/usr/bin/openssl   # macOS's built-in LibreSSL; its .p12 files import cleanly into the Keychain

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "A \"$NAME\" certificate is already in your keychain. Delete it in Keychain Access first if you really want a new one." >&2
    exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$OUT"
umask 077

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "Choose a strong password for the exported certificate (you'll paste it into GitHub as a secret)."
read -r -s -p "Password: " P12_PASSWORD; echo
read -r -s -p "Again:    " P12_CONFIRM; echo
[ "$P12_PASSWORD" = "$P12_CONFIRM" ] || { echo "Passwords didn't match." >&2; exit 1; }
[ "${#P12_PASSWORD}" -ge 12 ] || { echo "Use at least 12 characters." >&2; exit 1; }
export P12_PASSWORD

# Valid for 10 years. The unencrypted key file exists only until the .p12 is written.
$OPENSSL req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -config cert.cnf -keyout key.pem -out certificate.pem 2>/dev/null
$OPENSSL pkcs12 -export -inkey key.pem -in certificate.pem -name "$NAME" -out duhcord-signing.p12 -passout env:P12_PASSWORD
rm -P key.pem cert.cnf

security import duhcord-signing.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
base64 -i duhcord-signing.p12 -o duhcord-signing.p12.base64
FINGERPRINT="$($OPENSSL x509 -in certificate.pem -outform DER | shasum -a 256 | cut -d' ' -f1)"
echo "$FINGERPRINT" > fingerprint.txt

cat <<DONE

Done. Files are in $OUT:
  duhcord-signing.p12          the certificate and private key, encrypted with your password (back this up offline)
  duhcord-signing.p12.base64   the same file as text, for the DUHCORD_SIGNING_P12 GitHub secret
  certificate.pem              the public certificate (safe to share)
  fingerprint.txt              the public fingerprint (safe to share)

Fingerprint (SHA-256):
  $FINGERPRINT

Next: follow "Release signing" in the README to add the two GitHub secrets and publish the fingerprint.
DONE
