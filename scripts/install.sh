#!/bin/bash
# Installs the HAL plugin (needs sudo), restarts coreaudiod, installs the helper app
# in ~/Applications and registers it as a login item (LaunchAgent).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/Build/ThunderboltDisplays.driver"
APP="$ROOT/Build/ThunderboltDisplaysHelper.app"
LABEL="com.andresurena.ThunderboltDisplays.helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
APP_DEST="$HOME/Applications/ThunderboltDisplaysHelper.app"
LOG="$HOME/Library/Logs/ThunderboltDisplays.log"

if [ ! -d "$DRIVER" ] || [ ! -d "$APP" ]; then
  echo "Build first: $ROOT/scripts/build.sh" >&2
  exit 1
fi

echo "==> Installing HAL plugin into $HAL_DIR (asks for your password)"
sudo rm -rf "${HAL_DIR:?}/ThunderboltDisplays.driver"
sudo cp -R "$DRIVER" "$HAL_DIR/"
sudo chown -R root:wheel "$HAL_DIR/ThunderboltDisplays.driver"

echo "==> Restarting coreaudiod (audio drops for a second)"
sudo killall coreaudiod || true   # launchd respawns it with the new plugin

"$ROOT/scripts/install-helper.sh"
