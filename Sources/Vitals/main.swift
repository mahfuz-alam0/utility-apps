import AppKit
import Combine

// Menu-bar vitals, e.g. "52° 47%": CPU temperature, memory pressure, and optionally CPU load, battery and network,
// each as a number, a gauge or both. Click for the popup. Orange/red when macOS itself reports thermal throttling,
// memory pressure or a low battery, so the warning follows the system's verdict, not a guessed threshold.

@MainActor
private final class App: NSObject, NSApplicationDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let monitor = Monitor()
  private let prefs = Prefs()
  private lazy var popup = PopupController(monitor: monitor, prefs: prefs)
  // Re-setting an unchanged image still relayouts the status item; that was most of the app's CPU, so skip it.
  private var shown: (parts: [Part], level: Level)?
  private var watch: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
      return NSApp.terminate(nil)
    }
    guard let button = item.button else { return }
    button.target = self
    button.action = #selector(toggle)
    button.sendAction(on: [.leftMouseDown, .rightMouseDown])  // open on press, like a menu
    // after the click's own tracking ends, or the button un-highlights itself on mouse-up
    popup.onVisible = { [weak button] on in DispatchQueue.main.async { button?.highlight(on) } }
    watch = monitor.$sample.combineLatest(prefs.$display).sink { [weak self] in self?.render($0, $1) }
    monitor.start()
  }

  private func render(_ s: Sample, _ display: [Metric: Display]) {
    guard let button = item.button else { return }
    button.toolTip = MenuBar.summary(s)
    let parts = MenuBar.parts(s, display)
    let level = MenuBar.level(s, display)
    guard shown.map({ $0.parts != parts || $0.level != level }) ?? true else { return }
    shown = (parts, level)
    button.image = parts.isEmpty
      ? NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Vitals")  // everything off: still clickable
      : MenuBar.image(parts, level: level)
    button.setAccessibilityLabel("Vitals: " + MenuBar.summary(s))
  }

  @objc private func toggle() {
    if let window = item.button?.window { popup.toggle(below: window) }
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = App()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
