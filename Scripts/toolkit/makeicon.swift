// Draws the Toolkit icon as an .iconset folder: swiftc makeicon.swift -o makeicon && ./makeicon AppIcon.iconset
// A 2x2 grid of the four apps' own marks (clipboard, prompter bars, shield, Bangla অ) on a light squircle.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func round(_ r: NSRect, _ k: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.height * k, yRadius: r.height * k) }
func gradient(_ top: UInt32, _ bottom: UInt32, in path: NSBezierPath) { NSGradient(starting: rgb(top), ending: rgb(bottom))!.draw(in: path, angle: -90) }

/// One app tile at `r`; (u, v) are 0...1 inside it, v up.
func tile(_ r: NSRect, _ app: Int) {
    let t = r.width
    func p(_ u: CGFloat, _ v: CGFloat) -> NSPoint { NSPoint(x: r.minX + u * t, y: r.minY + v * t) }
    func box(_ u: CGFloat, _ v: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: r.minX + u * t, y: r.minY + v * t, width: w * t, height: h * t) }

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -t * 0.03)
    shadow.shadowBlurRadius = t * 0.07
    shadow.set()
    let body = round(r, 0.24)
    switch app {
    case 0: rgb(0x2F83E8).setFill()
    case 1: rgb(0x080C12).setFill()
    case 2: rgb(0x1A7AF5).setFill()
    default: rgb(0x006B50).setFill()
    }
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    switch app {
    case 0: gradient(0x58AAFF, 0x1560D8, in: body)
    case 3: gradient(0x007A5C, 0x004D3A, in: body)
    default: break
    }

    switch app {
    case 0:  // clipboard: white board, dark clip, three blue lines
        rgb(0xFFFFFF, 0.38).setFill(); round(box(0.34, 0.14, 0.44, 0.62), 0.1).fill()
        NSColor.white.setFill(); round(box(0.24, 0.2, 0.46, 0.6), 0.1).fill()
        rgb(0x153C78).setFill(); round(box(0.37, 0.74, 0.2, 0.12), 0.35).fill()
        rgb(0x2F7FE0).setFill()
        for (v, w) in [(0.6, 0.3), (0.48, 0.3), (0.36, 0.2)] as [(CGFloat, CGFloat)] { round(box(0.32, v, w, 0.05), 0.5).fill() }
    case 1:  // prompter: one yellow bar, three white bars
        for (v, w, c) in [(0.72, 0.4, rgb(0xFFCF5C)), (0.54, 0.54, .white), (0.40, 0.46, .white), (0.26, 0.34, .white)] as [(CGFloat, CGFloat, NSColor)] {
            c.setFill(); round(box(0.22, v, w, 0.075), 0.5).fill()
        }
    case 2:  // adwall: white shield, blue check
        let shield = NSBezierPath()
        shield.move(to: p(0.5, 0.86)); shield.line(to: p(0.8, 0.75)); shield.line(to: p(0.8, 0.46))
        shield.line(to: p(0.5, 0.16)); shield.line(to: p(0.2, 0.46)); shield.line(to: p(0.2, 0.75)); shield.close()
        NSColor.white.setFill(); shield.fill()
        let tick = NSBezierPath()
        tick.move(to: p(0.34, 0.47)); tick.line(to: p(0.45, 0.36)); tick.line(to: p(0.67, 0.65))
        tick.lineWidth = t * 0.085; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
        rgb(0x1A7AF5).setStroke(); tick.stroke()
    default:  // borno: Bangla অ
        let font = NSFont(name: "Kohinoor Bangla Semibold", size: t * 0.7) ?? NSFont.boldSystemFont(ofSize: t * 0.7)
        let str = NSAttributedString(string: "অ", attributes: [.font: font, .foregroundColor: NSColor.white])
        let b = str.size()
        str.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2 - t * 0.04))
    }
}

func icon(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let bodyRect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: s * 0.2, yRadius: s * 0.2)
    gradient(0xFAFBFD, 0xCBD2DD, in: body)
    rgb(0xFFFFFF, 0.7).setStroke(); body.lineWidth = max(1, s * 0.004); body.stroke()

    let pad = s * 0.095, gap = s * 0.05, t = (bodyRect.width - 2 * pad - gap) / 2
    for app in 0..<4 {
        let col = CGFloat(app % 2), row = CGFloat(1 - app / 2)  // clipboard, prompter on top; adwall, borno below
        tile(NSRect(x: bodyRect.minX + pad + col * (t + gap), y: bodyRect.minY + pad + row * (t + gap), width: t, height: t), app)
    }
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! icon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! icon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
