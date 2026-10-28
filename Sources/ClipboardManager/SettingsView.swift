import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Click the shortcut button, press a combo (needs ⌘, ⌥ or ⌃). Esc cancels.
final class ShortcutRecorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func toggle(_ settings: Settings) { recording ? stop() : start(settings) }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func start(_ settings: Settings) {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if Int(e.keyCode) == kVK_Escape { self?.stop(); return nil }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !f.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }

            var mods = 0, label = ""
            if f.contains(.control) { mods |= controlKey; label += "⌃" }
            if f.contains(.option) { mods |= optionKey; label += "⌥" }
            if f.contains(.shift) { mods |= shiftKey; label += "⇧" }
            if f.contains(.command) { mods |= cmdKey; label += "⌘" }
            let ch = e.charactersIgnoringModifiers?.uppercased() ?? ""
            label += ch.count == 1 && ch.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 0xF700 }) ? ch
                : Int(e.keyCode) == kVK_Space ? "Space" : "Key \(e.keyCode)"
            settings.hotKey = HotKeySpec(code: Int(e.keyCode), mods: mods, label: label)
            self?.stop()
            return nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: ClipStore
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Picker("Open popup at", selection: $settings.openAtCaret) {
                    Text("Text cursor").tag(true)
                    Text("Mouse pointer").tag(false)
                }
                LabeledContent("Shortcut") {
                    HStack {
                        Button(recorder.recording ? "Press shortcut…" : settings.hotKey.label) { recorder.toggle(settings) }
                        Button("Reset") { settings.hotKey = .standard }.disabled(settings.hotKey == .standard)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show timestamps", isOn: $settings.showTimestamps)
            }

            Section {
                LabeledContent("Maximum items") {
                    HStack {
                        TextField("", value: $settings.maxItems, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 56)
                        Stepper("", value: $settings.maxItems, in: 1...500).labelsHidden()
                    }
                }
                Toggle("Keep history after quitting", isOn: $settings.persistHistory)
                Toggle("Record text", isOn: $settings.recordText)
                Toggle("Record images", isOn: $settings.recordImages)
                Toggle("Pause recording", isOn: $settings.paused)
                Button("Clear History (\(store.items.filter { !$0.pinned }.count) items)", role: .destructive) { store.clear() }
            } header: {
                Text("History")
            } footer: {
                Text("Pinned items don't count toward the limit and survive Clear.")
            }

            Section("Privacy") {
                Toggle("Ignore password-manager content", isOn: $settings.ignoreSecrets)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
    }
}

final class SettingsWindow {
    private var window: NSWindow?
    private let recorder = ShortcutRecorder()

    func show(settings: Settings, store: ClipStore) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, store: store, recorder: recorder)))
            w.title = "Clipboard Manager Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [recorder] _ in
                recorder.stop()
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
