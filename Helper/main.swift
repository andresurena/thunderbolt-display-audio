import AppKit

/// Menu row holding the left/right balance slider.
final class BalanceView: NSView {
    let slider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let valueLabel = NSTextField(labelWithString: "")

    init(balance: Float, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        let title = NSTextField(labelWithString: "Balance")
        title.font = NSFont.menuFont(ofSize: 0)
        title.frame = NSRect(x: 14, y: 30, width: 80, height: 17)
        addSubview(title)

        valueLabel.font = NSFont.menuFont(ofSize: 0)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 140, y: 30, width: 106, height: 17)
        addSubview(valueLabel)

        let left = NSTextField(labelWithString: "L")
        left.font = NSFont.menuFont(ofSize: 0)
        left.frame = NSRect(x: 14, y: 6, width: 14, height: 17)
        addSubview(left)
        let right = NSTextField(labelWithString: "R")
        right.font = NSFont.menuFont(ofSize: 0)
        right.frame = NSRect(x: 234, y: 6, width: 14, height: 17)
        addSubview(right)

        slider.frame = NSRect(x: 30, y: 4, width: 200, height: 22)
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.floatValue = balance
        slider.target = target
        slider.action = action
        addSubview(slider)
        update(balance)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ balance: Float) {
        valueLabel.stringValue = Coordinator.describeBalance(balance).capitalized
    }
}

/// Payload for a Level menu item.
final class TrimChoice: NSObject {
    let uid: String
    let value: Float
    init(uid: String, value: Float) { self.uid = uid; self.value = value }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var balanceView: BalanceView?
    private var statusItem: NSStatusItem?
    private let coordinator = Coordinator()
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Thunderbolt Displays")
        item.button?.toolTip = "Thunderbolt Displays audio"
        menu.delegate = self
        menu.autoenablesItems = false   // items set isEnabled themselves
        item.menu = menu
        statusItem = item
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    // The menu is rebuilt every time it opens, so it always reflects the current displays and modes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = coordinator.snapshot()

        let statusLine = NSMenuItem(title: snapshot.status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        if !snapshot.isActive, !snapshot.outputIsDisplay, !snapshot.displays.isEmpty {
            menu.addItem(action("Use Thunderbolt Displays as Output", #selector(useDisplays)))
            menu.addItem(.separator())
        }

        if !snapshot.displays.isEmpty {
            let header = NSMenuItem(title: "Speakers", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for display in snapshot.displays {
                var title = display.side == .unknown ? display.label : "\(display.side.title) · \(display.label)"
                if snapshot.isActive { title += " — \(display.mode.shortTitle)" }
                if display.trim != 0 { title += " · \(LevelTrim.describe(display.trim))" }
                if display.isMain { title += " (volume keys)" }
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.submenu = submenu(for: display, active: snapshot.isActive)
                menu.addItem(entry)
            }
            menu.addItem(action("Identify Displays", #selector(identifyAll)))
            if snapshot.displays.count >= 2 {
                menu.addItem(positionItem(snapshot))
            }
            menu.addItem(.separator())
        }

        if snapshot.isActive, snapshot.displays.count >= 2 {
            let modes = snapshot.displays.map(\.mode)
            let split = modes.contains(.leftOnly) && modes.contains(.rightOnly)
            let splitItem = action("One Display per Channel (Left / Right)", #selector(splitByPlacement))
            splitItem.state = split && snapshot.displays.first?.mode == .leftOnly && snapshot.displays.last?.mode == .rightOnly ? .on : .off
            menu.addItem(splitItem)
            let swap = action("Swap Left and Right", #selector(swapLeftRight))
            swap.isEnabled = split
            menu.addItem(swap)
            let allStereo = modes.allSatisfy { $0 == .stereo }
            let stereo = action("Stereo on Every Display", #selector(setAllStereo))
            stereo.state = allStereo ? .on : .off
            menu.addItem(stereo)
            menu.addItem(.separator())
        }

        if snapshot.isActive, !snapshot.displays.isEmpty {
            let balanceItem = NSMenuItem(title: "Balance", action: nil, keyEquivalent: "")
            let view = BalanceView(balance: snapshot.balance, target: self, action: #selector(balanceChanged(_:)))
            balanceItem.view = view
            balanceView = view
            menu.addItem(balanceItem)
            let centre = action("Centre Balance", #selector(centreBalance))
            centre.isEnabled = snapshot.balance != 0
            menu.addItem(centre)
            menu.addItem(.separator())
        }

        menu.addItem(action("Rebuild Audio Routing", #selector(rebuild), key: "r"))
        menu.addItem(action("Open Sound Settings", #selector(openSoundSettings)))
        menu.addItem(action("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Thunderbolt Displays Helper", #selector(quit), key: "q"))
    }

    private func submenu(for display: DisplaySummary, active: Bool) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for mode in ChannelMode.allCases {
            let item = action(mode.title, #selector(changeMode(_:)))
            item.tag = Int(mode.rawValue)
            item.representedObject = display.uid
            item.state = mode == display.mode ? .on : .off
            item.isEnabled = active
            sub.addItem(item)
        }
        sub.addItem(.separator())

        let level = NSMenuItem(title: "Level: \(LevelTrim.describe(display.trim))", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for step in LevelTrim.steps {
            let item = action(LevelTrim.describe(step), #selector(changeTrim(_:)))
            item.representedObject = TrimChoice(uid: display.uid, value: step)
            item.state = step == display.trim ? .on : .off
            levels.addItem(item)
        }
        level.submenu = levels
        sub.addItem(level)
        sub.addItem(.separator())

        let identify = action("Identify (Outline Screen and Play Tone)", #selector(identify(_:)))
        identify.representedObject = display.uid
        sub.addItem(identify)
        return sub
    }

    private func positionItem(_ snapshot: Snapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let automatic = action(snapshot.arrangementKnown ? "Automatic (from Displays Settings)" : "Automatic (screens not detected)", #selector(setPlacementAutomatic))
        automatic.state = snapshot.manualLeftSerial == nil ? .on : .off
        sub.addItem(automatic)
        sub.addItem(.separator())
        for display in snapshot.displays {
            let pin = action("\(display.label) Is on the Left", #selector(setPlacementManual(_:)))
            pin.representedObject = display.serial
            pin.state = snapshot.manualLeftSerial == display.serial ? .on : .off
            sub.addItem(pin)
        }
        sub.addItem(.separator())
        sub.addItem(action("Open Displays Settings…", #selector(openDisplaysSettings)))
        item.submenu = sub
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func changeMode(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String, let mode = ChannelMode(rawValue: Int32(sender.tag)) else { return }
        coordinator.setMode(mode, forDisplayUID: uid)
    }

    @objc private func identify(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let display = coordinator.snapshot().displays.first(where: { $0.uid == uid }) else { return }
        outline(display)
        coordinator.identify(displayUID: uid)
    }

    /// Outline every display at once; play the tones one after another, left to right.
    @objc private func identifyAll() {
        let displays = coordinator.snapshot().displays
        for (position, display) in displays.enumerated() {
            outline(display, duration: 2.5 + Double(displays.count - 1) * 1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(position) * 1.2) { [coordinator] in
                coordinator.identify(displayUID: display.uid)
            }
        }
    }

    private func outline(_ display: DisplaySummary, duration: TimeInterval = 3) {
        guard let screen = ScreenMatch.screen(forSerial: display.serial) else {
            log("No screen matches \(display.label); cannot outline it")
            return
        }
        let title = display.side == .unknown ? "Speakers" : "\(display.side.title) Speakers"
        var subtitle = display.label
        if display.trim != 0 { subtitle += " · \(LevelTrim.describe(display.trim))" }
        if display.isMain { subtitle += " · volume keys" }
        ScreenOutline.show(on: screen, title: title, subtitle: subtitle, duration: duration)
    }

    @objc private func changeTrim(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TrimChoice else { return }
        coordinator.setTrim(choice.value, forDisplayUID: choice.uid)
    }

    @objc private func setPlacementAutomatic() { coordinator.setManualLeft(serial: nil) }

    @objc private func setPlacementManual(_ sender: NSMenuItem) {
        guard let serial = sender.representedObject as? String else { return }
        coordinator.setManualLeft(serial: serial)
    }

    @objc private func openDisplaysSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func balanceChanged(_ sender: NSSlider) {
        var value = sender.floatValue
        if abs(value) < 0.04 { value = 0; sender.floatValue = 0 }   // snap to centre
        balanceView?.update(value)
        coordinator.setBalance(value)
    }

    @objc private func centreBalance() { coordinator.setBalance(0) }
    @objc private func useDisplays() { coordinator.useDisplaysAsOutput() }

    @objc private func splitByPlacement() { coordinator.splitByPlacement() }
    @objc private func swapLeftRight() { coordinator.swapLeftRight() }
    @objc private func setAllStereo() { coordinator.setAllStereo() }
    @objc private func rebuild() { coordinator.requestRebuild() }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ThunderboltDisplays.log")
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Let launchd stop us cleanly so the private aggregate device is torn down.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApp.terminate(nil) }
termSource.resume()

log("Thunderbolt Displays Helper starting")
app.run()
