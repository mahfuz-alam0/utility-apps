// Draws the Toolkit icon as an .iconset folder: swiftc makeicon.swift -o makeicon && ./makeicon AppIcon.iconset
// A multi-tool opened from one handle: file, ring wrench, knife, screwdriver, on a deep indigo squircle.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let bgTop: UInt32 = 0x2C3480, bgBottom: UInt32 = 0x0B0D24

/// A tool lies along +x from the pivot (0,0). Coordinates are fractions of the canvas.
func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    pts.dropFirst().forEach { p.line(to: NSPoint(x: $0.0, y: $0.1)) }
    p.close()
    return p
}
func bar(_ x0: CGFloat, _ x1: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x0, y: -h / 2, width: x1 - x0, height: h), xRadius: h / 2, yRadius: h / 2)
}

enum Tool { case screwdriver, knife, wrench, file }

func shape(_ tool: Tool, _ L: CGFloat) -> [NSBezierPath] {
    switch tool {
    case .screwdriver:  // thin shaft, flat tip
        return [poly([(0, -0.022), (L - 0.09, -0.022), (L - 0.09, -0.05), (L, -0.05), (L, 0.05), (L - 0.09, 0.05), (L - 0.09, 0.022), (0, 0.022)])]
    case .knife:  // straight spine, curved-in edge, pointed tip
        return [poly([(0, -0.05), (L - 0.26, -0.05), (L, 0.05), (0, 0.05)])]
    case .wrench:  // shaft ending in a ring
        let ring = NSBezierPath(ovalIn: NSRect(x: L - 0.11, y: -0.11, width: 0.22, height: 0.22))
        ring.append(NSBezierPath(ovalIn: NSRect(x: L - 0.045, y: -0.045, width: 0.09, height: 0.09)))
        ring.windingRule = .evenOdd
        return [bar(0, L - 0.08, 0.075), ring]
    case .file:  // plain bar with a rounded end
        return [bar(0, L, 0.095)]
    }
}

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: rgb(bgTop), ending: rgb(bgBottom))!.draw(in: body, angle: -90)

    let pivot = NSPoint(x: s * 0.385, y: s * 0.365)
    func place(_ part: NSBezierPath, angle: CGFloat) {
        var t = AffineTransform(translationByX: pivot.x, byY: pivot.y)
        t.rotate(byDegrees: angle)
        t.scale(s)
        part.transform(using: t)
    }
    // back to front: file, wrench, knife, screwdriver; each leaves a thin gap where it overlaps the one behind
    let tools: [(Tool, CGFloat, CGFloat, UInt32)] = [
        (.file, 0, 0.47, 0xFF6B6B), (.wrench, 28, 0.45, 0x3DD68C), (.knife, 56, 0.53, 0x4DA3FF), (.screwdriver, 84, 0.52, 0xFFCF5C),
    ]
    for (tool, angle, L, color) in tools {
        let parts = shape(tool, L)
        for part in parts { place(part, angle: angle); part.lineJoinStyle = .round }
        for part in parts { part.lineWidth = s * 0.034; rgb(bgBottom).setStroke(); part.stroke() }  // gap
        for part in parts {
            part.lineWidth = s * 0.016
            rgb(color).setStroke(); rgb(color).setFill()
            part.fill(); part.stroke()                                                               // rounded corners
        }
    }
    // shared handle, pointing down-left from the pivot
    let handle = bar(-0.085, 0.30, 0.17)
    place(handle, angle: 225)
    rgb(bgBottom).setStroke(); handle.lineWidth = s * 0.018; handle.stroke()
    NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xC9D0E4))!.draw(in: handle, angle: 225)
    // rivet
    let r = s * 0.034
    rgb(bgBottom).setFill()
    NSBezierPath(ovalIn: NSRect(x: pivot.x - r, y: pivot.y - r, width: 2 * r, height: 2 * r)).fill()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
