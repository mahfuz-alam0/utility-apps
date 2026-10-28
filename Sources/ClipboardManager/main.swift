import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private lazy var store = ClipStore(settings: settings)
    private lazy var monitor = ClipboardMonitor(store: store, settings: settings)
    private lazy var popup = PopupController(store: store, settings: settings)
    private let settingsWindow = SettingsWindow()
    private var statusItem: NSStatusItem!
    private let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        // Accessibility: simulated ⌘V + caret lookup. Prompts, and clears a stale grant left by an older build.
        Paste.ensureAccess()

        monitor.start()

        // First run: enable launch at login. Later the Settings toggle decides, so turning it off sticks.
        if UserDefaults.standard.object(forKey: "loginItemInitialized") == nil {
            UserDefaults.standard.set(true, forKey: "loginItemInitialized")
            settings.launchAtLogin = true
        }

        // Each sink fires once immediately (initial setup), then on every change.
        settings.$theme.sink { NSApp.appearance = $0.appearance }.store(in: &bag)
        settings.$paused.sink { [pauseItem] in pauseItem.state = $0 ? .on : .off }.store(in: &bag)
        settings.$hotKey.sink { [popup] spec in HotKey.register(spec) { popup.toggle() } }.store(in: &bag)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard history")
        icon?.isTemplate = true  // tints for light/dark menu bar
        statusItem.button?.image = icon

        let menu = NSMenu()
        menu.addItem(withTitle: "Show History", action: #selector(show), keyEquivalent: "").target = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(withTitle: "Clear History", action: #selector(clear), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        statusItem.menu = menu

        buildMainMenu()
        if !launchedAtLogin { openSettings() }  // opening the app by hand shows a window instead of nothing
    }

    /// Clicking the app (Dock, Launchpad, Finder) while it is already running.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    // ponytail: login-item launch detection untested; if it misfires the window just opens at login.
    private var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The Settings window turns the app into a regular one (Dock, ⌘Tab, menu bar), which needs a main menu for ⌘Q / ⌘W / ⌘C / ⌘V.
    private func buildMainMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [(String, Selector, String)]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem(withTitle: $0.0, action: $0.1, keyEquivalent: $0.2) }
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        }
        add("Clipboard Manager", [("Settings…", #selector(openSettings), ","), ("Quit", #selector(NSApplication.terminate), "q")])
        add("Edit", [("Cut", #selector(NSText.cut), "x"), ("Copy", #selector(NSText.copy), "c"),
                     ("Paste", #selector(NSText.paste), "v"), ("Select All", #selector(NSText.selectAll), "a")])
        add("Window", [("Close", #selector(NSWindow.performClose), "w")])
        NSApp.mainMenu = main
    }

    @objc private func show() { popup.toggle() }
    @objc private func clear() { store.clear() }
    @objc private func togglePause() { settings.paused.toggle() }
    @objc private func openSettings() { settingsWindow.show(settings: settings, store: store) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
