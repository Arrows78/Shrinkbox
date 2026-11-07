#!/bin/sh
# Prints the Homebrew cask for a release.
#   scripts/render_cask.sh VERSION SHA256 [BASE_URL]
# BASE_URL defaults to the GitHub releases of the project; tests point it at file:// URLs.
set -eu
[ $# -ge 2 ] || { echo "usage: $0 VERSION SHA256 [BASE_URL]" >&2; exit 2; }
version=$1
sha=$2
base=${3:-https://github.com/Arrows78/Shrinkbox/releases/download}
case $version in ""|*[!0-9A-Za-z.+-]*) echo "invalid version" >&2; exit 2 ;; esac
case $sha in *[!0-9a-f]*|"") echo "invalid sha256" >&2; exit 2 ;; esac
[ ${#sha} -eq 64 ] || { echo "sha256 must be 64 hex characters" >&2; exit 2; }
sed -e "s|@VERSION@|$version|g" -e "s|@SHA256@|$sha|g" -e "s|@BASE_URL@|$base|g" \
  "$(dirname "$0")/../packaging/homebrew/shrinkbox.rb.in"
