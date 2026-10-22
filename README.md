# Thunderbolt Displays Audio

One macOS output device, "Thunderbolt Displays", that plays through the speakers of
both Apple Thunderbolt Displays at once, with working keyboard volume and mute keys.

## How it works

```
apps ──▶ "Thunderbolt Displays" (HAL plugin, loopback)
                 │ volume / mute controls (driven by the keyboard keys)
                 ▼
     ThunderboltDisplaysHelper.app (menu bar, login item)
       • private aggregate device: [virtual ▸ Display Audio #1 (clock) ▸ Display Audio #2]
       • Core Audio drift-corrects the other two onto display #1's clock
       • IO callback copies the stereo into every display's output stream
       • mirrors the virtual device's volume/mute to each display's hardware volume
```

* `Plugin/ThunderboltDisplaysConfig.h` configures the HAL plugin, built from the vendored
  [BlackHole](https://github.com/ExistentialAudio/BlackHole) source (GPLv3). The plugin keeps
  BlackHole's volume/mute controls but does not attenuate in software (`kEnableVolumeControl false`).
* `Helper/` is the Swift helper. It finds every USB device named "Display Audio" with an output,
  builds the aggregate, and rebuilds it when displays come and go.

## Build and install

```bash
scripts/build.sh           # Build/ThunderboltDisplays.driver + Build/ThunderboltDisplaysHelper.app
scripts/install.sh         # sudo for the plugin + coreaudiod restart, then installs the helper
scripts/install-helper.sh  # helper only (no sudo): rebuild + reinstall after changing Helper/
scripts/uninstall.sh
```

coreaudiod is restarted with `killall coreaudiod` (launchd respawns it); `launchctl kickstart`
is refused under System Integrity Protection on macOS 26. The helper is signed with the local
"Apple Development" identity when one exists, so the microphone permission survives rebuilds.

After installing: allow the microphone prompt for the helper (it only reads the virtual device),
then choose "Thunderbolt Displays" in the Sound menu.

## Positioning left and right

Click the menu bar icon. Each display has a submenu:

* **Stereo (left + right)** — default, both channels on that display.
* **Left channel only** / **Right channel only** — use one display per channel for a wide stereo image.
* **Mono (left + right mixed)**.
* **Play Test Tone on This Display** — three beeps through that display only, so you know which is which.

"One Display per Channel" assigns display 1 = left, display 2 = right in one click; it becomes
"Swap Left and Right" once a split is active. Choices are stored per display UID in the helper's
preferences and survive restarts and replugging. Switching takes effect immediately.

## Notes

* The virtual device runs at 48 kHz; the helper switches both displays to 48 kHz.
* The helper adopts display #1's current volume when it starts, so nothing jumps.
* The aggregate also carries the virtual device's own output stream; the helper writes silence to
  it (never the audio), otherwise the loopback would echo forever.
* The menu bar status shows "audio flowing" / "silent"; the log records "Signal detected" / "Signal stopped".
* "Thunderbolt Displays" also appears as an *input* device. That is the loopback the helper reads;
  ignore it (or pick it in another app to record system audio, like BlackHole).
* Log: `~/Library/Logs/ThunderboltDisplays.log`. Menu bar: Rebuild Audio Routing, Show Log, Quit.
* Different display? Set `TBD_DISPLAY_DEVICE_NAME` in the LaunchAgent to the device name to match.
