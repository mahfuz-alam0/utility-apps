// Draws the DMG window background (660x400 pt, @2x): swiftc makedmgbg.swift -o makedmgbg && ./makedmgbg bg.png [AppName]
import AppKit

let out = CommandLine.arguments[1]
let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Prompter"
let w: CGFloat = 660, h: CGFloat = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * 2, pixelsHigh: Int(h) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)  // 2x pixels, 660x400 points
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let ink = NSColor(srgbRed: 8 / 255, green: 12 / 255, blue: 18 / 255, alpha: 1)
NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1), ending: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 270)

func center(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    s.draw(at: NSPoint(x: (w - s.size().width) / 2, y: y))
}
center("Install \(name)", y: 330, size: 24, weight: .bold, color: ink)
center("Drag \(name) into your Applications folder", y: 304, size: 13, weight: .regular, color: ink.withAlphaComponent(0.55))

// arrow between the two icons (icon centres sit at y = 210 from the bottom)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 256, y: 210))
arrow.line(to: NSPoint(x: 404, y: 210))
arrow.move(to: NSPoint(x: 388, y: 226))
arrow.line(to: NSPoint(x: 404, y: 210))
arrow.line(to: NSPoint(x: 388, y: 194))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
ink.withAlphaComponent(0.7).setStroke()
arrow.stroke()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
