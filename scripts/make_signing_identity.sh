#!/bin/sh
# Creates a self-signed code-signing certificate named "Shrinkbox Local Signing" in your login keychain, so that
# build.sh signs with a stable identity and macOS keeps the privacy permissions you granted across rebuilds
# (an ad-hoc signature changes on every build and makes macOS forget them).
#
# scripts/make_signing_identity.sh [identity name]
#
# macOS asks for your login password to trust the certificate. This is for local use only: it is not a
# Developer ID, so it does not replace notarisation for distribution.
set -eu
NAME="${1:-${SHRINKBOX_SIGN_IDENTITY:-Shrinkbox Local Signing}}"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists, nothing to do."; exit 0
fi

DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/openssl.cnf" <<CNF
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
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/openssl.cnf" 2>/dev/null
PASS=$(openssl rand -hex 12)
# OpenSSL 3 writes PKCS#12 files with algorithms macOS cannot read ("MAC verification failed"): ask for the old ones.
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout "pass:$PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null || \
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout "pass:$PASS" 2>/dev/null
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
echo "Created '$NAME'. Rebuild with ./build.sh and grant the permissions once more."
security find-identity -v -p codesigning | grep "\"$NAME\"" || echo "warning: the identity is not listed as valid yet (open Keychain Access and check its trust)" >&2
