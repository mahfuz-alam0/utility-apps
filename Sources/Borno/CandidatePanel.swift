import AppKit

/// Suggestion list under the caret: roman text on top, Bangla candidates below, selection in accent color.
/// Non-activating, so the app you are typing in keeps focus.
final class CandidatePanel: NSPanel {
  static let shared = CandidatePanel()

  /// Called with the row index when a candidate is clicked.
  var onPick: ((Int) -> Void)? { didSet { list.onPick = onPick } }
  private let list = ListView()

  private init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let fx = NSVisualEffectView()
    fx.material = .popover
    fx.state = .active
    fx.wantsLayer = true
    fx.layer?.cornerRadius = 12
    fx.layer?.cornerCurve = .continuous
    fx.layer?.masksToBounds = true
    fx.layer?.borderWidth = 0.5
    fx.layer?.borderColor = NSColor.separatorColor.cgColor
    fx.addSubview(list)
    contentView = fx
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// `caret` is the caret line rectangle in screen coordinates (zero if the app did not report one).
  func show(header: String, items: [String], selected: Int, caret: NSRect) {
    list.set(header: header, items: items, selected: selected)
    let size = list.idealSize
    setContentSize(size)
    list.frame = NSRect(origin: .zero, size: size)
    setFrameOrigin(origin(for: size, caret: caret))
    invalidateShadow()
    if !isVisible {
      alphaValue = 0
      orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { $0.duration = 0.08; animator().alphaValue = 1 }
    }
  }

  func hide() { orderOut(nil) }

  private func origin(for size: NSSize, caret: NSRect) -> NSPoint {
    var c = caret
    if c == .zero { let m = NSEvent.mouseLocation; c = NSRect(x: m.x, y: m.y, width: 1, height: 18) }
    let screen = NSScreen.screens.first { $0.frame.contains(c.origin) } ?? NSScreen.main
    let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var p = NSPoint(x: c.minX - 8, y: c.minY - size.height - 6)             // below the line
    if p.y < area.minY { p.y = c.maxY + 6 }                                // no room: above it
    p.x = min(max(p.x, area.minX + 4), area.maxX - size.width - 4)
    return p
  }
}

private final class ListView: NSView {
  static let headH: CGFloat = 22, rowH: CGFloat = 26, inset: CGFloat = 4
  private var header = "", items: [String] = [], selected = 0
  var onPick: ((Int) -> Void)?

  private let headFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  private let wordFont = NSFont.systemFont(ofSize: 15)
  private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func set(header: String, items: [String], selected: Int) {
    self.header = header; self.items = items; self.selected = selected
    needsDisplay = true
  }

  var idealSize: NSSize {
    let words = items.map { ($0 as NSString).size(withAttributes: [.font: wordFont]).width }.max() ?? 0
    let head = (header as NSString).size(withAttributes: [.font: headFont]).width
    let w = min(max(words + 2 * (Self.inset + 10) + 24, head + 24, 110), 440)   // 24: room for the ⌥-number
    return NSSize(width: w, height: Self.headH + Self.inset + CGFloat(items.count) * Self.rowH + Self.inset)
  }

  override func draw(_ dirtyRect: NSRect) {
    (header as NSString).draw(at: NSPoint(x: 12, y: 4), withAttributes: [.font: headFont, .foregroundColor: NSColor.secondaryLabelColor])
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: Self.headH, width: bounds.width, height: 0.5).fill()

    for (i, word) in items.enumerated() {
      let row = NSRect(x: Self.inset, y: Self.headH + Self.inset + CGFloat(i) * Self.rowH,
                       width: bounds.width - 2 * Self.inset, height: Self.rowH)
      let on = i == selected
      if on {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
      }
      let attrs: [NSAttributedString.Key: Any] = [.font: wordFont, .foregroundColor: on ? NSColor.white : NSColor.labelColor]
      let h = (word as NSString).size(withAttributes: attrs).height
      (word as NSString).draw(at: NSPoint(x: row.minX + 8, y: row.minY + (row.height - h) / 2), withAttributes: attrs)
      if i < 9 {   // ⌥1-⌥9 picks this row
        let n = "\(i + 1)" as NSString
        let na: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: on ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor]
        let sz = n.size(withAttributes: na)
        n.draw(at: NSPoint(x: row.maxX - 10 - sz.width, y: row.minY + (row.height - sz.height) / 2), withAttributes: na)
      }
    }
  }

  override func mouseDown(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y - Self.headH - Self.inset
    let i = Int(y / Self.rowH)
    if y >= 0, i < items.count { onPick?(i) }
  }
}
