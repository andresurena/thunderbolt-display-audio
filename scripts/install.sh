#!/bin/bash
# Installs (or updates) the app in /Applications, starts it, and makes it open at login.
#   scripts/install.sh              install, start, open at login
#   scripts/install.sh --no-login   install and start only; leaves "Open at Login" off
# No sudo needed on an admin account: nothing outside /Applications and ~/Library is touched.
set -euo pipefail
LOGIN=1
for arg in "$@"; do
  case "$arg" in
    --no-login) LOGIN=0 ;;
    *) echo "usage: $0 [--no-login]" >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Build/Thunderbolt Displays Audio.app"
LABEL="com.andresurena.ThunderboltDisplays.helper"
DOMAIN="gui/$(id -u)"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DEST="/Applications/Thunderbolt Displays Audio.app"
LEGACY_APP="$HOME/Applications/ThunderboltDisplaysHelper.app"
LOG="$HOME/Library/Logs/ThunderboltDisplays.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "$APP" ] || { echo "Build first: $ROOT/scripts/build.sh" >&2; exit 1; }

echo "==> Stopping the running helper"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before launchd has finished removing the service; loading it again too early fails.
for _ in $(seq 1 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
pkill -x ThunderboltDisplaysHelper 2>/dev/null || true

echo "==> Installing into /Applications"
mkdir -p "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
rm -rf "${APP_DEST:?}"
cp -R "$APP" "$APP_DEST"
if [ -d "$LEGACY_APP" ]; then rm -rf "${LEGACY_APP:?}"; echo "    removed old copy from ~/Applications"; fi
"$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
BIN="$APP_DEST/Contents/MacOS/ThunderboltDisplaysHelper"

if [ "$LOGIN" = 0 ]; then
  # Clear any earlier login setup (LaunchAgent or system login item), then just open the app.
  "$BIN" --login-item off >/dev/null 2>&1 || rm -f "$AGENT"
  echo "==> Starting the app (not added to login)"
  open -g "$APP_DEST"
  for _ in $(seq 1 25); do pgrep -x ThunderboltDisplaysHelper >/dev/null && break; sleep 0.2; done
  if ! pgrep -x ThunderboltDisplaysHelper >/dev/null; then
    echo "ERROR: the app did not start. Open it from /Applications to see why." >&2
    exit 1
  fi
  cat <<MSG

Done. "Thunderbolt Displays Audio" is in /Applications and running. It will not open at login;
tick "Open at Login" in its menu if you want that.
Log: $LOG
MSG
  exit 0
fi

# The LaunchAgent below is the login mechanism here. Drop a system login item left by an earlier
# downloaded copy, so the app is never started twice.
"$BIN" --login-item off >/dev/null 2>&1 || true

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
	<!-- Restart after a crash, but let "Quit" from the menu actually quit. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/ThunderboltDisplays.crash.log</string>
</dict>
</plist>
PLIST

echo "==> Starting helper"
for attempt in 1 2 3 4 5; do
  launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null && break
  sleep 1
done
for _ in $(seq 1 25); do pgrep -x ThunderboltDisplaysHelper >/dev/null && break; sleep 0.2; done
if ! pgrep -x ThunderboltDisplaysHelper >/dev/null; then
  echo "ERROR: the helper did not start. Check: launchctl print $DOMAIN/$LABEL" >&2
  exit 1
fi

cat <<MSG

Done. "Thunderbolt Displays Audio" is in /Applications and starts at login.
  1. If macOS asks whether it may record system audio, click Allow.
  2. Pick either "Display Audio" as the output in the Sound menu, or use
     "Use Thunderbolt Displays as Output" in its menu bar menu.
  3. The volume keys drive that display; the app keeps the other one in step.
  Quit from the menu stops it until next login. To stop it opening at login, untick
  "Open at Login" in its menu.
Log: $LOG
MSG
