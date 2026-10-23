import AppKit
import CoreGraphics

// MARK: - Matching audio devices to screens

/// An Apple Thunderbolt Display reports the same serial to CoreGraphics (CGDisplaySerialNumber) as its
/// "Display Audio" USB device carries in its UID, e.g. "...:Display Audio:1A2B3C4D:2,1" <-> 0x1A2B3C4D.
enum ScreenMatch {
    /// CoreGraphics display ID of the screen whose serial matches, if that screen is active.
    static func displayID(forSerial serial: String) -> CGDirectDisplayID? {
        guard let value = UInt32(serial, radix: 16) else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplaySerialNumber($0) == value }
    }

    /// Horizontal centre of the matching screen in the global display arrangement, if known.
    static func midX(forSerial serial: String) -> CGFloat? {
        displayID(forSerial: serial).map { CGDisplayBounds($0).midX }
    }

    static func screen(forSerial serial: String) -> NSScreen? {
        guard let id = displayID(forSerial: serial) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}

// MARK: - Physical placement

/// Where each display's speakers physically are. Automatic follows the arrangement in
/// System Settings › Displays; the manual choice names the serial of the display on the left.
enum Placement {
    private static let manualLeftKey = "placement.manualLeftSerial"

    /// nil means automatic.
    static var manualLeftSerial: String? {
        get { UserDefaults.standard.string(forKey: manualLeftKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: manualLeftKey) }
            else { UserDefaults.standard.removeObject(forKey: manualLeftKey) }
        }
    }

    /// Serials ordered left to right. Manual choice first; otherwise screen arrangement; otherwise input order.
    static func leftToRight(_ serials: [String]) -> [String] {
        if let left = manualLeftSerial, serials.contains(left) {
            return [left] + serials.filter { $0 != left }
        }
        let positioned = serials.map { ($0, ScreenMatch.midX(forSerial: $0)) }
        guard positioned.allSatisfy({ $0.1 != nil }) else { return serials }
        return positioned.sorted { $0.1! < $1.1! }.map(\.0)
    }

    static var isAutomatic: Bool { manualLeftSerial == nil }
}

// MARK: - On-screen identification (like the red outline in System Settings › Displays)

/// Draws a coloured outline around a screen with a caption in the middle, then fades out.
final class ScreenOutline {
    private static var windows: [NSWindow] = []

    /// Must be called on the main thread.
    static func show(on screen: NSScreen, title: String, subtitle: String, duration: TimeInterval = 3) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = OutlineView(frame: NSRect(origin: .zero, size: screen.frame.size), title: title, subtitle: subtitle)
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        windows.append(window)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                windows.removeAll { $0 === window }
            })
        }
    }
}

private final class OutlineView: NSView {
    private let title: String
    private let subtitle: String

    init(frame: NSRect, title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let red = NSColor.systemRed
        let border = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5))
        border.lineWidth = 10
        red.setStroke()
        border.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttributes)
        let width = max(titleSize.width, subtitleSize.width) + 80
        let height = titleSize.height + subtitleSize.height + 50
        let card = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22)
        red.withAlphaComponent(0.92).setFill()
        cardPath.fill()

        (title as NSString).draw(at: NSPoint(x: card.midX - titleSize.width / 2, y: card.minY + 25 + subtitleSize.height), withAttributes: titleAttributes)
        (subtitle as NSString).draw(at: NSPoint(x: card.midX - subtitleSize.width / 2, y: card.minY + 22), withAttributes: subtitleAttributes)
    }
}
