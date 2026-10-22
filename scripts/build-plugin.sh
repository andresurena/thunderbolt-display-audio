#!/bin/bash
# Builds the "Thunderbolt Displays" HAL plugin from the vendored BlackHole source.
# Configuration lives in Plugin/ThunderboltDisplaysConfig.h.
# Output: Build/ThunderboltDisplays.driver
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/BlackHole"
OUT="$ROOT/Build"
CONFIG="$ROOT/Plugin/ThunderboltDisplaysConfig.h"

bundleID="com.andresurena.ThunderboltDisplays"
productName="ThunderboltDisplays"

rm -rf "${OUT:?}/${productName:?}.driver" "${OUT:?}/plugin-build"
xcodebuild \
  -project "$SRC/BlackHole.xcodeproj" \
  -target BlackHole \
  -configuration Release \
  SYMROOT="$OUT/plugin-build" \
  OBJROOT="$OUT/plugin-build" \
  CONFIGURATION_BUILD_DIR="$OUT" \
  PRODUCT_NAME="$productName" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundleID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  OTHER_CFLAGS="\$(inherited) -include $CONFIG" \
  build 2>&1 | grep -E "error:|BUILD " || true

test -d "$OUT/$productName.driver" && echo "Built: $OUT/$productName.driver"
