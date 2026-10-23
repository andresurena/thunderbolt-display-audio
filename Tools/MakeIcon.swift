// Renders the app icon: two Thunderbolt Displays sending sound left and right.
// Usage: swift Tools/MakeIcon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"
let size = CGFloat(args.count > 2 ? Double(args[2])! : 1024)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = size / 1024   // design on a 1024 grid

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// Background squircle (macOS icon grid: 824 x 824 body centred in 1024, radius ~185).
let body = rect(100, 100, 824, 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1B2A4A).setFill()
bodyPath.fill()
ctx.restoreGState()
bodyPath.addClip()
NSGradient(colors: [color(0x2D4C86), color(0x14213D)])!.draw(in: body, angle: -90)
// soft top glow
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: rect(100, 560, 824, 364), angle: -90)

// Sound waves first, so the displays sit on top of their inner ends.
func waves(centerX: CGFloat, centerY: CGFloat, facingRight: Bool) {
    for (i, radius) in [CGFloat(32), 64, 96].enumerated() {
        let path = NSBezierPath()
        let start: CGFloat = facingRight ? -42 : 138
        let end: CGFloat = facingRight ? 42 : 222
        path.appendArc(withCenter: NSPoint(x: centerX * s, y: centerY * s), radius: radius * s, startAngle: start, endAngle: end)
        path.lineWidth = 20 * s
        path.lineCapStyle = .round
        color(0x7FD3FF, 1 - CGFloat(i) * 0.25).setStroke()
        path.stroke()
    }
}
waves(centerX: 252, centerY: 588, facingRight: false)
waves(centerX: 772, centerY: 588, facingRight: true)

// One Thunderbolt Display: aluminium bezel, black glass, screen glow, stand.
func display(x: CGFloat) {
    let w: CGFloat = 248, h: CGFloat = 180, y: CGFloat = 490
    // stand
    let neck = NSBezierPath(rect: rect(x + w / 2 - 34, y - 78, 68, 82))
    NSGradient(colors: [color(0xC9CED6), color(0x8D939C)])!.draw(in: neck, angle: 0)
    let foot = NSBezierPath(roundedRect: rect(x + w / 2 - 92, y - 92, 184, 20), xRadius: 10 * s, yRadius: 10 * s)
    NSGradient(colors: [color(0xD8DCE2), color(0x9AA0A9)])!.draw(in: foot, angle: -90)
    // bezel (black glass edge with aluminium chin, like the real display)
    let frame = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: 16 * s, yRadius: 16 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    color(0x0B0D12).setFill()
    frame.fill()
    ctx.restoreGState()
    // thin aluminium rim around the black glass, as on the real display
    let rim = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: 16 * s, yRadius: 16 * s)
    rim.lineWidth = 4 * s
    color(0xB8BEC7).setStroke()
    rim.stroke()
    // screen
    let screen = NSBezierPath(rect: rect(x + 16, y + 16, w - 32, h - 32))
    NSGradient(colors: [color(0x3FA9F5), color(0x6F5BD8)])!.draw(in: screen, angle: -60)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: rect(x + 16, y + 90, w - 32, h - 106), angle: -90)
}
display(x: 262)
display(x: 514)

// "L" and "R" badges under the displays.
func badge(_ text: String, centerX: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 74 * s, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: centerX * s - size.width / 2, y: 228 * s), withAttributes: attrs)
}
badge("L", centerX: 386)
badge("R", centerX: 638)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
