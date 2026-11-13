#!/bin/bash
# Builds the app, checks it is what the README promises, and zips it for a GitHub release.
# Output: Build/release/Thunderbolt-Displays-Audio.zip (plus its SHA-256 on stdout)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Build/Thunderbolt Displays Audio.app"
BIN="$APP/Contents/MacOS/ThunderboltDisplaysHelper"
ZIP="$ROOT/Build/release/Thunderbolt-Displays-Audio.zip"

"$ROOT/scripts/build-helper.sh"

MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$BIN")"
for arch in arm64 x86_64; do
  case " $ARCHS " in *" $arch "*) ;; *) echo "ERROR: binary has no $arch slice ($ARCHS)" >&2; exit 1 ;; esac
done
# Every slice must allow the minimum macOS the app claims.
BUILT_MIN="$(vtool -show-build "$BIN" | awk '/minos/ {print $2}' | sort -u | tr '\n' ' ')"
if [ "$BUILT_MIN" != "$MIN_MACOS " ]; then
  echo "ERROR: built for macOS $BUILT_MIN but Info.plist says $MIN_MACOS" >&2; exit 1
fi
codesign --verify --deep --strict "$APP"

mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Version $VERSION, $ARCHS, macOS $MIN_MACOS or later"
echo "Signed by: $(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')"
shasum -a 256 "$ZIP"
