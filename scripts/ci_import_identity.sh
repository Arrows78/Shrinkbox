#!/bin/sh
# Imports a code-signing identity into a temporary keychain and prints its SHA-1 hash, so the release build can be signed with it.
#   SIGNING_P12       the .p12 file, base64 encoded (a repository secret)
#   SIGNING_PASSWORD  its password (a repository secret)
#   $1                the identity's name, e.g. "Shrinkbox Local Signing"
# Prints nothing and succeeds when no .p12 is provided: the caller then keeps the ad hoc signature.
# A stable identity is what lets macOS keep the privacy permissions (screen recording...) across updates.
set -eu
name="$1"
[ -n "${SIGNING_P12:-}" ] || { echo "no signing identity provided: the build stays ad hoc" >&2; exit 0; }
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
kc="$tmp/release-signing.keychain-db"
pw=$(uuidgen)
trap 'rm -f "$tmp/identity.p12"' EXIT
printf '%s' "$SIGNING_P12" | base64 -d > "$tmp/identity.p12"
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$pw" "$kc"
security import "$tmp/identity.p12" -k "$kc" -P "${SIGNING_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null
existing=$(security list-keychains -d user | tr -d '"')
# shellcheck disable=SC2086
security list-keychains -d user -s "$kc" $existing
hash=$(security find-identity -p codesigning "$kc" | awk -v n="$name" 'index($0, n) { print $2; exit }')
[ -n "$hash" ] || { echo "identity '$name' not found in the imported file" >&2; exit 1; }
echo "$hash"
