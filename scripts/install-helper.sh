#!/bin/bash
# Installs (or updates) only the helper app and its login item. No sudo needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Build/ThunderboltDisplaysHelper.app"
LABEL="com.andresurena.ThunderboltDisplays.helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="$HOME/Applications/ThunderboltDisplaysHelper.app"
LOG="$HOME/Library/Logs/ThunderboltDisplays.log"
[ -d "$APP" ] || { echo "Build first: $ROOT/scripts/build-helper.sh" >&2; exit 1; }

echo "==> Installing helper app into ~/Applications"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ThunderboltDisplaysHelper 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
rm -rf "${APP_DEST:?}"
cp -R "$APP" "$APP_DEST"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP_DEST/Contents/MacOS/ThunderboltDisplaysHelper</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
</dict>
</plist>
PLIST

echo "==> Starting helper"
launchctl bootstrap "gui/$(id -u)" "$AGENT"

cat <<MSG

Done.
  1. If macOS asks whether "Thunderbolt Displays Helper" may use the microphone, click Allow.
     (It only reads the virtual output device; nothing is recorded.)
  2. Pick "Thunderbolt Displays" as the output in the Sound menu or System Settings > Sound.
  3. The volume keys now drive both displays. A display.2 icon in the menu bar shows status.
Log: $LOG
MSG
