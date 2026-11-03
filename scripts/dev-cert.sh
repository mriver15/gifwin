#!/bin/zsh
# Creates a stable local signing identity for Gifwin.app, so the Screen Recording grant survives rebuilds.
#
#   scripts/dev-cert.sh            create it (once)
#   scripts/dev-cert.sh --remove   delete it
#
# Why: an ad-hoc signature is different on every build, so macOS treats each build as a new app and
# forgets the grant. A certificate gives the app a fixed identity; the grant is then keyed to that.
#
# It lives in its own keychain file (~/.config/gifwin/dev.keychain-db), not your login keychain, and is
# self-signed: it proves nothing to anyone else and is not a Developer ID. The keychain password below is
# not a secret; it only guards a throwaway key that signs this one app on this one machine.
set -euo pipefail

NAME="Gifwin Local Dev"
DIR="$HOME/.config/gifwin"
KC="$DIR/dev.keychain-db"
PASS="gifwin-dev"

if [[ "${1:-}" == "--remove" ]]; then
    security delete-keychain "$KC" 2>/dev/null || true
    rm -f "$KC"
    echo "removed $KC"
    exit 0
fi

mkdir -p "$DIR"
if [[ -f "$KC" ]] && security unlock-keychain -p "$PASS" "$KC" 2>/dev/null \
   && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "already set up: $NAME in $KC"
    exit 0
fi
rm -f "$KC"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/openssl.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout "pass:$PASS" 2>/dev/null

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"                     # never auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$work/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a prompt each time.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null

security find-identity -p codesigning "$KC" | grep "$NAME" || { echo "identity was not created" >&2; exit 1; }
echo "created $NAME in $KC"
echo "bundle.sh will use it automatically. Grant Screen Recording to Gifwin once more; it will then stick."
