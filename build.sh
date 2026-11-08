#!/bin/zsh
# Builds Shrinkbox into build/Shrinkbox.app (ad-hoc signed unless SHRINKBOX_SIGN_IDENTITY is set), then installs it
# into /Applications and relaunches it, unless SHRINKBOX_NO_INSTALL is set or this runs in CI.
# SHRINKBOX_UNIVERSAL=1 builds for Apple Silicon and Intel (used by the release workflow).
set -euo pipefail
setopt nullglob   # an empty glob (no resource bundle) is not an error
cd "$(dirname "$0")"

build_arch() {  # $1 = arm64 | x86_64 (empty = host); prints only the bin path on stdout
  local flags=(-c release --build-system native)
  [ -n "${1:-}" ] && flags+=(--triple "$1-apple-macosx")
  local log; log="$(mktemp)"
  if ! swift build "${flags[@]}" > "$log" 2>&1; then
    cat "$log" >&2; rm -f "$log"
    echo "error: swift build failed" >&2; exit 1   # a failed build must stop the script, never be hidden
  fi
  grep -E "warning:|error:" "$log" | grep -v -E "deprecated|repeated" >&2 || true
  rm -f "$log"
  swift build "${flags[@]}" --show-bin-path 2>/dev/null
}

APP=build/Shrinkbox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${SHRINKBOX_UNIVERSAL:-0}" = 1 ]; then
  ARM_DIR="$(build_arch arm64 | tail -1)"; X86_DIR="$(build_arch x86_64 | tail -1)"
  lipo -create "$ARM_DIR/Shrinkbox" "$X86_DIR/Shrinkbox" -output "$APP/Contents/MacOS/Shrinkbox"
  BINDIR="$ARM_DIR"
else
  BINDIR="$(build_arch | tail -1)"
  cp "$BINDIR/Shrinkbox" "$APP/Contents/MacOS/Shrinkbox"
fi
# Resource bundles produced by packages sit next to the executable's resources.
for b in "$BINDIR"/*.bundle; do [ -d "$b" ] || continue; cp -R "$b" "$APP/Contents/Resources/"; done
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lp in Resources/*.lproj; do [ -d "$lp" ] || continue; cp -R "$lp" "$APP/Contents/Resources/"; done

# A stable signing identity keeps macOS privacy permissions across rebuilds; an ad-hoc signature changes on
# every build and makes macOS forget them.
IDENTITY="${SHRINKBOX_SIGN_IDENTITY:-Shrinkbox Local Signing}"
# On a CI runner the imported self-signed identity is not "trusted", so it is only listed without -v.
if { security find-identity -v -p codesigning; [ -n "${CI:-}" ] && security find-identity -p codesigning; true; } | grep -qF "$IDENTITY"; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "warning: signing identity '$IDENTITY' not found, falling back to ad-hoc (permissions will reset on every build)" >&2
fi
codesign --force --deep --sign "$SIGN" "$APP"
echo "Built $APP"

if [ -z "${CI:-}" ] && [ -z "${SHRINKBOX_NO_INSTALL:-}" ]; then
  ./install.sh --no-build
fi
