import AppKit
import Combine
import SwiftUI

// MARK: - Window

/// Borderless and key, but non-activating: the app you were in stays frontmost. A click elsewhere or Esc closes it.
final class Panel: NSPanel {
  var onResign: (() -> Void)?
  var onEscape: (() -> Void)?

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: PopupController.width, height: 452), styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  override var canBecomeKey: Bool { true }
  override func resignKey() { super.resignKey(); onResign?() }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, event.keyCode == 53 { onEscape?() } else { super.sendEvent(event) }
  }
}

/// UI state lives here, not in @State: the Command Line Tools SDK can't expand SwiftUI's @State macro.
@MainActor
final class PopupModel: ObservableObject {
  enum Page: Hashable { case overview, cpu, memory, network, settings }
  @Published var page = Page.overview
  @Published var hovered: Page?
  @Published var shown = false
  let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"

  func go(_ page: Page) {
    withAnimation(.snappy(duration: 0.28)) { self.page = page }
  }

  func hover(_ page: Page, _ inside: Bool) {
    if inside { hovered = page } else if hovered == page { hovered = nil }
  }
}

@MainActor
final class PopupController {
  static let width: CGFloat = 360
  static let radius: CGFloat = 20
  /// Each page is as tall as its content, and never shorter than the overview the popup opens on. Measured rather
  /// than hard-coded: fixed heights drifted from the content, leaving empty space or eating the padding.
  func height(_ page: PopupModel.Page) -> CGFloat {
    func measure(_ page: PopupModel.Page) -> CGFloat {
      let m = PopupModel()  // not `model`: while a page change is being published, it still holds the old page
      m.page = page
      return NSHostingView(rootView: PopupView(monitor: monitor, prefs: prefs, model: m) {}.frame(width: Self.width)).fittingSize.height
    }
    return max(measure(page), measure(.overview))
  }
  /// Rounded corners that stretch to whatever height the page needs.
  private static let mask: NSImage = {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }()
  private let panel = Panel()
  private let model = PopupModel()
  private let monitor: Monitor
  private let prefs: Prefs
  private var closedAt = Date.distantPast
  private var pages: AnyCancellable?
  var onVisible: ((Bool) -> Void)?

  init(monitor: Monitor, prefs: Prefs) {
    self.monitor = monitor
    self.prefs = prefs
    panel.onResign = { [weak self] in self?.hide() }
    panel.onEscape = { [weak self] in
      guard let self else { return }
      if model.page == .overview { hide() } else { model.go(.overview) }
    }
    pages = model.$page.dropFirst().removeDuplicates().sink { [weak self] in self?.fit($0) }
  }

  /// Resize for a page, top edge pinned under the status item.
  private func fit(_ page: PopupModel.Page) {
    guard panel.isVisible else { return }
    var frame = panel.frame
    let height = self.height(page)
    frame.origin.y += frame.height - height
    frame.size.height = height
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.22
      panel.animator().setFrame(frame, display: true)
    } completionHandler: { [weak panel] in panel?.invalidateShadow() }
  }

  /// A click on the status item closes an open popup. If that same click already closed it (the panel lost key
  /// first), it must not reopen.
  func toggle(below anchor: NSWindow) {
    if panel.isVisible { hide() } else if Date().timeIntervalSince(closedAt) > 0.25 { show(below: anchor) }
  }

  private func show(below anchor: NSWindow) {
    model.page = .overview
    model.hovered = nil
    model.shown = false
    let size = NSSize(width: Self.width, height: height(.overview))
    let host = NSHostingView(rootView: PopupView(monitor: monitor, prefs: prefs, model: model) { [weak self] in self?.hide() })
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    host.sizingOptions = []  // the controller sizes the panel per page; inside glass the host would otherwise resize it to fit
    if #available(macOS 26, *) {
      let glass = NSGlassEffectView(frame: host.frame)
      glass.cornerRadius = Self.radius
      glass.appearance = NSAppearance(named: .darkAqua)
      glass.contentView = host
      glass.autoresizingMask = [.width, .height]
      // The glass alone leaves the window's alpha square, so macOS traced a square shadow with a dark rim around the
      // round glass. A clipping layer of the same shape makes the window round, and its shadow with it.
      let root = NSView(frame: host.frame)
      root.wantsLayer = true
      root.layer?.cornerRadius = Self.radius
      root.layer?.cornerCurve = .continuous
      root.layer?.masksToBounds = true
      root.addSubview(glass)
      panel.contentView = root
    } else {
      let blur = NSVisualEffectView(frame: host.frame)
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      blur.appearance = NSAppearance(named: .darkAqua)
      blur.maskImage = Self.mask
      blur.addSubview(host)
      panel.contentView = blur
    }

    // centred under the status item, kept on its screen
    let screen = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
    let x = min(max(anchor.frame.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: anchor.frame.minY - size.height - 6), size: size), display: true)
    panel.makeKeyAndOrderFront(nil)
    // next turn, once the new content is committed: traced now, the shadow follows whatever the window last showed
    DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
    onVisible?(true)
  }

  func hide() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    closedAt = Date()
    onVisible?(false)
    // Drop the SwiftUI tree so nothing renders while closed. Next turn: a button inside it may be what closed it.
    DispatchQueue.main.async { [self] in if !panel.isVisible { panel.contentView = nil } }
  }
}

// MARK: - Look: a dark instrument panel, one signal colour per vital

extension Color {
  static let cpuTint = Color(red: 1.0, green: 0.55, blue: 0.38)
  static let memTint = Color(red: 0.38, green: 0.76, blue: 1.0)
  static let okTint = Color(red: 0.36, green: 0.88, blue: 0.55)
  static let netTint = Color(red: 1.0, green: 0.78, blue: 0.32)
  static let upTint = Color(red: 0.76, green: 0.66, blue: 1.0)
  static let wiredTint = Color(red: 0.62, green: 0.56, blue: 1.0)
  static let squeezedTint = Color(red: 1.0, green: 0.48, blue: 0.68)
  static let text1 = Color.white.opacity(0.94)
  static let text2 = Color.white.opacity(0.58)
  static let text3 = Color.white.opacity(0.36)
}

extension Level {
  var color: Color {
    switch self {
    case .ok: .okTint
    case .warning: Color(red: 1.0, green: 0.68, blue: 0.26)
    case .critical: Color(red: 1.0, green: 0.38, blue: 0.38)
    }
  }
}

/// `calm` while a vital is normal, blending through orange to red as it climbs: the menu bar's ramp, so nothing flips at one reading.
func heated(_ calm: Color, _ heat: Double) -> Color { Color(nsColor: MenuBar.shade(heat, ink: NSColor(calm))) }

extension Sample {
  var cpuHeat: Double { temperature.map(MenuBar.tempHeat) ?? MenuBar.loadHeat(load?.total ?? 0) }
  var memoryHeat: Double { MenuBar.memoryHeat(pressurePercent ?? 0) }
}

private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

/// Range that fits the values with some air, so a flat line sits mid-chart instead of on the floor.
private func around(_ values: [Double], minSpan: Double) -> ClosedRange<Double> {
  guard let lo = values.min(), let hi = values.max() else { return 0...1 }
  let mid = (lo + hi) / 2, half = max(hi - lo, minSpan) / 2 * 1.2
  return (mid - half)...(mid + half)
}

private func netRange(_ h: History) -> ClosedRange<Double> { 0...max(((h.down + h.up).max() ?? 0) * 1.15, 20_000) }

private func tileShape() -> some View {
  RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.055))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
}

// MARK: - Root

struct PopupView: View {
  @ObservedObject var monitor: Monitor
  @ObservedObject var prefs: Prefs
  @ObservedObject var model: PopupModel
  let close: () -> Void

  var body: some View {
    let s = monitor.sample
    ZStack {
      // a light dark wash keeps white text readable over bright wallpapers without hiding the glass
      LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
      Group {
        switch model.page {
        case .overview:
          Overview(s: s, history: monitor.history, model: model, close: close)
            .transition(.move(edge: .leading).combined(with: .opacity))
        case .settings:
          SettingsPage(prefs: prefs, model: model).transition(.move(edge: .trailing).combined(with: .opacity))
        default:
          DetailPage(s: s, history: monitor.history, model: model).transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: PopupController.radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: PopupController.radius, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    .foregroundStyle(Color.text1)
    .environment(\.colorScheme, .dark)
    .opacity(model.shown ? 1 : 0)  // fade only: scaling would pull the edge and border off the glass, which doesn't scale
    .onAppear { withAnimation(.easeOut(duration: 0.16)) { model.shown = true } }
  }
}

// MARK: - Overview

struct Overview: View {
  let s: Sample
  let history: History
  @ObservedObject var model: PopupModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      header
      VStack(spacing: 0) {
        cpu
        divider
        memory
        divider
        network
      }
      .padding(4)
      .background(tileShape())
      Spacer(minLength: 0)
      footer
    }
  }

  private var divider: some View { Divider().overlay(Color.white.opacity(0.03)).padding(.leading, 50).padding(.trailing, 8) }

  private var header: some View {
    let health = s.health
    return HStack(spacing: 10) {
      Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .semibold)).foregroundStyle(health.level.color)
        .frame(width: 30, height: 30).background(Circle().fill(health.level.color.opacity(0.13)))
      VStack(alignment: .leading, spacing: 1) {
        Text(health.headline).font(.system(size: 14, weight: .semibold))
        Text([model.chip, bootDate.map { "up " + uptime(since: $0) }].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 11)).foregroundStyle(Color.text2)
      }
      Spacer()
    }
  }

  private var cpu: some View {
    let t = s.temperature
    let load = s.load.map { Int(($0.total * 100).rounded()) }
    let trace = t == nil ? history.load : history.temperature
    return VitalRow(symbol: "cpu", title: "CPU", detail: "Load " + (load.map { "\($0)%" } ?? "–"), tint: .cpuTint, page: .cpu, model: model) {
      Trace(values: trace, range: t == nil ? 0...100 : around(trace, minSpan: 10), color: .cpuTint)
    } value: {
      Big(value: t.map { "\(Int($0.rounded()))" } ?? load.map(String.init) ?? "–", unit: t == nil ? "%" : "°C", size: 18)
        .foregroundStyle(heated(.text1, s.cpuHeat))
    }
  }

  private var memory: some View {
    VitalRow(symbol: "memorychip", title: "Memory", detail: s.memory.map { "\(gigabytes($0.used)) of \(gigabytes($0.total))" } ?? "–",
             tint: .memTint, page: .memory, model: model) {
      Trace(values: history.pressure, range: 0...100, color: .memTint)
    } value: {
      Big(value: s.pressurePercent.map(String.init) ?? "–", unit: "%", size: 18)
        .foregroundStyle(heated(.text1, s.memoryHeat))
    }
  }

  private var network: some View {
    VitalRow(symbol: "arrow.up.arrow.down", title: "Network", detail: "Wi-Fi and wired", tint: .netTint, page: .network, model: model) {
      ZStack {
        Trace(values: history.down, range: netRange(history), color: .netTint)
        Trace(values: history.up, range: netRange(history), color: .upTint, fill: false)
      }
    } value: {
      VStack(alignment: .trailing, spacing: 1) {
        Rate(symbol: "arrow.down", value: s.network?.down, tint: .netTint)
        Rate(symbol: "arrow.up", value: s.network?.up, tint: .upTint)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        close()
      } label: {
        Label("Activity Monitor", systemImage: "list.bullet.rectangle")
      }
      .buttonStyle(Pill())
      .help("See which apps use the CPU and memory")
      Spacer()
      Button { model.go(.settings) } label: { Image(systemName: "gearshape.fill") }
        .buttonStyle(Pill())
        .help("Settings")
        .accessibilityLabel("Settings")
      Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
        .buttonStyle(Pill())
        .keyboardShortcut("q")
        .help("Quit Vitals (⌘Q)")
        .accessibilityLabel("Quit Vitals")
    }
  }
}

struct BackBar: View {
  let title: String
  @ObservedObject var model: PopupModel

  var body: some View {
    HStack(spacing: 8) {
      Button { model.go(.overview) } label: {
        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
          .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help("Back")
      .accessibilityLabel("Back")
      Text(title).font(.system(size: 15, weight: .semibold))
      Spacer()
    }
  }
}

/// One vital in the overview list: icon, name and detail, a 5-minute trace, the reading. Click for its page.
struct VitalRow<Chart: View, Value: View>: View {
  let symbol: String
  let title: String
  let detail: String
  let tint: Color
  let page: PopupModel.Page
  @ObservedObject var model: PopupModel
  @ViewBuilder var chart: () -> Chart
  @ViewBuilder var value: () -> Value

  var body: some View {
    Button { model.go(page) } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint.opacity(0.85))
          .frame(width: 30, height: 30).background(Circle().fill(tint.opacity(0.1)))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 12.5, weight: .medium))
          Text(detail).font(.system(size: 11)).foregroundStyle(Color.text2).lineLimit(1)
        }
        Spacer(minLength: 6)
        chart().frame(width: 52, height: 22)
        value().fixedSize().frame(minWidth: 66, alignment: .trailing)  // a long rate takes room from the detail, never wraps
      }
      .padding(.horizontal, 8)
      .frame(height: 50)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(model.hovered == page ? 0.06 : 0)))
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)  // VoiceOver reads "CPU, Load 22%, 52 °C"
    }
    .buttonStyle(.plain)
    .onHover { model.hover(page, $0) }
    .help("Details")
    .accessibilityHint("Shows details")
  }
}

struct Pill: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 11)
      .frame(height: 28)
      .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
      .contentShape(Capsule())
  }
}

// MARK: - Details

struct DetailPage: View {
  let s: Sample
  let history: History
  @ObservedObject var model: PopupModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BackBar(title: ["CPU", "Memory", "Network"][[PopupModel.Page.cpu, .memory, .network].firstIndex(of: model.page) ?? 0],
              model: model)
      switch model.page {
      case .cpu: cpu
      case .memory: memory
      default: network
      }
      Spacer(minLength: 0)
    }
  }

  private func hero<G: View>(@ViewBuilder gauge: () -> G, title: String, tint: Color = .text1, note: String) -> some View {
    HStack(spacing: 16) {
      gauge().frame(width: 100, height: 100)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
        Text(note).font(.system(size: 11.5)).foregroundStyle(Color.text2).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  // CPU

  private var thermal: (String, String) {
    switch s.thermal {
    case .nominal: ("Normal", "Full speed, no thermal throttling.")
    case .fair: ("Warm", "Warming up under load, still at full speed.")
    case .serious: ("Hot", "macOS is slowing the CPU to shed heat.")
    case .critical: ("Critical", "Heavily throttled. Give it a break to cool down.")
    @unknown default: ("Unknown", "")
    }
  }

  private var cpu: some View {
    let t = s.temperature
    let load = s.load ?? CPULoad()
    return VStack(spacing: 12) {
      hero(gauge: {
        ZStack {
          Ring(fraction: t.map(MenuBar.heat) ?? load.total, color: heated(t == nil ? .cpuTint : .okTint, s.cpuHeat))
          VStack(spacing: 0) {
            Big(value: t.map { "\(Int($0.rounded()))" } ?? "\(Int((load.total * 100).rounded()))", unit: t == nil ? "%" : "°C", size: 26)
              .foregroundStyle(heated(.text1, s.cpuHeat))
            Text(t == nil ? "load" : "hottest core").font(.system(size: 10)).foregroundStyle(Color.text3)
          }
        }
      }, title: thermal.0, tint: heated(.text1, s.cpuHeat),
         note: thermal.1 + (t == nil ? " Temperature isn't readable on this Mac." : ""))

      if t != nil {
        Tile(title: "Temperature", note: "last 5 min") {
          Trace(values: history.temperature, range: around(history.temperature, minSpan: 10), color: .cpuTint).frame(height: 50)
          HStack {
            Text("low " + (history.temperature.min().map { "\(Int($0.rounded()))°" } ?? "–"))
            Spacer()
            Text("high " + (history.temperature.max().map { "\(Int($0.rounded()))°" } ?? "–"))
          }
          .font(.system(size: 10)).foregroundStyle(Color.text3).monospacedDigit()
        }
      }

      Tile(title: "Load", note: percent(load.total)) {
        StackedBar(parts: [(load.user, .cpuTint), (load.system, .cpuTint.opacity(0.5)), (1 - load.total, .white.opacity(0.08))])
        HStack(spacing: 12) {
          Legend(color: .cpuTint, label: "User", value: percent(load.user))
          Legend(color: .cpuTint.opacity(0.5), label: "System", value: percent(load.system))
          Legend(color: .white.opacity(0.15), label: "Idle", value: percent(1 - load.total))
        }
        Trace(values: history.load, range: 0...100, color: .cpuTint).frame(height: t == nil ? 60 : 34).padding(.top, 2)
      }
    }
  }

  // Memory

  private var memory: some View {
    let m = s.memory ?? Memory(total: 0)
    let p = s.pressurePercent ?? 0
    let (title, note): (String, String) =
      switch s.pressure {
      case .normal: ("Normal", "Room for more apps. macOS isn't squeezing memory.")
      case .warning: ("High", "macOS is compressing and swapping. Quit apps you don't need.")
      case .critical: ("Critical", "Out of memory. Quit apps now to avoid slowdowns.")
      }
    return VStack(spacing: 12) {
      hero(gauge: {
        ZStack {
          Ring(fraction: Double(p) / 100, color: .memTint)  // blue blends to mud on the way to orange; the number carries the heat
          VStack(spacing: 0) {
            Big(value: "\(p)", unit: "%", size: 26).foregroundStyle(heated(.text1, s.memoryHeat))
            Text("pressure").font(.system(size: 10)).foregroundStyle(Color.text3)
          }
        }
      }, title: title, tint: heated(.text1, s.memoryHeat), note: note)

      Tile(title: "\(gigabytes(m.used)) used", note: "of \(gigabytes(m.total))") {
        StackedBar(parts: [(Double(m.app), .memTint), (Double(m.wired), .wiredTint), (Double(m.compressed), .squeezedTint),
                           (Double(m.free), .white.opacity(0.08))])
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
          GridRow {
            Legend(color: .memTint, label: "Apps", value: gigabytes(m.app))
            Legend(color: .wiredTint, label: "Wired", value: gigabytes(m.wired))
          }
          GridRow {
            Legend(color: .squeezedTint, label: "Compressed", value: gigabytes(m.compressed))
            Legend(color: .white.opacity(0.15), label: "Free", value: gigabytes(m.free))
          }
          GridRow {
            Legend(color: .clear, label: "Swap", value: Memory.swapUsed().map(gigabytes) ?? "–")
          }
        }
      }

      Tile(title: "Pressure", note: "last 5 min") {
        Trace(values: history.pressure, range: 0...100, color: .memTint).frame(height: 40)
      }
    }
  }

  // Network

  private var network: some View {
    let n = s.network ?? NetRate()
    return VStack(spacing: 12) {
      HStack(spacing: 10) {
        Tile(title: "Download") {
          Text(speed(n.down)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Color.netTint)
        }
        Tile(title: "Upload") {
          Text(speed(n.up)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Color.upTint)
        }
      }
      Tile(title: "Activity", note: "last 5 min") {
        ZStack {
          Trace(values: history.down, range: netRange(history), color: .netTint)
          Trace(values: history.up, range: netRange(history), color: .upTint, fill: false)
        }
        .frame(height: 96)
        HStack(spacing: 12) {
          Legend(color: .netTint, label: "Peak down", value: speed(history.down.max() ?? 0))
          Legend(color: .upTint, label: "Peak up", value: speed(history.up.max() ?? 0))
        }
      }
      Text("Wi-Fi and wired connections. VPN traffic is counted once, on the connection it travels over.")
        .font(.system(size: 10.5)).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Settings

struct SettingsPage: View {
  @ObservedObject var prefs: Prefs
  @ObservedObject var model: PopupModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      BackBar(title: "Settings", model: model).padding(.bottom, 2)

      Text("Menu bar").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.text2).padding(.leading, 4)
      VStack(spacing: 0) {
        ForEach(Metric.allCases) { metric in
          HStack(spacing: 8) {
            Image(systemName: metric.symbol).font(.system(size: 12)).foregroundStyle(Color.text2).frame(width: 18)
            Text(metric.title).font(.system(size: 12.5)).fixedSize()
            Spacer(minLength: 4)
            Picker(metric.title, selection: Binding { prefs[metric] } set: { prefs[metric] = $0 }) {
              ForEach(Display.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
          }
          .frame(height: 38)
          .padding(.horizontal, 12)
          if metric != Metric.allCases.last { Divider().overlay(Color.white.opacity(0.04)).padding(.leading, 38).padding(.trailing, 12) }
        }
      }
      .background(tileShape())

      Text("General").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.text2).padding(.leading, 4).padding(.top, 4)
      VStack(spacing: 0) {
        HStack {
          Text("Launch at login").font(.system(size: 12.5))
          Spacer()
          Toggle("Launch at login", isOn: $prefs.launchAtLogin).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .frame(height: 38)
        .padding(.horizontal, 12)
        Divider().overlay(Color.white.opacity(0.04)).padding(.horizontal, 12)
        Button { NSApp.terminate(nil) } label: {
          HStack {
            Text("Quit Vitals").font(.system(size: 12.5))
            Spacer()
            Text("⌘Q").font(.system(size: 11)).foregroundStyle(Color.text3)
          }
          .frame(height: 38)
          .padding(.horizontal, 12)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
      }
      .background(tileShape())

      Spacer(minLength: 0)
      Text("Vitals \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · updates every \(Int(Monitor.interval)) s")
        .font(.system(size: 10.5)).foregroundStyle(Color.text3).frame(maxWidth: .infinity)
    }
  }
}

// MARK: - Pieces

struct Big: View {
  let value: String
  let unit: String
  var size: CGFloat = 30

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(unit).font(.system(size: size * 0.5, weight: .medium, design: .rounded)).foregroundStyle(Color.text2)
    }
  }
}

struct Rate: View {
  let symbol: String
  let value: Double?
  let tint: Color

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint)
      Text(value.map(speed) ?? "–").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel((symbol == "arrow.down" ? "Download " : "Upload ") + (value.map(speed) ?? "unknown"))
  }
}

struct Tile<Content: View>: View {
  let title: String
  var note: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.text2)
        Spacer()
        if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Color.text3).monospacedDigit() }
      }
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tileShape())
  }
}

struct Legend: View {
  let color: Color
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(label).foregroundStyle(Color.text2)
      Text(value).monospacedDigit()
    }
    .font(.system(size: 11))
  }
}

/// Live trace, newest on the right, filling in from the right as history builds up.
struct Trace: View {
  let values: [Double]
  let range: ClosedRange<Double>
  let color: Color
  var fill = true

  var body: some View {
    Canvas { ctx, size in
      var floor = Path()
      floor.move(to: CGPoint(x: 0, y: size.height - 0.5))
      floor.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
      ctx.stroke(floor, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      guard values.count > 1 else { return }
      let width = size.width - 3  // room for the end dot
      let step = width / CGFloat(History.length - 1)
      let start = width - step * CGFloat(values.count - 1)
      let span = max(range.upperBound - range.lowerBound, 1e-9)
      let points = values.enumerated().map { i, v in
        CGPoint(x: start + step * CGFloat(i), y: 2 + (size.height - 4) * (1 - CGFloat(min(max((v - range.lowerBound) / span, 0), 1))))
      }
      var line = Path()
      line.addLines(points)
      if fill {
        var area = line
        area.addLine(to: CGPoint(x: width, y: size.height))
        area.addLine(to: CGPoint(x: start, y: size.height))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.3), color.opacity(0)]),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      }
      ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      if let last = points.last {
        ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(color))
      }
    }
  }
}

struct Ring: View {
  let fraction: Double
  let color: Color
  var width: CGFloat = 8

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.08), lineWidth: width)
      Circle()
        .trim(from: 0, to: min(max(fraction, 0.005), 1))
        .stroke(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .bottom, endPoint: .top),
                style: StrokeStyle(lineWidth: width, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
    .padding(width / 2)
  }
}

struct StackedBar: View {
  let parts: [(Double, Color)]

  var body: some View {
    GeometryReader { g in
      let total = max(parts.map(\.0).reduce(0, +), 1e-9)
      let room = g.size.width - 2 * CGFloat(parts.count - 1)
      HStack(spacing: 2) {
        ForEach(parts.indices, id: \.self) { i in
          RoundedRectangle(cornerRadius: 3).fill(parts[i].1).frame(width: max(0, room * max(parts[i].0, 0) / total))
        }
      }
    }
    .frame(height: 8)
  }
}
