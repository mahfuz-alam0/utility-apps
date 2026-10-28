import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    lazy var session = Session(store: store)
    var editor: NSWindow!
    var tray: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        installHotKeyHandler()
        session.onChange = { [weak self] in self?.updateTray() }
        session.onStop = { [weak self] in
            self?.updateTray()
            self?.showEditor()
        }
        buildMainMenu()
        createEditor()
        createTray()
        showEditor()
    }

    func applicationWillTerminate(_ n: Notification) { store.save() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !session.running }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showEditor()
        return true
    }

    // MARK: editor window

    func createEditor() {
        let host = NSHostingController(rootView: EditorView(store: store, start: { [weak self] in self?.start(at: $0) }))
        host.sizingOptions = []
        editor = NSWindow(contentViewController: host)
        editor.title = "Prompter"
        editor.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        editor.setContentSize(NSSize(width: 1000, height: 700))
        editor.contentMinSize = NSSize(width: 860, height: 600)
        editor.isReleasedWhenClosed = false
        editor.center()
        editor.setFrameAutosaveName("Editor")
    }

    func showEditor() {
        NSApp.activate(ignoringOtherApps: true)
        editor.makeKeyAndOrderFront(nil)
    }

    func start(at i: Int) {
        guard let script = store.current, !script.steps.isEmpty else { return NSSound.beep() }
        editor.orderOut(nil)
        session.start(script, at: i)
    }

    // MARK: menus

    @objc func newScript() { store.newScript() }
    @objc func importScript() { store.importScript() }
    @objc func exportScript() { store.exportScript() }
    @objc func startFromMenu() { start(at: 0) }

    func buildMainMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenuItem()
            m.submenu = NSMenu(title: title)
            items.forEach { m.submenu?.addItem($0) }
            main.addItem(m)
        }
        func mi(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let own = [mi("New Script", #selector(newScript), "n"), mi("Import Text File…", #selector(importScript), "o"),
                   mi("Export as Text…", #selector(exportScript), "e", [.command, .shift])]
        own.forEach { $0.target = self }
        let run = mi("Start Prompter", #selector(startFromMenu), "\r")
        run.target = self

        add("Prompter", [mi("About Prompter", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                         mi("Hide Prompter", #selector(NSApplication.hide(_:)), "h"),
                         mi("Quit Prompter", #selector(NSApplication.terminate(_:)), "q")])
        add("File", own + [.separator(), mi("Close", #selector(NSWindow.performClose(_:)), "w")])
        add("Edit", [mi("Undo", Selector(("undo:")), "z"), mi("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     mi("Cut", #selector(NSText.cut(_:)), "x"), mi("Copy", #selector(NSText.copy(_:)), "c"),
                     mi("Paste", #selector(NSText.paste(_:)), "v"), mi("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Script", [run])
        add("Window", [mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), mi("Zoom", #selector(NSWindow.performZoom(_:)))])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    // MARK: menu bar item

    func createTray() {
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = Bundle.main.image(forResource: "trayTemplate") {
            img.isTemplate = true
            tray.button?.image = img
            tray.button?.imagePosition = .imageLeft
        }
        tray.menu = NSMenu()
        tray.menu?.delegate = self
    }

    func updateTray() {
        tray.button?.title = session.running ? " \(session.index + 1)/\(session.steps.count)" : ""
        tray.button?.toolTip = session.running ? "Prompter: step \(session.index + 1) of \(session.steps.count)" : "Prompter"
    }

    @objc func menuAct(_ m: NSMenuItem) {
        switch m.representedObject as? String ?? "" {
        case "editor": showEditor()
        case "start": start(at: 0)
        case "quit": NSApp.terminate(nil)
        case let name: session.act(name)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = store.settings
        func k(_ name: String) -> String { "    " + pretty(store.keys[name] ?? "") }
        func add(_ title: String, _ action: String, on: Bool? = nil) {
            let m = NSMenuItem(title: title, action: #selector(menuAct(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = action
            if let on { m.state = on ? .on : .off }
            menu.addItem(m)
        }
        add("Open Editor", "editor")
        if session.running {
            add("Stop Prompter" + k("stop"), "stop")
            menu.addItem(.separator())
            add("Next step" + k("next"), "next")
            add("Previous step" + k("prev"), "prev")
            if s.mode == .auto { add((session.playing ? "Pause" : "Play") + k("toggleAuto"), "play") }
            menu.addItem(.separator())
            add("Auto mode", "mode", on: s.mode == .auto)
            add("Locked (clicks pass through)" + k("toggleLock"), "lock", on: s.locked)
            add("Hide from screen recordings", "protect", on: s.protect)
            add("Show overlay" + k("toggleVisible"), "visible", on: session.win.isVisible)
        } else {
            add("Start Prompter", "start")
        }
        menu.addItem(.separator())
        add("Quit Prompter", "quit")
    }
}

// MARK: - Entry

// one copy only: a second launch just brings the first one forward
if let id = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
    other.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
