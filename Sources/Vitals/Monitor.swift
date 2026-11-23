import AppKit
import ServiceManagement

/// One reading of every sensor. The menu bar and the popup both draw from it, so nothing is sampled twice.
struct Sample {
  var temperature: Double?
  var load: CPULoad?
  var memory: Memory?
  var pressure = Pressure.normal
  var pressurePercent: Int?
  var thermal = ProcessInfo.ThermalState.nominal
  var network: NetRate?
}

enum Level: Int, Comparable {
  case ok, warning, critical
  static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

extension Sample {
  // Warnings follow macOS's own verdicts (thermal state, memory pressure), not guessed thresholds.
  var thermalLevel: Level { thermal == .critical ? .critical : thermal == .serious ? .warning : .ok }
  var memoryLevel: Level { pressure == .critical ? .critical : pressure == .warning ? .warning : .ok }

  /// Worst problem first (heat, then memory), or all clear.
  var health: (level: Level, headline: String) {
    let problems = [
      (thermalLevel, thermal == .critical ? "Overheating" : "Running hot"),
      (memoryLevel, pressure == .critical ? "Out of memory" : "Memory is tight"),
    ]
    return problems.filter { $0.0 != .ok }.max { $0.0 < $1.0 } ?? (.ok, "All vitals normal")
  }
}

/// Recent readings for the charts, oldest first.
struct History {
  static let length = 150  // 5 minutes at the 2 s refresh
  var temperature: [Double] = [], load: [Double] = [], pressure: [Double] = [], down: [Double] = [], up: [Double] = []

  mutating func record(_ s: Sample) {
    func push(_ list: inout [Double], _ value: Double?) {
      guard let value else { return }
      list.append(value)
      if list.count > Self.length { list.removeFirst(list.count - Self.length) }
    }
    push(&temperature, s.temperature)
    push(&load, s.load.map { $0.total * 100 })
    push(&pressure, s.pressurePercent.map(Double.init))
    push(&down, s.network?.down)
    push(&up, s.network?.up)
  }
}

@MainActor
final class Monitor: ObservableObject {
  static let interval = 2.0
  @Published var sample = Sample()
  var history = History()  // updated just before `sample`, so its change notification covers both
  private let thermometer = Thermometer()
  private let cpu = CPUMeter()
  private let net = NetMeter()
  private var timer: Timer?
  /// Why sampling is paused: the Mac asleep, its displays off, or another user's session in front. Empty = running.
  private var holds = Set<Notification.Name>()

  func start() {
    // Nobody sees the menu bar then, so stop sampling until it's back. Logging out quits the app anyway.
    let center = NSWorkspace.shared.notificationCenter
    for (stop, go) in [(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                       (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                       (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
      center.addObserver(forName: stop, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.hold(stop, true) } }
      center.addObserver(forName: go, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.hold(stop, false) } }
    }
    run()
  }

  private func hold(_ reason: Notification.Name, _ on: Bool) {
    if on { holds.insert(reason) } else { holds.remove(reason) }
    if !holds.isEmpty {
      timer?.invalidate()
      timer = nil
    } else if timer == nil {
      history = History()  // the charts read "last 5 min": don't join them across the gap
      run()
    }
  }

  private func run() {
    refresh()
    // .common mode keeps the numbers live while a control in the popup is being tracked
    let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func refresh() {
    var s = Sample()
    s.temperature = thermometer?.read()
    s.load = cpu.read()
    s.memory = Memory.current()
    s.pressure = Pressure.current()
    s.pressurePercent = Pressure.percent()
    s.thermal = ProcessInfo.processInfo.thermalState
    s.network = net.read()
    history.record(s)
    sample = s
  }
}

// MARK: - Menu-bar preferences

enum Metric: String, CaseIterable, Identifiable {
  case temperature, load, memory, network
  var id: Self { self }
  var title: String {
    switch self {
    case .temperature: "CPU temp"
    case .load: "CPU load"
    case .memory: "Memory"
    case .network: "Network"
    }
  }
  var symbol: String {
    switch self {
    case .temperature: "thermometer.medium"
    case .load: "cpu"
    case .memory: "memorychip"
    case .network: "arrow.up.arrow.down"
    }
  }
}

enum Display: Int, CaseIterable, Identifiable {
  case off, value, gauge, both
  var id: Self { self }
  var title: String { ["Off", "Value", "Gauge", "Both"][rawValue] }
  var showsValue: Bool { self == .value || self == .both }
  var showsGauge: Bool { self == .gauge || self == .both }
}

/// Persisted in UserDefaults. Plain @Published + didSet: the Command Line Tools SDK can't expand SwiftUI's macros.
@MainActor
final class Prefs: ObservableObject {
  static let standard: [Metric: Display] = [.temperature: .value, .load: .gauge, .memory: .gauge]  // "52°", load and memory bars under it
  private let store: UserDefaults

  @Published var display: [Metric: Display] {
    didSet { store.set(Dictionary(uniqueKeysWithValues: display.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "display") }
  }
  @Published var launchAtLogin: Bool {
    didSet {
      guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
      do {
        if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        NSLog("launch at login failed: \(error)")
        launchAtLogin = SMAppService.mainApp.status == .enabled
      }
    }
  }

  init(store: UserDefaults = .standard) {
    self.store = store
    let saved = store.dictionary(forKey: "display") as? [String: Int]
    display = Dictionary(uniqueKeysWithValues: Metric.allCases.map { m in
      (m, saved.map { $0[m.rawValue].flatMap(Display.init) ?? .off } ?? Prefs.standard[m] ?? .off)
    })
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  subscript(metric: Metric) -> Display {
    get { display[metric] ?? .off }
    set { display[metric] = newValue }
  }
}

// MARK: - Formatting shared by the menu bar and the popup

/// Decimal units, like Activity Monitor.
func speed(_ bytesPerSecond: Double) -> String {
  let kb = max(bytesPerSecond, 0) / 1000
  switch kb {
  case ..<999.5: return "\(Int(kb.rounded())) KB/s"
  case ..<99_950: return String(format: "%.1f MB/s", kb / 1000)
  case ..<999_500: return "\(Int((kb / 1000).rounded())) MB/s"
  default: return String(format: "%.1f GB/s", kb / 1_000_000)
  }
}

func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

func uptime(since boot: Date, now: Date = Date()) -> String {
  let minutes = max(0, Int(now.timeIntervalSince(boot) / 60))
  let (d, h, m) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
  return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
