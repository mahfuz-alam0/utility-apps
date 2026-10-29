import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var window: NSWindow!
    var server: CaptureServer!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        server = CaptureServer(isOn: { [store] in DispatchQueue.main.sync { store.capture } },
                               onAdd: { [store] url, h in DispatchQueue.main.async { store.add(url, headers: h) } })
        server.start()
        let host = NSHostingController(rootView: ContentView(store: store))
        host.sizingOptions = []
        window = NSWindow(contentViewController: host)
        window.title = "Downloader"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 520))
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Main")
        showWindow()
    }

    // paused (with progress saved) so the next launch can resume
    func applicationWillTerminate(_ n: Notification) { store.pauseAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !store.active && !store.capture }  // capture on: stay alive to receive browser downloads
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func addURL() {
        showWindow()
        store.adding = true
    }

    @objc func showExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.resourceURL!.appendingPathComponent("extension")])
    }

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
        let new = mi("Add URL…", #selector(addURL), "n")
        new.target = self
        let ext = mi("Show Browser Extension in Finder", #selector(showExtension))
        ext.target = self

        add("Downloader", [mi("About Downloader", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                           mi("Hide Downloader", #selector(NSApplication.hide(_:)), "h"),
                           mi("Quit Downloader", #selector(NSApplication.terminate(_:)), "q")])
        add("File", [new, ext, .separator(), mi("Close", #selector(NSWindow.performClose(_:)), "w")])
        add("Edit", [mi("Cut", #selector(NSText.cut(_:)), "x"), mi("Copy", #selector(NSText.copy(_:)), "c"),
                     mi("Paste", #selector(NSText.paste(_:)), "v"), mi("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), mi("Zoom", #selector(NSWindow.performZoom(_:)))])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
}

// one copy only: a second launch just brings the first one forward
if let id = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
    other.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
