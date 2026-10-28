// Renders Resources/AppIcon.icns and Resources/dmg-background.png: `swift Scripts/make-assets.swift`
import AppKit

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

/// Draws on a 1024 canvas (Apple icon grid: 824 body inset 100).
func draw() {
    let body = rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    hex(0x0B5ED7).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: hex(0x4DB0FF), ending: hex(0x0A58CA))!.draw(in: body, angle: -90)

    // back sheet (history)
    hex(0xFFFFFF, 0.4).setFill()
    rounded(NSRect(x: 340, y: 210, width: 420, height: 560), 56).fill()
    // front board
    NSGradient(starting: .white, ending: hex(0xE3ECF7))!.draw(in: rounded(NSRect(x: 270, y: 250, width: 440, height: 560), 56), angle: -90)
    // text lines
    hex(0x2B7FDB).setFill()
    rounded(NSRect(x: 340, y: 600, width: 300, height: 38), 19).fill()
    rounded(NSRect(x: 340, y: 520, width: 300, height: 38), 19).fill()
    rounded(NSRect(x: 340, y: 440, width: 190, height: 38), 19).fill()
    // clip
    hex(0x1B3A66).setFill()
    rounded(NSRect(x: 370, y: 745, width: 240, height: 110), 38).fill()
    hex(0x4F78B0).setFill()
    rounded(NSRect(x: 430, y: 782, width: 120, height: 36), 18).fill()
}

/// Renders `draw` (authored on a `design`-sized canvas) into a w×h pixel PNG. `dpi` 144 marks it as @2x for Finder.
func render(w: Int, h: Int, design: CGFloat, dpi: CGFloat = 72, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: CGFloat(w) * 72 / dpi, height: CGFloat(h) * 72 / dpi)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform()
    t.scale(by: CGFloat(w) * 72 / dpi / design)  // rep.size already maps points to pixels at this dpi
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func png(_ px: Int) -> Data { render(w: px, h: px, design: 1024, draw) }

/// Installer window background: 660×400 pt, same layout as the Prompter DMG (icons sit at y=190, x=170 and x=490).
func drawBackground() {
    NSGradient(starting: hex(0xFAFAFD), ending: hex(0xE5E8EF))!.draw(in: NSRect(x: 0, y: 0, width: 660, height: 400), angle: -90)

    func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (660 - size.width) / 2, y: 400 - y - size.height / 2), withAttributes: attrs)
    }
    centered("Install Clipboard Manager", y: 56, font: .systemFont(ofSize: 26, weight: .bold), color: hex(0x080C12), kern: -0.4)
    centered("Drag Clipboard Manager into your Applications folder", y: 88, font: .systemFont(ofSize: 14), color: hex(0x72767A))

    // arrow, vertically centered on the icons (y = 190 from top)
    let arrow = NSBezierPath()
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 256, y: 210)); arrow.line(to: NSPoint(x: 404, y: 210))
    arrow.move(to: NSPoint(x: 386, y: 228)); arrow.line(to: NSPoint(x: 404, y: 210)); arrow.line(to: NSPoint(x: 386, y: 192))
    hex(0x4E5057).setStroke()
    arrow.stroke()
}

let fm = FileManager.default
let set = ".build/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)  // also creates .build/
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try png(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try render(w: 1320, h: 800, design: 660, dpi: 144, drawBackground).write(to: URL(fileURLWithPath: "Resources/dmg-background.png"))
print("wrote Resources/AppIcon.icns, Resources/dmg-background.png")
