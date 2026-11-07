// Draws the Toolkit icon as an .iconset folder: swiftc makeicon.swift -o makeicon && ./makeicon AppIcon.iconset
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    NSColor(srgbRed: 8 / 255, green: 12 / 255, blue: 18 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.2, yRadius: s * 0.2).fill()
    // 2x2 tiles, one per app
    let colors: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 1), NSColor(srgbRed: 1, green: 0xcf / 255, blue: 0x5c / 255, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.38, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.35, green: 0.80, blue: 0.55, alpha: 1),
    ]
    let t = s * 0.30, gap = s * 0.05, x0 = s * 0.5 - t - gap / 2, y0 = s * 0.5 - t - gap / 2
    for (i, c) in colors.enumerated() {
        c.setFill()
        let r = NSRect(x: x0 + CGFloat(i % 2) * (t + gap), y: y0 + CGFloat(i / 2) * (t + gap), width: t, height: t)
        NSBezierPath(roundedRect: r, xRadius: t * 0.25, yRadius: t * 0.25).fill()
    }
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
