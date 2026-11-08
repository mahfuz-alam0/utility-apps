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

/// One toolbar tab of the settings window. Short grouped forms that fit without scrolling; the window resizes per tab.
struct SettingsView: View {
    enum Pane { case general, history, privacy }
    let pane: Pane
    @ObservedObject var settings: Settings
    @ObservedObject var store: ClipStore
    @ObservedObject var recorder: ShortcutRecorder

    var body: some View {
        Form {
            switch pane {
            case .general: general
            case .history: history
            case .privacy: privacy
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)  // compact rows
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            LabeledContent("Shortcut") {
                HStack(spacing: 6) {
                    Button(recorder.recording ? "Press shortcut…" : settings.hotKey.label) { recorder.toggle(settings) }
                    if settings.hotKey != .standard {
                        Button { settings.hotKey = .standard } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless).help("Reset to \(HotKeySpec.standard.label)")
                    }
                }
            }
            Picker("Open popup at", selection: $settings.openAtCaret) {
                Text("Text cursor").tag(true)
                Text("Mouse pointer").tag(false)
            }
        }
        Section {
            Picker("Theme", selection: $settings.theme) {
                ForEach(Theme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show timestamps", isOn: $settings.showTimestamps)
        }
    }

    @ViewBuilder private var history: some View {
        Section {
            LabeledContent("Maximum items") {
                HStack(spacing: 4) {
                    TextField("", value: $settings.maxItems, format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 48)
                    Stepper("", value: $settings.maxItems, in: 1...500).labelsHidden()
                }
            }
            Toggle("Record text", isOn: $settings.recordText)
            Toggle("Record images", isOn: $settings.recordImages)
        } footer: {
            Text("Pinned items don't count toward the limit and survive Clear.")
        }
        Section {
            LabeledContent("Save images to") {
                HStack(spacing: 6) {
                    Text(settings.saveFolder.isEmpty ? "Off" : (settings.saveFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    if !settings.saveFolder.isEmpty {
                        Button { settings.saveFolder = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop saving images")
                    }
                }
            }
        } footer: {
            Text("Also saves every recorded image here as a PNG, named like a macOS screenshot.")
        }
        Section {
            let n = store.items.filter { !$0.pinned }.count
            LabeledContent("\(n) unpinned \(n == 1 ? "item" : "items")") {
                Button("Clear History", role: .destructive) { store.clear() }.disabled(n == 0)
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        Section {
            Toggle("Pause recording", isOn: $settings.paused)
            Toggle("Keep history after quitting", isOn: $settings.persistHistory)
            Toggle("Ignore password-manager content", isOn: $settings.ignoreSecrets)
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url { settings.saveFolder = url.path }
    }
}

final class SettingsWindow {
    private var window: NSWindow?
    private let recorder = ShortcutRecorder()

    func show(settings: Settings, store: ClipStore) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar  // standard macOS preferences: icon tabs, window title follows the tab
            for (pane, label, symbol) in [(SettingsView.Pane.general, "General", "gearshape"),
                                          (.history, "History", "clock.arrow.circlepath"),
                                          (.privacy, "Privacy", "hand.raised")] {
                let vc = NSHostingController(rootView: SettingsView(pane: pane, settings: settings, store: store, recorder: recorder))
                vc.sizingOptions = .preferredContentSize  // lets the tab controller resize the window to each pane
                vc.title = label  // shown as the window title for the selected tab
                let item = NSTabViewItem(viewController: vc)
                item.label = label
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [recorder] _ in
                recorder.stop()
                NSApp.setActivationPolicy(.accessory)  // back to menu-bar only
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)  // Dock icon + ⌘Tab while the window is open
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
