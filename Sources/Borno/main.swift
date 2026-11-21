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
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    // Update in place: deleting the bundle makes macOS drop Borno from the enabled input sources,
    // and only the user can add it back (System Settings consent).
    let copy = Process()
    copy.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
    copy.arguments = ["-a", "--delete", Bundle.main.bundleURL.path + "/", dest.path + "/"]
    try copy.run()
    copy.waitUntilExit()
    guard copy.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    let p = Process()
    p.executableURL = dest.appendingPathComponent("Contents/MacOS/Borno")
    p.arguments = ["--register"]
    try p.run()
    p.waitUntilExit()
    // macOS may start any registered copy with this bundle ID as the input method. A copy outside
    // Input Methods only runs this installer and quits, so Bangla never appears: remove this copy
    // (fails quietly on the read-only DMG) and drop it from Launch Services.
    try? fm.removeItem(at: Bundle.main.bundleURL)
    let lsregister = Process()
    lsregister.executableURL = URL(fileURLWithPath:
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    lsregister.arguments = ["-u", Bundle.main.bundleURL.path]
    try? lsregister.run()
    lsregister.waitUntilExit()
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
  LSRegisterURL(Bundle.main.bundleURL as CFURL, true)   // this copy wins over older ones with the same bundle ID
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
_ = Lexicon.shared   // loads the dictionary now, not on the first key
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
  Lexicon.shared.save()
}
NSApplication.shared.run()
