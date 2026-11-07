import Carbon
import InputMethodKit

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

let server = IMKServer(
  name: Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
  bundleIdentifier: Bundle.main.bundleIdentifier)
Lexicon.shared.loadBundled()
NSApplication.shared.run()
