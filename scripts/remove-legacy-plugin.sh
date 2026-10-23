#!/bin/bash
# Removes the HAL plugin from the first version of this project (needs sudo) and restarts coreaudiod.
# Not needed on a fresh install: the tap-based helper has no plugin.
set -euo pipefail
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
if [ ! -d "$HAL_DIR/ThunderboltDisplays.driver" ]; then
  echo "No legacy plugin installed."; exit 0
fi
echo "==> Removing $HAL_DIR/ThunderboltDisplays.driver (asks for your password)"
sudo rm -rf "${HAL_DIR:?}/ThunderboltDisplays.driver"
echo "==> Restarting coreaudiod (audio drops for a second)"
sudo killall coreaudiod || true
echo "Done."
