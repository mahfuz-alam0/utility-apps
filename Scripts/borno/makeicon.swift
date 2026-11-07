// Draws the app icon (.iconset) and the input-menu icon (menu.tiff):
//   swiftc Scripts/borno/makeicon.swift -o /tmp/makeicon && /tmp/makeicon out/ && iconutil -c icns out/AppIcon.iconset -o Resources/borno/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out + "/AppIcon.iconset", withIntermediateDirectories: true)

func bitmap(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw(CGFloat(px))
  return rep
}

func glyph(_ s: CGFloat, size: CGFloat, color: NSColor, dy: CGFloat = 0) {
  let font = NSFont(name: "Kohinoor Bangla Semibold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
  let str = NSAttributedString(string: "অ", attributes: [.font: font, .foregroundColor: color])
  let b = str.size()
  str.draw(at: NSPoint(x: (s - b.width) / 2, y: (s - b.height) / 2 + dy))
}

func appIcon(_ px: Int) -> Data {
  bitmap(px) { s in
    let body = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(srgbRed: 0, green: 0.46, blue: 0.34, alpha: 1),
               ending: NSColor(srgbRed: 0, green: 0.30, blue: 0.22, alpha: 1))!.draw(in: path, angle: -90)
    NSColor(srgbRed: 0.96, green: 0.16, blue: 0.25, alpha: 1).setFill()                 // the red disc of the flag
    NSBezierPath(ovalIn: NSRect(x: s * 0.66, y: s * 0.68, width: s * 0.14, height: s * 0.14)).fill()
    glyph(s, size: s * 0.58, color: .white, dy: -s * 0.02)
  }.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try! appIcon(base).write(to: URL(fileURLWithPath: "\(out)/AppIcon.iconset/icon_\(base)x\(base).png"))
  try! appIcon(base * 2).write(to: URL(fileURLWithPath: "\(out)/AppIcon.iconset/icon_\(base)x\(base)@2x.png"))
}

// Menu-bar icon: black glyph on clear, 16 pt at 1x and 2x (the system tints it).
let menu = NSImage(size: NSSize(width: 16, height: 16))
for px in [16, 32] {
  let rep = bitmap(px) { s in glyph(s, size: s * 0.95, color: .black) }
  rep.size = NSSize(width: 16, height: 16)
  menu.addRepresentation(rep)
}
try! menu.tiffRepresentation!.write(to: URL(fileURLWithPath: out + "/menu.tiff"))
