#!/bin/bash
# Removes the helper, its login item and the HAL plugin (needs sudo), then restarts coreaudiod.
set -euo pipefail
LABEL="com.andresurena.ThunderboltDisplays.helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="$HOME/Applications/ThunderboltDisplaysHelper.app"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

echo "==> Stopping and removing helper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ThunderboltDisplaysHelper 2>/dev/null || true
rm -f "$AGENT"
rm -rf "${APP_DEST:?}"

echo "==> Removing HAL plugin (asks for your password)"
sudo rm -rf "${HAL_DIR:?}/ThunderboltDisplays.driver"
echo "==> Restarting coreaudiod"
sudo killall coreaudiod || true   # launchd respawns it with the new plugin
echo "Done. Pick another output device in the Sound menu if needed."
