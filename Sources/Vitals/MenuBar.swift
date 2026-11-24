import AppKit

/// One metric in the menu bar: an optional gauge followed by its number(s).
struct Part: Equatable {
  enum Gauge: Equatable {
    case thermometer(Double), bar(Double), arrows(up: Bool, down: Bool)
  }
  var gauge: Gauge?
  var lines: [String] = []  // one line, or two stacked (network up over down)
  var reserve = ""  // widest text this metric usually shows; the slot keeps that width so neighbours don't jiggle
  var heat = 0.0  // -0.5 sky blue (cold), 0 = menu-bar colour, 0.5 orange, 1 red
  var under: [Bar] = []  // thin bars under the number: CPU load over memory, stacked under the temperature

  struct Bar: Equatable {
    var fill: Double
    var heat = 0.0
  }
}

/// The status item is one image: template (system-tinted) normally, each metric blending toward orange/red as it climbs (temperature: sky blue when cold).
enum MenuBar {
  static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
  static let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
  static let height: CGFloat = 22
  static let spacing: CGFloat = 5  // between metrics
  static let gap: CGFloat = 3  // between a gauge and its number
  static let busy = 1_000.0  // bytes/s above which a network arrow lights up

  static func parts(_ s: Sample, _ display: [Metric: Display]) -> [Part] {
    // CPU load or memory as a gauge only, temperature as a number: their bars go under the number, saving their own slots
    let stacks = { (m: Metric) in display[m] == .gauge && (display[.temperature] ?? .off).showsValue && s.temperature != nil }
    return Metric.allCases.compactMap { metric -> Part? in
      let mode = display[metric] ?? .off
      var part: Part
      switch metric {
      case _ where mode == .off: return nil
      case .load where stacks(.load), .memory where stacks(.memory): return nil
      case .temperature:
        guard let t = s.temperature else { return nil }
        part = Part(gauge: .thermometer(step(heat(t))), lines: ["\(Int(t.rounded()))°"], reserve: "88°", heat: tempHeat(t))
        if stacks(.load), let load = s.load { part.under.append(Part.Bar(fill: step(load.total), heat: loadHeat(load.total))) }
        if stacks(.memory), let p = s.pressurePercent { part.under.append(Part.Bar(fill: step(Double(p) / 100), heat: memoryHeat(p))) }
      case .load:
        guard let load = s.load else { return nil }
        part = Part(gauge: .bar(step(load.total)), lines: ["\(Int((load.total * 100).rounded()))%"], reserve: "88%",
                    heat: loadHeat(load.total))
      case .memory:
        guard let p = s.pressurePercent else { return nil }
        part = Part(gauge: .bar(step(Double(p) / 100)), lines: ["\(p)%"], reserve: "88%", heat: memoryHeat(p))
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

  static func summary(_ s: Sample) -> String {
    [
      s.temperature.map { "CPU \(Int($0.rounded())) °C" },
      s.load.map { "Load \(Int(($0.total * 100).rounded()))%" },
      s.pressurePercent.map { "Memory pressure \($0)%" },
      s.network.map { "↑ \(speed($0.up))  ↓ \(speed($0.down))" },
    ].compactMap { $0 }.joined(separator: " · ")
  }

  /// Each metric tints itself by its own heat, so colour creeps in gradually instead of the whole bar flipping at once.
  static func image(_ parts: [Part]) -> NSImage {
    let widths = parts.map(width)
    let total = widths.reduce(0, +) + spacing * CGFloat(max(parts.count - 1, 0))
    let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
      // runs at draw time, so a non-template image still matches a light or dark menu bar
      let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let ink: NSColor = dark ? .white : .black
      var x: CGFloat = 0
      for (part, w) in zip(parts, widths) {
        let color = shade(part.heat, ink: ink)
        let textX = x + (part.gauge.map { gaugeWidth($0) + gap } ?? 0)
        if let gauge = part.gauge { draw(gauge, x: x, ink: color) }
        if !part.under.isEmpty {
          // number over its bars (first on top), the whole stack centred on the digits' cap height
          let (thick, between) = part.under.count > 1 ? (CGFloat(2.5), CGFloat(1.5)) : (3, 0)
          let stack = CGFloat(part.under.count) * (thick + between) - between
          let bottom = ((height - stack - 2 - font.capHeight) / 2).rounded()
          NSAttributedString(string: part.lines[0], attributes: attributes(font, color))
            .draw(at: NSPoint(x: textX, y: bottom + stack + 2 + font.descender))
          for (i, bar) in part.under.enumerated() {
            let y = bottom + stack - thick - CGFloat(i) * (thick + between)
            let track = NSRect(x: textX, y: y, width: x + w - textX, height: thick)
            let ink = shade(bar.heat, ink: ink)
            ink.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: thick / 2, yRadius: thick / 2).fill()
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: y, width: track.width * bar.fill, height: thick), xRadius: thick / 2, yRadius: thick / 2).fill()
          }
        } else {
          text(part.lines, x: textX, ink: color)
        }
        x += w + spacing
      }
      return true
    }
    image.isTemplate = parts.allSatisfy { $0.heat == 0 && $0.under.allSatisfy { $0.heat == 0 } }
    image.cacheMode = .never  // redraw when the menu bar flips between light and dark
    return image
  }

  // MARK: drawing

  /// Calibrate here. Sky blue up to 30 °C, fading to plain at 35; plain to 45; then orange at 57.5 and red from 70,
  /// every 0.5 °C mixing in 4 % more of the next colour.
  static func tempHeat(_ celsius: Double) -> Double {
    let t = (celsius * 2).rounded() / 2
    return t < 45 ? min(max((t - 35) / 10, -0.5), 0) : min((t - 45) / 25, 1)
  }
  /// Calibrate here. Plain until 60 % CPU load, orange at 80, red at 100.
  static func loadHeat(_ total: Double) -> Double { step((total - 0.6) / 0.4) }
  /// Calibrate here. Plain until 50 % memory pressure, orange at 70, red at 90.
  static func memoryHeat(_ percent: Int) -> Double { step((Double(percent) - 50) / 40) }

  /// Menu-bar colour at 0, blending to orange at 0.5 and red at 1, or the other way to sky blue at -0.5.
  static func shade(_ heat: Double, ink: NSColor) -> NSColor {
    if heat == 0 { return ink }
    if heat < 0 { return ink.blended(withFraction: heat * -2, of: .systemCyan) ?? .systemCyan }
    let (from, to, f) = heat < 0.5 ? (ink, NSColor.systemOrange, heat * 2) : (.systemOrange, .systemRed, heat * 2 - 1)
    return from.blended(withFraction: f, of: to) ?? to
  }

  /// 20 °C empty, 110 °C full: Apple Silicon idles in the 30s–40s and runs 80–100 °C under load.
  static func heat(_ celsius: Double) -> Double { min(max((celsius - 20) / 90, 0), 1) }

  /// 5 % steps, so the image only redraws when a gauge visibly moves.
  static func step(_ f: Double) -> Double { (min(max(f, 0), 1) * 20).rounded() / 20 }

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
