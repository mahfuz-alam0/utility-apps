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
    NSColor(srgbRed: 8 / 255, green: 12 / 255, blue: 18 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2).fill()
    // one yellow title bar, three white text bars: reads as a prompter panel
    let bars: [(CGFloat, CGFloat, NSColor)] = [
        (0.70, 0.46, NSColor(srgbRed: 1, green: 0xcf / 255, blue: 0x5c / 255, alpha: 1)),
        (0.52, 0.62, .white), (0.38, 0.54, .white), (0.24, 0.40, .white),
    ]
    for (y, w, c) in bars {
        c.setFill()
        let h = s * 0.075
        NSBezierPath(roundedRect: NSRect(x: s * 0.2, y: s * y, width: s * w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
