import AppKit

/// One metric in the menu bar: an optional gauge followed by its number(s).
struct Part: Equatable {
  enum Gauge: Equatable {
    case thermometer(Double), bar(Double), ring(Double), battery(Double, symbol: String?), arrows(up: Bool, down: Bool)
  }
  var gauge: Gauge?
  var lines: [String] = []  // one line, or two stacked (network up over down)
  var reserve = ""  // widest text this metric usually shows; the slot keeps that width so neighbours don't jiggle
}

/// The status item is one image: template (system-tinted) normally, drawn in orange/red when macOS reports trouble.
enum MenuBar {
  static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
  static let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
  static let height: CGFloat = 22
  static let spacing: CGFloat = 9  // between metrics
  static let gap: CGFloat = 3  // between a gauge and its number
  static let busy = 1_000.0  // bytes/s above which a network arrow lights up

  static func parts(_ s: Sample, _ display: [Metric: Display]) -> [Part] {
    Metric.allCases.compactMap { metric -> Part? in
      let mode = display[metric] ?? .off
      var part: Part
      switch metric {
      case _ where mode == .off: return nil
      case .temperature:
        guard let t = s.temperature else { return nil }
        part = Part(gauge: .thermometer(step(heat(t))), lines: ["\(Int(t.rounded()))°"], reserve: "88°")
      case .load:
        guard let load = s.load else { return nil }
        part = Part(gauge: .bar(step(load.total)), lines: ["\(Int((load.total * 100).rounded()))%"], reserve: "88%")
      case .memory:
        guard let p = s.pressurePercent else { return nil }
        part = Part(gauge: .ring(step(Double(p) / 100)), lines: ["\(p)%"], reserve: "88%")
      case .battery:
        guard let b = s.battery else { return nil }
        part = Part(gauge: .battery(step(Double(b.percent) / 100), symbol: b.powerSymbol), lines: ["\(b.percent)%"], reserve: "88%")
      case .network:
        let n = s.network ?? NetRate()
        let arrows = mode.showsGauge ? ["", ""] : ["↑ ", "↓ "]  // the gauge already draws the arrows
        part = Part(
          gauge: .arrows(up: n.up > busy, down: n.down > busy),
          lines: [arrows[0] + speed(n.up), arrows[1] + speed(n.down)], reserve: arrows[0] + "88.8 MB/s")
      }
      if !mode.showsGauge { part.gauge = nil }
      if !mode.showsValue { (part.lines, part.reserve) = ([], "") }
      return part
    }
  }

  /// Only metrics on screen can tint it: a hot CPU shouldn't colour a menu bar that only shows the battery.
  static func level(_ s: Sample, _ display: [Metric: Display]) -> Level {
    let on = { (m: Metric) in (display[m] ?? .off) != .off }
    return [
      on(.temperature) || on(.load) ? s.thermalLevel : .ok,
      on(.memory) ? s.memoryLevel : .ok,
      on(.battery) ? s.batteryLevel : .ok,
    ].max()!
  }

  static func summary(_ s: Sample) -> String {
    [
      s.temperature.map { "CPU \(Int($0.rounded())) °C" },
      s.load.map { "Load \(Int(($0.total * 100).rounded()))%" },
      s.pressurePercent.map { "Memory pressure \($0)%" },
      s.battery.map { "Battery \($0.percent)%" },
      s.network.map { "↑ \(speed($0.up))  ↓ \(speed($0.down))" },
    ].compactMap { $0 }.joined(separator: " · ")
  }

  static func image(_ parts: [Part], level: Level) -> NSImage {
    let widths = parts.map(width)
    let total = widths.reduce(0, +) + spacing * CGFloat(max(parts.count - 1, 0))
    let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
      let ink: NSColor = level == .critical ? .systemRed : level == .warning ? .systemOrange : .black
      var x: CGFloat = 0
      for (part, w) in zip(parts, widths) {
        if let gauge = part.gauge { draw(gauge, x: x, ink: ink) }
        text(part.lines, x: x + (part.gauge.map { gaugeWidth($0) + gap } ?? 0), ink: ink)
        x += w + spacing
      }
      return true
    }
    image.isTemplate = level == .ok
    return image
  }

  // MARK: drawing

  /// 20 °C empty, 110 °C full: Apple Silicon idles in the 30s–40s and runs 80–100 °C under load.
  static func heat(_ celsius: Double) -> Double { min(max((celsius - 20) / 90, 0), 1) }

  /// 5 % steps, so the image only redraws when a gauge visibly moves.
  private static func step(_ f: Double) -> Double { (min(max(f, 0), 1) * 20).rounded() / 20 }

  private static func attributes(_ font: NSFont, _ ink: NSColor) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: ink]
  }

  private static func textWidth(_ lines: [String], reserve: String) -> CGFloat {
    let font = lines.count > 1 ? small : font
    return (lines + [reserve]).map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
  }

  private static func width(_ p: Part) -> CGFloat {
    let gauge = p.gauge.map(gaugeWidth) ?? 0
    let text = p.lines.isEmpty ? 0 : textWidth(p.lines, reserve: p.reserve)
    return gauge + text + (gauge > 0 && text > 0 ? gap : 0)
  }

  private static func gaugeWidth(_ g: Part.Gauge) -> CGFloat {
    switch g {
    case .thermometer: 7
    case .bar: 5
    case .ring: 13
    case .battery: 23
    case .arrows: 7
    }
  }

  private static func text(_ lines: [String], x: CGFloat, ink: NSColor) {
    if lines.count == 1 {
      let s = NSAttributedString(string: lines[0], attributes: attributes(font, ink))
      s.draw(at: NSPoint(x: x, y: ((height - s.size().height) / 2).rounded()))
    } else {
      for (i, line) in lines.enumerated() {  // up on top, down below
        NSAttributedString(string: line, attributes: attributes(small, ink)).draw(at: NSPoint(x: x, y: i == 0 ? 10 : 0))
      }
    }
  }

  /// Track at 30 % ink, full ink from the bottom up to `top`, clipped to the shape.
  private static func fill(_ shape: NSBezierPath, upTo top: CGFloat, ink: NSColor) {
    ink.withAlphaComponent(0.3).setFill()
    shape.fill()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    ink.setFill()
    let b = shape.bounds
    NSRect(x: b.minX, y: b.minY, width: b.width, height: top - b.minY).fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  private static func draw(_ g: Part.Gauge, x: CGFloat, ink: NSColor) {
    let mid = height / 2
    switch g {
    case .bar(let f):
      let box = NSRect(x: x, y: mid - 7, width: 5, height: 14)
      fill(NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2), upTo: box.minY + box.height * f, ink: ink)

    case .thermometer(let f):
      let bulb = NSRect(x: x, y: mid - 7.5, width: 7, height: 7)
      let shape = NSBezierPath(ovalIn: bulb)
      shape.append(NSBezierPath(roundedRect: NSRect(x: x + 1.75, y: mid - 4, width: 3.5, height: 11.5), xRadius: 1.75, yRadius: 1.75))
      // the bulb is always full; the tube above it fills with the level
      let tube = bulb.maxY - 1.5
      fill(shape, upTo: tube + (mid + 7.5 - tube) * f, ink: ink)

    case .ring(let f):
      let center = NSPoint(x: x + 6.5, y: mid)
      let track = NSBezierPath()
      track.appendArc(withCenter: center, radius: 5.25, startAngle: 0, endAngle: 360)
      track.lineWidth = 2.5
      ink.withAlphaComponent(0.3).setStroke()
      track.stroke()
      guard f > 0 else { return }
      let arc = NSBezierPath()
      arc.appendArc(withCenter: center, radius: 5.25, startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
      arc.lineWidth = 2.5
      arc.lineCapStyle = .round
      ink.setStroke()
      arc.stroke()

    case .battery(let f, let symbolName):
      let body = NSRect(x: x + 0.5, y: mid - 5, width: 20, height: 10)
      let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
      outline.lineWidth = 1
      ink.withAlphaComponent(0.45).setStroke()
      outline.stroke()
      ink.withAlphaComponent(0.45).setFill()
      NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: mid - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
      let inner = body.insetBy(dx: 2, dy: 2)
      ink.setFill()
      NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * f, height: inner.height), xRadius: 1.5, yRadius: 1.5).fill()
      guard let symbolName, let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
      // knock a halo out of the fill, then draw the glyph, so it reads at any charge level
      let bolt = symbolName.hasPrefix("bolt")  // the plug is wider, so it gets a smaller glyph and halo
      for (size, op) in [(CGFloat(bolt ? 11 : 9), NSCompositingOperation.destinationOut), (bolt ? 8 : 6.5, .sourceOver)] {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: bolt ? .black : .bold).applying(.init(paletteColors: [ink]))
        guard let symbol = glyph.withSymbolConfiguration(config) else { continue }
        let s = symbol.size
        symbol.draw(in: NSRect(x: body.midX - s.width / 2, y: mid - s.height / 2, width: s.width, height: s.height), from: .zero, operation: op, fraction: 1)
      }

    case .arrows(let up, let down):
      for (lit, top) in [(up, true), (down, false)] {
        let y = top ? mid + 1.5 : mid - 6.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: top ? y : y + 5))
        path.line(to: NSPoint(x: x + 7, y: top ? y : y + 5))
        path.line(to: NSPoint(x: x + 3.5, y: top ? y + 5 : y))
        path.close()
        ink.withAlphaComponent(lit ? 1 : 0.3).setFill()
        path.fill()
      }
    }
  }
}
