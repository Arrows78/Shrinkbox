#!/bin/zsh
# Builds Shrinkbox, installs it into /Applications (replacing the previous copy) and relaunches it.
# Usage: ./install.sh [--no-launch] [--no-build]
# build.sh calls this by itself after a local build, so a plain ./build.sh already leaves the app in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

[[ " $* " == *" --no-build "* ]] || SHRINKBOX_NO_INSTALL=1 ./build.sh

DEST=/Applications/Shrinkbox.app
if pgrep -x Shrinkbox >/dev/null; then
  echo "Quitting running Shrinkbox…"
  osascript -e 'tell application id "dev.labs.shrinkbox" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x Shrinkbox >/dev/null || break; sleep 0.25; done
  pkill -x Shrinkbox 2>/dev/null || true   # SIGTERM: Shrinkbox restores Caps Lock before exiting
  sleep 0.5
fi
rm -rf "$DEST"
cp -R build/Shrinkbox.app "$DEST"
codesign --verify --deep "$DEST"
echo "Installed $DEST"

[[ " $* " == *" --no-launch "* ]] || open "$DEST"
