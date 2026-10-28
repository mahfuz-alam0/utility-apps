import AppKit

// MARK: - Rendering helpers

let accent = NSColor(srgbRed: 1, green: 0xcf / 255, blue: 0x5c / 255, alpha: 1)
let boldRx = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)

func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "") }

func textShadow() -> NSShadow {
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.9)
    sh.shadowOffset = NSSize(width: 0, height: -1)
    sh.shadowBlurRadius = 3
    return sh
}

func small(_ s: String, size: CGFloat = 12, color: NSColor = NSColor.white.withAlphaComponent(0.85), mono: Bool = false) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size),
        .foregroundColor: color,
        .shadow: textShadow(),
    ])
}

func inline(_ s: String, _ base: [NSAttributedString.Key: Any], _ bold: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let ns = s as NSString
    var last = 0
    for m in boldRx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: base))
        out.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)), attributes: bold))
        last = m.range.location + m.range.length
    }
    out.append(NSAttributedString(string: ns.substring(from: last), attributes: base))
    return out
}

func paragraph(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineHeightMultiple = 1.12
    p.paragraphSpacingBefore = before
    p.paragraphSpacing = after
    if indent > 0 {
        p.headIndent = indent
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
    }
    return p
}

func buildContent(_ step: Step, size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let shadow = textShadow()
    func attrs(_ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .shadow: shadow, .paragraphStyle: style]
    }
    func block(_ base: [NSAttributedString.Key: Any], _ boldFont: NSFont, _ text: String, prefix: String = "") {
        var strong = base
        strong[.font] = boldFont
        strong[.foregroundColor] = accent
        out.append(NSAttributedString(string: prefix, attributes: base))
        out.append(inline(text, base, strong))
        out.append(NSAttributedString(string: "\n", attributes: base))
    }
    let boldFont = NSFont.systemFont(ofSize: size, weight: .bold)
    if !step.title.isEmpty {
        let big = size * 1.3
        let f = NSFont.systemFont(ofSize: big, weight: .bold)
        block(attrs(f, accent, paragraph(after: big * 0.25)), f, step.title)
    }
    for item in step.items {
        switch item.kind {
        case .li:
            block(attrs(.systemFont(ofSize: size), .white, paragraph(after: size * 0.15, indent: size * 1.15)), boldFont, item.text, prefix: "•\t")
        case .cue:
            var base = attrs(.systemFont(ofSize: size * 0.65, weight: .semibold), .white, paragraph(before: size * 0.35, after: size * 0.1))
            base[.backgroundColor] = NSColor(srgbRed: 70 / 255, green: 140 / 255, blue: 230 / 255, alpha: 0.4)
            block(base, .systemFont(ofSize: size * 0.65, weight: .bold), "\u{00A0}\u{00A0}" + item.text + "\u{00A0}\u{00A0}")
        case .p:
            block(attrs(.systemFont(ofSize: size), .white, paragraph(after: size * 0.3)), boldFont, item.text)
        }
    }
    if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    return out
}

func textHeight(_ s: NSAttributedString, _ width: CGFloat) -> CGFloat {
    ceil(s.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
}

// MARK: - Views

final class DotsView: NSView {
    var n = 0
    var index = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<n {
            let c = NSPoint(x: 5.5 + CGFloat(i) * 12, y: bounds.midY)
            func disc(_ r: CGFloat, _ color: NSColor) {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            }
            if i == index {
                disc(5.5, accent.withAlphaComponent(0.35))
                disc(3.5, accent)
            } else {
                disc(3.5, NSColor.white.withAlphaComponent(i < index ? 0.6 : 0.28))
            }
        }
    }
}

final class BodyView: NSView {
    var text = NSAttributedString()
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { text.draw(with: bounds, options: [.usesLineFragmentOrigin]) }
}

final class GripView: NSView {
    private var start = (mouse: NSPoint.zero, frame: NSRect.zero)
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        accent.withAlphaComponent(0.75).setStroke()
        let p = NSBezierPath()
        for d in [6.0, 11.0] {
            p.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - 3 - d))
            p.line(to: NSPoint(x: bounds.maxX - 3 - d, y: bounds.maxY - 3))
        }
        p.lineWidth = 1.5
        p.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        start = (NSEvent.mouseLocation, window?.frame ?? .zero)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        let width = max(w.minSize.width, start.frame.width + m.x - start.mouse.x)
        let height = max(w.minSize.height, start.frame.height - (m.y - start.mouse.y))
        w.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height), display: true)
    }
}

final class PillButton: NSButton {
    enum Style { case normal, strong, danger }
    private let fg: NSColor
    init(_ title: String, _ action: String, _ style: Style = .normal) {
        fg = style == .strong ? NSColor(srgbRed: 0x1a / 255, green: 0x14 / 255, blue: 0x05 / 255, alpha: 1) : .white
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(action)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        switch style {
        case .normal:
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        case .strong:
            layer?.backgroundColor = accent.cgColor
            layer?.borderColor = accent.cgColor
        case .danger:
            layer?.backgroundColor = NSColor(srgbRed: 220 / 255, green: 70 / 255, blue: 70 / 255, alpha: 0.45).cgColor
            layer?.borderColor = NSColor(srgbRed: 1, green: 130 / 255, blue: 130 / 255, alpha: 0.6).cgColor
        }
        set(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { alphaValue = isHighlighted ? 0.6 : 1 } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func set(_ t: String) {
        attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg])
    }
    var fitWidth: CGFloat { ceil(attributedTitle.size().width) + 20 }
}

struct Snapshot {
    var steps: [Step]
    var index: Int
    var fontSize: CGFloat
    var bgAlpha: CGFloat
    var locked: Bool
    var protect: Bool
    var mode: Mode
    var playing: Bool
    var finished: Bool
    var left: Int
    var warnings: [String]
}

func makeLabel() -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.lineBreakMode = .byTruncatingTail
    return l
}

final class OverlayView: NSView {
    var onAction: (String) -> Void = { _ in }
    private var snap: Snapshot?
    private let dots = DotsView()
    private let count = makeLabel()
    private let next = makeLabel()
    private let warn = makeLabel()
    private let body = BodyView()
    private let grip = GripView()
    private let bar = NSView()
    private let blur = NSVisualEffectView()  // blurs the screen behind the overlay so text underneath doesn't fight the prompt
    private let tint = NSView()              // dark layer on top of the blur, strength = Bg slider
    private let protectBtn = PillButton("", "protect")
    private let playBtn = PillButton("Play", "play", .strong)
    private let modeBtn = PillButton("", "mode")
    private var buttons: [PillButton] = []
    private var warnKey = ""
    private var warnHidden = false
    private var warnTimer: Timer?
    private var progress = 0.0
    private var fit: (step: Step, size: CGFloat, area: NSSize, text: NSAttributedString)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        body.clipsToBounds = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        tint.wantsLayer = true
        for v in [blur, tint] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        bar.wantsLayer = true
        bar.layer?.backgroundColor = accent.cgColor
        buttons = [
            PillButton("Prev", "prev"), PillButton("Next", "next"), playBtn, modeBtn,
            PillButton("A\u{2212}", "fontDown"), PillButton("A+", "fontUp"),
            PillButton("Bg \u{2212}", "alphaDown"), PillButton("Bg +", "alphaUp"),
            protectBtn, PillButton("Lock", "lock"), PillButton("Stop", "stop", .danger),
        ]
        for b in buttons {
            b.target = self
            b.action = #selector(tap(_:))
            addSubview(b)
        }
        warn.lineBreakMode = .byWordWrapping
        warn.maximumNumberOfLines = 0
        for v in [dots, count, next, warn, body, grip, bar] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ b: NSButton) { onAction(b.identifier?.rawValue ?? "") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Auto mode countdown bar along the top edge; cheap, no relayout.
    func setProgress(_ p: Double) {
        progress = min(1, max(0, p))
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: 3)
    }

    func render(_ s: Snapshot) {
        snap = s
        tint.layer?.backgroundColor = NSColor(srgbRed: 8 / 255, green: 12 / 255, blue: 18 / 255, alpha: s.bgAlpha).cgColor
        blur.isHidden = s.bgAlpha == 0  // Bg at 0 = fully clear glass, no blur
        layer?.borderColor = (s.locked ? NSColor.white.withAlphaComponent(0.1) : accent.withAlphaComponent(0.75)).cgColor
        dots.n = s.steps.count <= 12 ? s.steps.count : 0
        dots.index = s.index
        dots.needsDisplay = true
        count.attributedStringValue = small("\(s.index + 1) / \(s.steps.count)", mono: true)
        protectBtn.set(s.protect ? "Hidden from recording: on" : "Hidden from recording: off")
        modeBtn.set(s.mode == .auto ? "Mode: Auto" : "Mode: Manual")
        playBtn.set(s.playing ? "Pause" : s.finished ? "Restart" : "Play")
        buttons.forEach { $0.isHidden = s.locked }
        playBtn.isHidden = s.locked || s.mode != .auto
        bar.isHidden = s.mode != .auto
        grip.isHidden = s.locked

        var status = ""
        if s.mode == .auto { status = s.finished ? "Finished · " : s.playing ? "\(clock(s.left)) left · " : "Paused · " }
        var nextText = status + "Last step"
        if s.index + 1 < s.steps.count {
            let t = plain(s.steps[s.index + 1].title)
            nextText = status + "Next: " + (t.isEmpty ? "continue" : t)
        }
        next.attributedStringValue = small(nextText)

        let key = s.warnings.joined(separator: "|")
        if key != warnKey {
            warnKey = key
            warnHidden = false
            warnTimer?.invalidate()
            if !s.warnings.isEmpty {
                warnTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
                    self?.warnHidden = true
                    self?.needsLayout = true
                }
            }
        }
        warn.attributedStringValue = small(s.warnings.joined(separator: "  "), color: accent)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let s = snap else { return }
        let padX: CGFloat = 18, padTop: CGFloat = 12, padBottom: CGFloat = 10, gap: CGFloat = 6
        let right = bounds.width - padX
        let inner = right - padX

        // header: dots, counter, wrapped right-aligned tool buttons
        var x = padX
        let dotsW = CGFloat(dots.n) * 12
        let cs = count.attributedStringValue.size()
        let countW = ceil(cs.width) + 4
        x += dotsW + (dots.n > 0 ? 8 : 0) + countW + 10
        let shown = buttons.filter { !$0.isHidden }
        var rows: [[PillButton]] = [[]]
        var used: CGFloat = 0
        for b in shown {
            if used > 0 && used + gap + b.fitWidth > right - x {
                rows.append([])
                used = 0
            }
            used += (used > 0 ? gap : 0) + b.fitWidth
            rows[rows.count - 1].append(b)
        }
        let rowsH = shown.isEmpty ? 0 : CGFloat(rows.count) * 22 + CGFloat(rows.count - 1) * gap
        let headH = max(24, rowsH)
        var y = padTop + (headH - rowsH) / 2
        for row in rows {
            var rx = right - row.reduce(0) { $0 + $1.fitWidth } - CGFloat(row.count - 1) * gap
            for b in row {
                b.frame = NSRect(x: rx, y: y, width: b.fitWidth, height: 22)
                rx += b.fitWidth + gap
            }
            y += 22 + gap
        }
        let midY = padTop + headH / 2
        dots.frame = NSRect(x: padX, y: midY - 5.5, width: dotsW, height: 11)
        count.frame = NSRect(x: padX + dotsW + (dots.n > 0 ? 8 : 0), y: midY - ceil(cs.height) / 2, width: countW, height: ceil(cs.height))

        // footer
        let footH: CGFloat = 16
        let footY = bounds.height - padBottom - footH
        next.frame = NSRect(x: padX, y: footY, width: inner - (s.locked ? 0 : 20), height: footH)
        grip.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18)

        // warning line
        var bottom = footY - gap
        let showWarn = !warnHidden && !s.warnings.isEmpty
        warn.isHidden = !showWarn
        if showWarn {
            let h = textHeight(warn.attributedStringValue, inner)
            bottom -= h
            warn.frame = NSRect(x: padX, y: bottom, width: inner, height: h)
            bottom -= gap
        }

        // content: shrink the font until it fits (memoised: layout also runs on every timer tick)
        let top = padTop + headH + gap
        let area = NSRect(x: padX, y: top, width: inner, height: max(0, bottom - top))
        let step = s.steps[s.index]
        if let f = fit, f.step == step, f.size == s.fontSize, f.area == area.size {
            body.text = f.text
        } else {
            var size = s.fontSize
            var text = buildContent(step, size: size)
            while size > 13 && textHeight(text, area.width) > area.height + 1 {
                size -= 1
                text = buildContent(step, size: size)
            }
            fit = (step, s.fontSize, area.size, text)
            body.text = text
        }
        body.frame = area
        body.needsDisplay = true
        setProgress(progress)
    }
}

final class Overlay: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
