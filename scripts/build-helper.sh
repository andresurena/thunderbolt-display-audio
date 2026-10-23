#!/bin/bash
# Builds the menu bar app that fans the main display's audio out to every Thunderbolt Display.
# Output: Build/Thunderbolt Displays Audio.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Build"
APP="$OUT/Thunderbolt Displays Audio.app"

rm -rf "${APP:?}" "${OUT:?}/ThunderboltDisplaysHelper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Helper/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Helper/AppIcon.icns" ]; then cp "$ROOT/Helper/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
swiftc -O -swift-version 5 \
  -framework AppKit -framework CoreAudio \
  -o "$APP/Contents/MacOS/ThunderboltDisplaysHelper" \
  "$ROOT"/Helper/*.swift

# Sign with an Apple Development identity when one exists so the audio permission sticks across
# rebuilds; fall back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.andresurena.ThunderboltDisplays.helper "$APP"
echo "Built: $APP"
