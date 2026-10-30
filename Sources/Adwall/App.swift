import AppKit
import ServiceManagement

private let refreshInterval = 3.0

/// Menu item that runs a closure when clicked.
private final class ActionItem: NSMenuItem {
  private var handler: (() -> Void)?

  convenience init(_ title: String, enabled: Bool = true, action: (() -> Void)? = nil) {
    self.init(title: title, action: action == nil ? nil : #selector(fire), keyEquivalent: "")
    handler = action
    target = self
    isEnabled = enabled && action != nil
  }

  @objc private func fire() { handler?() }
}

private func number(_ value: Int) -> String {
  value.formatted(.number.locale(Locale(identifier: "en_US")))
}

private func alert(_ style: NSAlert.Style, _ message: String, _ detail: String, ok: String, cancel: String? = nil, defaultCancel: Bool = false) -> Bool {
  NSApp.activate(ignoringOtherApps: true)
  let alert = NSAlert()
  alert.alertStyle = style
  alert.messageText = message
  alert.informativeText = detail
  alert.addButton(withTitle: ok)
  if let cancel { alert.addButton(withTitle: cancel) }
  if defaultCancel { alert.buttons.first?.keyEquivalent = ""; alert.buttons.last?.keyEquivalent = "\r" }
  return alert.runModal() == .alertFirstButtonReturn
}

/// Runs `Adwall <command>` as root through the macOS administrator prompt. Throws "cancelled" if dismissed.
private func runAsAdmin(_ command: String) throws {
  let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Adwall").path
  let shell = "\(shellQuote(daemon)) \(command)"
  let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  do {
    try runProcess("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
  } catch {
    let message = error.localizedDescription
    if message.contains("(-128)") { throw AdwallError("cancelled") }
    throw AdwallError(message.components(separatedBy: "execution error: ").last ?? message)
  }
}

@MainActor
private final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var status: Status?
  private var busy = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
      return NSApp.terminate(nil)
    }
    let icon = NSImage(named: "trayTemplate")
    icon?.isTemplate = true
    item.button?.image = icon
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    item.menu = menu
    refresh()
    Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
  }

  // MARK: daemon

  private func refresh() {
    guard !busy else { return }
    send("status")
  }

  private func send(_ command: String) {
    Task.detached {
      let status = try? Control.send(command)
      await MainActor.run {
        if status != nil || command == "status" { self.status = status }
        self.item.button?.toolTip = self.tooltip
      }
    }
  }

  private var tooltip: String {
    guard let status else { return "Adwall: protection off" }
    return status.enabled ? "Adwall: protection on" : "Adwall: paused"
  }

  private var installed: Bool { FileManager.default.fileExists(atPath: Paths.plist) }

  private func changeProtection(_ command: String) {
    busy = true
    Task.detached {
      let failure: String? = {
        do { try runAsAdmin(command); return nil } catch { return error.localizedDescription }
      }()
      await MainActor.run {
        self.busy = false
        if let failure, failure != "cancelled" { _ = alert(.critical, "Adwall", failure, ok: "OK") }
        self.send("status")
      }
    }
  }

  private func turnOn() {
    let go = alert(
      .informational, "Turn on system-wide blocking?",
      "Adwall starts a local filtering DNS service and points this Mac at it, so ads and trackers are blocked in every app. macOS will ask for your password.",
      ok: "Turn On", cancel: "Cancel")
    if go { changeProtection("install") }
  }

  private func turnOff() {
    let go = alert(
      .warning, "Turn off protection?", "Your original DNS settings will be restored and the blocking service removed.",
      ok: "Turn Off", cancel: "Cancel", defaultCancel: true)
    if go { changeProtection("uninstall") }
  }

  private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled { try service.unregister() } else { try service.register() }
    } catch {
      _ = alert(.warning, "Launch at Login", error.localizedDescription, ok: "OK")
    }
  }

  private func open(_ file: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: "\(Paths.rulesDir)/\(file)"))
  }

  // MARK: menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    refresh()

    if let status {
      let stats = status.stats
      let percent = stats.total > 0 ? String(format: "%.1f", Double(stats.blocked) / Double(stats.total) * 100) : "0.0"
      let recent = NSMenu()
      recent.autoenablesItems = false
      if status.recent.isEmpty {
        recent.addItem(ActionItem("Nothing blocked yet"))
      } else {
        recent.addItem(ActionItem("Click a domain to allow it"))
        recent.addItem(.separator())
        for domain in status.recent { recent.addItem(ActionItem(domain) { self.send("allow \(domain)") }) }
      }
      let recentItem = NSMenuItem(title: "Recently Blocked", action: nil, keyEquivalent: "")
      recentItem.submenu = recent

      menu.addItem(ActionItem(status.enabled ? "Protection is on" : "Blocking is paused"))
      menu.addItem(ActionItem("Blocked \(number(stats.blocked)) of \(number(stats.total)) requests (\(percent)%)"))
      menu.addItem(ActionItem("\(number(status.ruleCount)) domains in blocklists"))
      menu.addItem(.separator())
      menu.addItem(
        status.enabled
          ? ActionItem("Pause Blocking") { self.send("pause") }
          : ActionItem("Resume Blocking") { self.send("resume") })
      menu.addItem(recentItem)
      menu.addItem(.separator())
      menu.addItem(
        ActionItem(status.updating ? "Updating Blocklists…" : "Update Blocklists", enabled: !status.updating) { self.send("update") })
      menu.addItem(ActionItem("Edit Allowlist…") { self.open("allowlist.txt") })
      menu.addItem(ActionItem("Edit Custom Blocklist…") { self.open("blocklist.txt") })
    } else {
      menu.addItem(ActionItem(installed ? "Blocking service is not running" : "Protection is off"))
      menu.addItem(ActionItem("Turn On Protection…", enabled: !busy) { self.turnOn() })
    }

    menu.addItem(.separator())
    let login = ActionItem("Launch at Login") { self.toggleLaunchAtLogin() }
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    if installed { menu.addItem(ActionItem("Turn Off Protection…", enabled: !busy) { self.turnOff() }) }
    menu.addItem(ActionItem("Quit Adwall") { NSApp.terminate(nil) })
  }
}

func runApp() {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}
