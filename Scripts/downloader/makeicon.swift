// Draws the app icon as an .iconset folder: swiftc makeicon.swift -o makeicon && ./makeicon AppIcon.iconset
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.55, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.05, green: 0.25, blue: 0.80, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2), angle: -90)
    // white arrow pointing at a tray: reads as "download"
    NSColor.white.setFill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: s * 0.42, y: s * 0.78))
    arrow.line(to: NSPoint(x: s * 0.58, y: s * 0.78))
    arrow.line(to: NSPoint(x: s * 0.58, y: s * 0.54))
    arrow.line(to: NSPoint(x: s * 0.70, y: s * 0.54))
    arrow.line(to: NSPoint(x: s * 0.50, y: s * 0.34))
    arrow.line(to: NSPoint(x: s * 0.30, y: s * 0.54))
    arrow.line(to: NSPoint(x: s * 0.42, y: s * 0.54))
    arrow.close()
    arrow.fill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.28, y: s * 0.20, width: s * 0.44, height: s * 0.065), xRadius: s * 0.03, yRadius: s * 0.03).fill()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
