// Draws the app icon .iconset:
//   swiftc Scripts/vitals/makeicon.swift -o /tmp/makeicon && /tmp/makeicon out/ && iconutil -c icns out/AppIcon.iconset -o Resources/vitals/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1] + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func appIcon(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px)
  let body = NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.2, yRadius: s * 0.2)
  NSGradient(starting: NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1),
             ending: NSColor(srgbRed: 0.86, green: 0.2, blue: 0.2, alpha: 1))!.draw(in: body, angle: -90)
  let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
  let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
  symbol.draw(in: NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
  return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
  try! appIcon(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
  try! appIcon(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
