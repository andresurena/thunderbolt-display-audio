# Thunderbolt Displays Audio

Plays your Mac's audio through the speakers of both Apple Thunderbolt Displays at once, with
working keyboard volume and mute keys, per-display left/right positioning and a balance slider.
No driver, no system install, no microphone indicator.

## How it works

```
apps ──▶ Display Audio #1 (the Mac's output device; volume keys drive it natively)
              │  Core Audio process tap, muted at the source while tapped
              ▼
   Thunderbolt Displays Audio.app (menu bar, login item, /Applications)
     • private aggregate device: [Display Audio #1 (clock) ▸ Display Audio #2] + tap
     • Core Audio drift-corrects display #2 and the tap onto display #1's clock
     • IO callback writes the tapped stereo into each display, routed per display
     • mirrors display #1's hardware volume (in dB, plus each display's level trim) and mute to display #2
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
scripts/build.sh      # Build/Thunderbolt Displays Audio.app
scripts/install.sh    # copies it to /Applications, registers the login item, starts it
scripts/uninstall.sh
scripts/make-icon.sh  # regenerates Helper/AppIcon.icns from Tools/MakeIcon.swift
```

No password is needed on an admin account. The install waits for launchd to finish unloading the
previous copy before loading the new one and fails loudly if the app does not start. Quit from the
menu stops the app until next login; it is only restarted automatically after a crash.

If macOS asks whether "Thunderbolt Displays Audio" may record system audio, click Allow. Then
choose either "Display Audio" in the Sound menu, or click "Use Thunderbolt Displays as Output" in
the app's menu.

Upgrading from the first, plugin-based version: `scripts/remove-legacy-plugin.sh` removes the old
"Thunderbolt Displays" virtual device (needs your password, restarts coreaudiod).

## Menu

* **Speakers**: displays are listed left to right. Each has Stereo, Left only, Right only and Mono,
  a **Level** trim (−6 to +6 dB) for a display that sounds quieter, and **Identify**, which draws a
  red outline with a caption on that screen (like System Settings › Displays) and plays three beeps
  through its speakers. The display marked "(volume keys)" is the one macOS outputs to.
* **Identify Displays** outlines every screen at once and beeps them in turn, left to right.
* **Position**: automatic follows the arrangement in System Settings › Displays. Each Thunderbolt
  Display reports the same serial to the display system as its "Display Audio" USB device, so the
  match is exact. You can also pin which display is on the left.
* **One Display per Channel (Left / Right)** uses that placement; **Swap Left and Right** flips it.
* **Balance**: classic linear balance. The side you move toward stays at full level, the other
  fades to silence. Acts on each display's left/right speakers in stereo, or on the two displays
  in a split.
* Choices are saved per display and survive restarts and replugging.

Level trim works on the hardware volume: the other display follows the main one's dB value plus
the trim difference. If a boost would exceed a display's hardware maximum, the shortfall is taken
off the other displays in software instead, so nothing clips and the difference is kept.

## Notes

* Both displays and the aggregate run at 48 kHz.
* The test tone uses its own short IO proc on the chosen display, so it plays even while nothing
  else does (the tap's IO is idle then).
* `FanOut.start()` runs off the helper's main work queue. If macOS is waiting on the permission
  prompt (it cannot show one while the screen is locked), the menu says so instead of freezing.
* Log: `~/Library/Logs/ThunderboltDisplays.log`. Menu: Rebuild Audio Routing, Show Log, Quit.
* Different display model? Set `TBD_DISPLAY_DEVICE_NAME` in the LaunchAgent to its device name.
