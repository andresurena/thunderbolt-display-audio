# Thunderbolt Displays Audio

Plays your Mac's audio through the speakers of both Apple Thunderbolt Displays at once, with
working keyboard volume and mute keys, per-display left/right positioning and a balance slider.
No driver, no system install, no microphone indicator.

## How it works

```
apps ──▶ Display Audio #1 (the Mac's output device; volume keys drive it natively)
              │  Core Audio process tap, muted at the source while tapped
              ▼
   ThunderboltDisplaysHelper.app (menu bar, login item)
     • private aggregate device: [Display Audio #1 (clock) ▸ Display Audio #2] + tap
     • Core Audio drift-corrects display #2 and the tap onto display #1's clock
     • IO callback writes the tapped stereo into each display, routed per display
     • mirrors display #1's hardware volume and mute to display #2
```

* The helper is in `Helper/`. It only routes while the Mac's output device is one of the
  Thunderbolt Displays. Pick any other output and it goes idle; pick a display again and it resumes.
* The tap excludes the helper's own process, so its output is never tapped back into itself.
* The IO proc's input is limited to the tap stream, so the displays' microphones are never started.
  macOS shows only the small purple "system audio recording" dot by Control Center, not the
  orange microphone indicator.
* Requires macOS 14.2 or later (process taps).

## Build and install

```bash
scripts/build.sh      # Build/ThunderboltDisplaysHelper.app
scripts/install.sh    # copies the helper to ~/Applications, registers the login item, starts it
scripts/uninstall.sh
```

No password is needed. If macOS asks whether "Thunderbolt Displays Helper" may record system
audio, click Allow. Then choose either "Display Audio" in the Sound menu, or click
"Use Thunderbolt Displays as Output" in the helper's menu.

Upgrading from the first, plugin-based version: `scripts/remove-legacy-plugin.sh` removes the old
"Thunderbolt Displays" virtual device (needs your password, restarts coreaudiod).

## Menu

* **Speakers**: each display has Stereo, Left only, Right only and Mono, plus
  "Play Test Tone on This Display" to tell the screens apart. The display marked "(volume keys)"
  is the one macOS outputs to.
* **One Display per Channel / Swap Left and Right**: one-click split, then swap if it's backwards.
* **Balance**: classic linear balance. The side you move toward stays at full level, the other
  fades to silence. Acts on each display's left/right speakers in stereo, or on the two displays
  in a split.
* Choices are saved per display and survive restarts and replugging.

## Notes

* Both displays and the aggregate run at 48 kHz.
* `FanOut.start()` runs off the helper's main work queue. If macOS is waiting on the permission
  prompt (it cannot show one while the screen is locked), the menu says so instead of freezing.
* Log: `~/Library/Logs/ThunderboltDisplays.log`. Menu: Rebuild Audio Routing, Show Log, Quit.
* Different display model? Set `TBD_DISPLAY_DEVICE_NAME` in the LaunchAgent to its device name.
