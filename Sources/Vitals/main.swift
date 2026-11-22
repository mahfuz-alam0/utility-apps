import AppKit
import ServiceManagement

// Menu-bar text "52° 61%": hottest CPU die temperature, memory used. Orange/red when macOS itself reports
// thermal throttling or memory pressure, so the warning follows the system's verdict, not a guessed threshold.

private let refreshInterval = 2.0

@MainActor
private final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let thermometer = Thermometer()
  private let tempLine = NSMenuItem()
  private let thermalLine = NSMenuItem()
  private let memoryLine = NSMenuItem()
  private let pressureLine = NSMenuItem()
  private let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
  // Re-setting an unchanged title still relayouts the status item; that was most of the app's CPU, so skip it.
  private var shown: (title: String, alert: NSColor?) = ("", nil)
  private var menuOpen = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
      return NSApp.terminate(nil)
    }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    for line in [tempLine, thermalLine, memoryLine, pressureLine] {
      line.isEnabled = false
      menu.addItem(line)
    }
    menu.addItem(.separator())
    let activity = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
    for action in [activity, login] {
      action.target = self
      menu.addItem(action)
    }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu
    item.button?.font = .monospacedDigitSystemFont(ofSize: item.button?.font?.pointSize ?? 13, weight: .regular)

    refresh()
    // .common mode keeps the numbers live while the menu is open
    let timer = Timer(timeInterval: refreshInterval, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
  }

  private func refresh() {
    let temp = thermometer?.read()
    let memory = Memory.current()
    let pressure = Pressure.current()
    let thermal = ProcessInfo.processInfo.thermalState

    let tempText = temp.map { "\(Int($0.rounded()))°" }
    let memoryText = memory.map { "\($0.percent)%" }
    let title = [tempText, memoryText].compactMap { $0 }.joined(separator: " ")
    let alert: NSColor? =
      thermal == .critical || pressure == .critical ? .systemRed
      : thermal == .serious || pressure == .warning ? .systemOrange : nil
    if let button = item.button, title != shown.title || alert != shown.alert {
      shown = (title, alert)
      // plain title in the normal case so the system picks the menu-bar text colour (light/dark/tinted)
      if let alert, let font = button.font {
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: alert])
      } else {
        button.title = title
      }
      button.toolTip = "CPU \(tempText ?? "n/a") · Memory \(memoryText ?? "n/a") used"
    }

    guard menuOpen else { return }
    tempLine.title = "CPU temperature: " + (temp.map { "\(Int($0.rounded())) °C" } ?? "not available on this Mac")
    thermalLine.title = "Thermal state: " + describe(thermal)
    memoryLine.title = memory.map { "Memory: \(gigabytes($0.used)) of \(gigabytes($0.total)) GB used (\($0.percent)%)" } ?? "Memory: n/a"
    pressureLine.title = "Memory pressure: " + ["Normal", "High, close some apps", "Critical, close apps now"][pressure == .normal ? 0 : pressure == .warning ? 1 : 2]
  }

  private func describe(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "Normal"
    case .fair: "Warm"
    case .serious: "Hot, CPU is being slowed down"
    case .critical: "Critical, let it cool down"
    @unknown default: "Unknown"
    }
  }

  private func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    refresh()
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
  }

  func menuDidClose(_ menu: NSMenu) { menuOpen = false }

  @objc private func openActivityMonitor() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
  }

  @objc private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled { try service.unregister() } else { try service.register() }
    } catch {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "Launch at Login"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = App()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
