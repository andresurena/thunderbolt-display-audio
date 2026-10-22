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

        if !snapshot.displays.isEmpty {
            let header = NSMenuItem(title: "Speakers", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for display in snapshot.displays {
                let entry = NSMenuItem(title: "\(display.label) — \(display.mode.shortTitle)", action: nil, keyEquivalent: "")
                entry.submenu = submenu(for: display)
                menu.addItem(entry)
            }
            if snapshot.displays.count >= 2 {
                let modes = snapshot.displays.prefix(2).map(\.mode)
                let split = (modes[0] == .leftOnly && modes[1] == .rightOnly) || (modes[0] == .rightOnly && modes[1] == .leftOnly)
                let title = split ? "Swap Left and Right" : "One Display per Channel (Left / Right)"
                menu.addItem(action(title, #selector(swapOrSplit)))
                let allStereo = snapshot.displays.allSatisfy { $0.mode == .stereo }
                let stereo = action("Stereo on Every Display", #selector(setAllStereo))
                stereo.state = allStereo ? .on : .off
                menu.addItem(stereo)
            }
            menu.addItem(.separator())

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

    private func submenu(for display: DisplaySummary) -> NSMenu {
        let sub = NSMenu()
        for mode in ChannelMode.allCases {
            let item = action(mode.title, #selector(changeMode(_:)))
            item.tag = Int(mode.rawValue)
            item.representedObject = display.uid
            item.state = mode == display.mode ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let tone = action("Play Test Tone on This Display", #selector(identify(_:)))
        tone.representedObject = display.uid
        sub.addItem(tone)
        return sub
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
        guard let uid = sender.representedObject as? String else { return }
        coordinator.identify(displayUID: uid)
    }

    @objc private func balanceChanged(_ sender: NSSlider) {
        var value = sender.floatValue
        if abs(value) < 0.04 { value = 0; sender.floatValue = 0 }   // snap to centre
        balanceView?.update(value)
        coordinator.setBalance(value)
    }

    @objc private func centreBalance() { coordinator.setBalance(0) }

    @objc private func swapOrSplit() { coordinator.swapOrSplitLeftRight() }
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
