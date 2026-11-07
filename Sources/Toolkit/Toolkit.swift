import SwiftUI

/// Launcher for the apps embedded in Contents/Helpers. Each keeps its own bundle id, so this and a standalone install
/// of the same app are one and the same to macOS.
struct Tool: Identifiable {
  let name, blurb, file, bundleID: String
  var isInputMethod = false
  var id: String { file }
  var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(file).app") }
}

let tools = [
  Tool(name: "Clipboard Manager", blurb: "Clipboard history and emoji picker. Press ⌃⇧V.", file: "ClipboardManager", bundleID: "com.local.ClipboardManager"),
  Tool(name: "Prompter", blurb: "On-screen script prompter for calls and recordings.", file: "Prompter", bundleID: "local.prompter.overlay"),
  Tool(name: "Adwall", blurb: "System-wide ad and tracker blocker.", file: "Adwall", bundleID: "com.adwall.app"),
  Tool(name: "Borno", blurb: "Bangla phonetic keyboard. Installs as a macOS input method.", file: "Borno",
       bundleID: "com.mahfuz.inputmethod.Borno", isInputMethod: true),
]

final class Delegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main struct ToolkitApp: App {
  @NSApplicationDelegateAdaptor(Delegate.self) var delegate
  var body: some Scene {
    Window("Toolkit", id: "main") { ToolList() }.windowResizability(.contentSize)
  }
}

struct ToolList: View {
  @State private var running = Set<String>()
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 0) {
      ForEach(tools) { tool in
        let isRunning = running.contains(tool.bundleID) && !tool.isInputMethod
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(tool.name).font(.headline)
            Text(tool.blurb).font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
          Button(tool.isInputMethod ? "Install" : isRunning ? "Quit" : "Open") {
            if isRunning {
              NSRunningApplication.runningApplications(withBundleIdentifier: tool.bundleID).forEach { $0.terminate() }
            } else {
              NSWorkspace.shared.openApplication(at: tool.url, configuration: .init())
            }
          }
          .frame(width: 70)
          .disabled(!FileManager.default.fileExists(atPath: tool.url.path))
        }
        .padding(14)
        if tool.id != tools.last?.id { Divider() }
      }
    }
    .frame(width: 460)
    .onAppear(perform: refresh)
    .onReceive(tick) { _ in refresh() }
  }

  private func refresh() { running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
}
