#!/bin/bash
# Stops and removes the app and its login item.
set -euo pipefail
LABEL="com.andresurena.ThunderboltDisplays.helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="/Applications/Thunderbolt Displays Audio.app"
LEGACY_APP="$HOME/Applications/ThunderboltDisplaysHelper.app"

echo "==> Stopping and removing the app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ThunderboltDisplaysHelper 2>/dev/null || true
# Remove "Open at Login" however it was set up (LaunchAgent or system login item).
BIN="$APP_DEST/Contents/MacOS/ThunderboltDisplaysHelper"
if [ -x "$BIN" ]; then "$BIN" --login-item off >/dev/null 2>&1 || true; fi
rm -f "$AGENT"
rm -rf "${APP_DEST:?}" "${LEGACY_APP:?}"
echo "Done."
