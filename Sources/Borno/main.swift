import Carbon
import InputMethodKit

/// Copies this app into ~/Library/Input Methods, registers it, tells the user what to do next.
func selfInstall() {
  let fm = FileManager.default
  let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
  let dest = dir.appendingPathComponent("Borno.app")
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  app.activate(ignoringOtherApps: true)

  let alert = NSAlert()
  do {
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
      .filter { $0.processIdentifier != getpid() }.forEach { $0.terminate() }  // old installed copy
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.removeItem(at: dest)
    try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
    let p = Process()
    p.executableURL = dest.appendingPathComponent("Contents/MacOS/Borno")
    p.arguments = ["--register"]
    try p.run()
    p.waitUntilExit()
    alert.messageText = "Borno is installed"
    alert.informativeText = "Add it once: System Settings > Keyboard > Text Input > Input Sources > + > Bangla > Borno. Then pick Borno from the input menu in the menu bar to type Bangla. If it is not listed, log out and in."
    alert.addButton(withTitle: "Open Keyboard Settings")
    alert.addButton(withTitle: "Done")
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
  } catch {
    alert.messageText = "Could not install Borno"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }
}

// `Borno --register` (used by bundle.sh install): tell macOS about the input source and enable it,
// so it shows up in System Settings > Keyboard > Input Sources without logging out.
if CommandLine.arguments.contains("--register") {
  let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
  let match = [kTISPropertyBundleID: Bundle.main.bundleIdentifier!] as CFDictionary
  let sources = TISCreateInputSourceList(match, true)?.takeRetainedValue() as? [TISInputSource] ?? []
  sources.forEach { TISEnableInputSource($0) }
  print("register status \(status), enabled \(sources.count) input source(s)")
  exit(status == noErr ? 0 : 1)
}

// Opened by hand (e.g. from the DMG) instead of by macOS: install into ~/Library/Input Methods.
if Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent != "Input Methods" {
  selfInstall()
  exit(0)
}

let server = IMKServer(
  name: Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
  bundleIdentifier: Bundle.main.bundleIdentifier)
Lexicon.shared.loadBundled()
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
  Lexicon.shared.flush()
}
NSApplication.shared.run()
