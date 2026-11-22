import AppKit
import SwiftUI

// MARK: - Window

/// Borderless and key, but non-activating: the app you were in stays frontmost. A click elsewhere or Esc closes it.
final class Panel: NSPanel {
  var onResign: (() -> Void)?
  var onEscape: (() -> Void)?

  init() {
    super.init(contentRect: NSRect(origin: .zero, size: PopupController.size), styleMask: [.borderless, .nonactivatingPanel],
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
  enum Page: Hashable { case overview, cpu, memory, battery, network, settings }
  @Published var page = Page.overview
  @Published var hovered: Page?
  @Published var shown = false
  var health: Battery.Health?  // read when the battery page opens
  let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"

  func go(_ page: Page) {
    if page == .battery { health = Battery.health() }
    withAnimation(.snappy(duration: 0.28)) { self.page = page }
  }

  func hover(_ page: Page, _ inside: Bool) {
    if inside { hovered = page } else if hovered == page { hovered = nil }
  }
}

@MainActor
final class PopupController {
  static let size = NSSize(width: 340, height: 452)
  static let radius: CGFloat = 16
  private static let mask = NSImage(size: size, flipped: false) { rect in
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    return true
  }
  private let panel = Panel()
  private let model = PopupModel()
  private let monitor: Monitor
  private let prefs: Prefs
  private var closedAt = Date.distantPast
  var onVisible: ((Bool) -> Void)?

  init(monitor: Monitor, prefs: Prefs) {
    self.monitor = monitor
    self.prefs = prefs
    panel.onResign = { [weak self] in self?.hide() }
    panel.onEscape = { [weak self] in
      guard let self else { return }
      if model.page == .overview { hide() } else { model.go(.overview) }
    }
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
    let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.maskImage = Self.mask
    let host = NSHostingView(rootView: PopupView(monitor: monitor, prefs: prefs, model: model) { [weak self] in self?.hide() })
    host.frame = blur.bounds
    host.autoresizingMask = [.width, .height]
    blur.addSubview(host)
    panel.contentView = blur

    // centred under the status item, kept on its screen
    let screen = (anchor.screen ?? NSScreen.main)?.visibleFrame ?? anchor.frame
    let x = min(max(anchor.frame.midX - Self.size.width / 2, screen.minX + 8), screen.maxX - Self.size.width - 8)
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: anchor.frame.minY - Self.size.height - 6), size: Self.size), display: true)
    panel.makeKeyAndOrderFront(nil)
    panel.invalidateShadow()
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
  static let batTint = Color(red: 0.36, green: 0.88, blue: 0.55)
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
    case .ok: .batTint
    case .warning: Color(red: 1.0, green: 0.68, blue: 0.26)
    case .critical: Color(red: 1.0, green: 0.38, blue: 0.38)
    }
  }
}

/// Cool green, warm amber, hot coral; macOS's own throttling verdict overrides.
func heatColor(_ celsius: Double, _ level: Level) -> Color {
  level != .ok ? level.color : celsius >= 90 ? .cpuTint : celsius >= 70 ? .netTint : .batTint
}

private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

/// Range that fits the values with some air, so a flat line sits mid-chart instead of on the floor.
private func around(_ values: [Double], minSpan: Double) -> ClosedRange<Double> {
  guard let lo = values.min(), let hi = values.max() else { return 0...1 }
  let mid = (lo + hi) / 2, half = max(hi - lo, minSpan) / 2 * 1.2
  return (mid - half)...(mid + half)
}

private func netRange(_ h: History) -> ClosedRange<Double> { 0...max(((h.down + h.up).max() ?? 0) * 1.15, 20_000) }

private func tileShape(_ lit: Bool = false) -> some View {
  RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(lit ? 0.09 : 0.055))
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
      LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.17), Color(red: 0.05, green: 0.06, blue: 0.08)],
                     startPoint: .top, endPoint: .bottom).opacity(0.9)
      // the ambient light takes the colour of the overall verdict
      RadialGradient(colors: [s.health.level.color.opacity(0.2), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
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
      .padding(14)
    }
    .frame(width: PopupController.size.width, height: PopupController.size.height)
    .clipShape(RoundedRectangle(cornerRadius: PopupController.radius))
    .overlay(RoundedRectangle(cornerRadius: PopupController.radius).strokeBorder(Color.white.opacity(0.1)))
    .foregroundStyle(Color.text1)
    .environment(\.colorScheme, .dark)
    .scaleEffect(model.shown ? 1 : 0.97, anchor: .top)
    .opacity(model.shown ? 1 : 0)
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
    VStack(spacing: 12) {
      header
      VStack(spacing: 10) {
        HStack(spacing: 10) { cpu; memory }
        HStack(spacing: 10) {
          if s.battery != nil { battery }
          network
        }
      }
      Spacer(minLength: 0)
      footer
    }
  }

  private var header: some View {
    let health = s.health
    return HStack(spacing: 12) {
      ZStack {
        Circle().fill(health.level.color.opacity(0.15))
        Circle().strokeBorder(health.level.color.opacity(0.35), lineWidth: 1)
        Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .semibold)).foregroundStyle(health.level.color)
      }
      .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(health.headline).font(.system(size: 16, weight: .semibold))
        Text([model.chip, bootDate.map { "up " + uptime(since: $0) }].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 11)).foregroundStyle(Color.text2)
      }
      Spacer()
    }
    .padding(.top, 2)
  }

  private var cpu: some View {
    Card(title: "CPU", symbol: "cpu", tint: .cpuTint, page: .cpu, model: model) {
      if let t = s.temperature {
        Big(value: "\(Int(t.rounded()))", unit: "°C")
      } else {
        Big(value: s.load.map { "\(Int(($0.total * 100).rounded()))" } ?? "–", unit: "%")
      }
      Text(s.temperature == nil ? "Load" : "Load " + (s.load.map { percent($0.total) } ?? "–"))
        .font(.system(size: 11)).foregroundStyle(Color.text2)
      let trace = s.temperature == nil ? history.load : history.temperature
      Trace(values: trace, range: s.temperature == nil ? 0...100 : around(trace, minSpan: 10), color: .cpuTint)
        .frame(height: 34).padding(.top, 10)
    }
  }

  private var memory: some View {
    Card(title: "Memory", symbol: "memorychip", tint: .memTint, page: .memory, model: model) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Big(value: s.pressurePercent.map(String.init) ?? "–", unit: "%")
        Text("pressure").font(.system(size: 10.5)).foregroundStyle(Color.text3)
      }
      Text(s.memory.map { "\(gigabytes($0.used)) of \(gigabytes($0.total))" } ?? "–")
        .font(.system(size: 11)).foregroundStyle(Color.text2)
      Trace(values: history.pressure, range: 0...100, color: s.memoryLevel == .ok ? .memTint : s.memoryLevel.color)
        .frame(height: 34).padding(.top, 10)
    }
  }

  private var battery: some View {
    let b = s.battery ?? Battery(percent: 0)
    return Card(title: "Battery", symbol: b.plugged ? "powerplug.fill" : "battery.75percent", tint: .batTint, page: .battery, model: model) {
      Big(value: "\(b.percent)", unit: "%")
      Text(b.status).font(.system(size: 11)).foregroundStyle(Color.text2).lineLimit(1)
      BatteryGlyph(fraction: Double(b.percent) / 100, symbol: b.powerSymbol, color: s.batteryLevel == .ok ? .batTint : s.batteryLevel.color)
        .frame(height: 18).padding(.top, 20)
    }
  }

  private var network: some View {
    Card(title: "Network", symbol: "arrow.up.arrow.down", tint: .netTint, page: .network, model: model) {
      VStack(alignment: .leading, spacing: 2) {
        Rate(symbol: "arrow.down", value: s.network?.down, tint: .netTint)
        Rate(symbol: "arrow.up", value: s.network?.up, tint: .upTint)
      }
      ZStack {
        Trace(values: history.down, range: netRange(history), color: .netTint)
        Trace(values: history.up, range: netRange(history), color: .upTint, fill: false)
      }
      .frame(height: 34).padding(.top, 10)
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

struct Card<Content: View>: View {
  let title: String
  let symbol: String
  let tint: Color
  let page: PopupModel.Page
  @ObservedObject var model: PopupModel
  @ViewBuilder var content: () -> Content

  var body: some View {
    let lit = model.hovered == page
    Button { model.go(page) } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 5) {
          Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
          Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.text2)
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.text3)
            .opacity(lit ? 1 : 0)
        }
        Spacer(minLength: 6)
        content()
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 150)
      .background(tileShape(lit))
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)  // VoiceOver reads "CPU, 52 °C, Load 22%"
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
      BackBar(title: ["CPU", "Memory", "Battery", "Network"][[PopupModel.Page.cpu, .memory, .battery, .network].firstIndex(of: model.page) ?? 0],
              model: model)
      switch model.page {
      case .cpu: cpu
      case .memory: memory
      case .battery: battery
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
          Ring(fraction: t.map(MenuBar.heat) ?? load.total, color: t.map { heatColor($0, s.thermalLevel) } ?? .cpuTint)
          VStack(spacing: 0) {
            Big(value: t.map { "\(Int($0.rounded()))" } ?? "\(Int((load.total * 100).rounded()))", unit: t == nil ? "%" : "°C", size: 26)
            Text(t == nil ? "load" : "hottest core").font(.system(size: 10)).foregroundStyle(Color.text3)
          }
        }
      }, title: thermal.0, tint: s.thermalLevel == .ok ? .text1 : s.thermalLevel.color,
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
          Ring(fraction: Double(p) / 100, color: s.memoryLevel == .ok ? .memTint : s.memoryLevel.color)
          VStack(spacing: 0) {
            Big(value: "\(p)", unit: "%", size: 26)
            Text("pressure").font(.system(size: 10)).foregroundStyle(Color.text3)
          }
        }
      }, title: title, tint: s.memoryLevel == .ok ? .text1 : s.memoryLevel.color, note: note)

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

  // Battery

  private var battery: some View {
    let b = s.battery ?? Battery(percent: 0)
    let health = model.health
    return VStack(spacing: 12) {
      hero(gauge: {
        VStack(spacing: 10) {
          BatteryGlyph(fraction: Double(b.percent) / 100, symbol: b.powerSymbol, color: s.batteryLevel == .ok ? .batTint : s.batteryLevel.color)
            .frame(width: 88, height: 40)
          Big(value: "\(b.percent)", unit: "%", size: 24)
        }
      }, title: b.title, note: b.note)

      Tile {
        Row(label: "Power source", value: b.plugged ? "Power adapter" : "Battery")
        Row(label: "Health", value: health?.percent.map { "\($0)%" } ?? "–")
        Row(label: "Charge cycles", value: health?.cycles.map(String.init) ?? "–")
        Row(label: "Full charge", value: health.flatMap { h in h.capacity.map { "\($0) of \(h.design.map(String.init) ?? "–") mAh" } } ?? "–")
        Text(healthNote(health?.percent)).font(.system(size: 11)).foregroundStyle(Color.text2)
          .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
      }
    }
  }

  private func healthNote(_ p: Int?) -> String {
    guard let p else { return "This Mac doesn't report battery wear." }
    return p >= 80
      ? "Good condition: holds \(p)% of the charge it held when new."
      : "Worn: holds \(p)% of its original charge. Consider a battery service."
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

extension Battery {
  /// Short line for the overview card.
  var status: String {
    if charged { return "Fully charged" }
    if charging { return minutes.map { "\(duration(minutes: $0)) to full" } ?? "Charging" }
    if plugged { return "Not charging" }
    return minutes.map { "\(duration(minutes: $0)) left" } ?? "On battery"
  }

  /// Bolt while charging, plug while on the adapter but holding.
  var powerSymbol: String? { charging ? "bolt.fill" : plugged ? "powerplug.fill" : nil }

  var title: String { charged ? "Fully charged" : charging ? "Charging" : plugged ? "Not charging" : "On battery" }

  var note: String {
    if charged { return "Running from the power adapter." }
    if charging { return minutes.map { "\(duration(minutes: $0)) until full." } ?? "Estimating time until full…" }
    if plugged { return "On the power adapter. macOS is holding the charge, usually to protect the battery." }
    return minutes.map { "About \(duration(minutes: $0)) remaining." } ?? "Estimating time remaining…"
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
            Text(metric.title).font(.system(size: 12.5))
            Spacer(minLength: 4)
            Segments(value: prefs[metric]) { prefs[metric] = $0 }
          }
          .frame(height: 38)
          .padding(.horizontal, 10)
          if metric != Metric.allCases.last { Divider().overlay(Color.white.opacity(0.04)).padding(.leading, 36) }
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
        Divider().overlay(Color.white.opacity(0.04)).padding(.leading, 12)
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

struct Segments: View {
  let value: Display
  let set: (Display) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Display.allCases) { option in
        Button { withAnimation(.snappy(duration: 0.18)) { set(option) } } label: {
          Text(option.title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(option == value ? Color.text1 : Color.text2)
            .frame(width: 40, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(option == value ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
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
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
      Text(value.map(speed) ?? "–").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel((symbol == "arrow.down" ? "Download " : "Upload ") + (value.map(speed) ?? "unknown"))
  }
}

struct Tile<Content: View>: View {
  var title: String?
  var note: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        HStack {
          Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.text2)
          Spacer()
          if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Color.text3).monospacedDigit() }
        }
      }
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tileShape())
  }
}

struct Row: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label).foregroundStyle(Color.text2)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.system(size: 12))
    .frame(height: 22)
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

struct BatteryGlyph: View {
  let fraction: Double
  let symbol: String?
  let color: Color

  var body: some View {
    GeometryReader { g in
      let h = g.size.height
      let nub = max(2, h * 0.1)
      let shell = g.size.width - nub - 2
      let inset = max(2, h * 0.1)
      let radius = h * 0.28
      HStack(spacing: 2) {
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: max(1, h * 0.05))
          RoundedRectangle(cornerRadius: max(radius - inset, 1.5), style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(0, (shell - inset * 2) * min(max(fraction, 0), 1)))
            .padding(inset)
          if let symbol {
            Image(systemName: symbol).font(.system(size: h * 0.55, weight: .heavy)).foregroundStyle(.white)
              .shadow(color: .black.opacity(0.35), radius: 1).frame(maxWidth: .infinity)
          }
        }
        .frame(width: shell)
        RoundedRectangle(cornerRadius: nub / 2).fill(Color.white.opacity(0.3)).frame(width: nub, height: h * 0.36)
      }
    }
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
