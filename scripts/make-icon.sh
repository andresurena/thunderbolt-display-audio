#!/bin/bash
# Regenerates Helper/AppIcon.icns from Tools/MakeIcon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
swiftc -O -o "$WORK/makeicon" "$ROOT/Tools/MakeIcon.swift"
for size in 16 32 128 256 512; do
  "$WORK/makeicon" "$SET/icon_${size}x${size}.png" "$size" >/dev/null
  "$WORK/makeicon" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Helper/AppIcon.icns"
"$WORK/makeicon" "$ROOT/Tools/AppIcon-preview.png" 512 >/dev/null
echo "Wrote $ROOT/Helper/AppIcon.icns"
