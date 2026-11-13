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
# Universal binary (Apple Silicon + Intel) for the macOS version Info.plist promises. Without an
# explicit -target, swiftc builds for this Mac's chip and this Mac's macOS only.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Helper/Info.plist")"
SLICES="$OUT/slices"
mkdir -p "$SLICES"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos$MIN_MACOS" \
    -framework AppKit -framework CoreAudio \
    -o "$SLICES/ThunderboltDisplaysHelper-$arch" \
    "$ROOT"/Helper/*.swift
done
lipo -create "$SLICES/ThunderboltDisplaysHelper-arm64" "$SLICES/ThunderboltDisplaysHelper-x86_64" \
  -output "$APP/Contents/MacOS/ThunderboltDisplaysHelper"

# Sign with an Apple Development identity when one exists so the audio permission sticks across
# rebuilds; fall back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.andresurena.ThunderboltDisplays.helper "$APP"
echo "Built: $APP"
