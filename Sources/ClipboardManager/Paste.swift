import AppKit
import Carbon.HIToolbox

enum Paste {
    private static var resetDone = false

    /// True when Accessibility is granted. Otherwise clears our grant and shows the system prompt.
    /// A toggle that is ON but no longer matches this binary's signature (older ad-hoc build) fails AXIsProcessTrusted
    /// forever and the prompt can't fix it, so drop the stale entry first. Once per run: a repeat would close the prompt.
    @discardableResult
    static func ensureAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !resetDone, let id = Bundle.main.bundleIdentifier {
            resetDone = true
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            try? p.run()
            p.waitUntilExit()
        }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        return false
    }

    /// Posts ⌘V to the frontmost app. Without Accessibility permission macOS drops the event, so ask for it instead.
    static func commandV() {
        guard ensureAccess() else { return }
        let src = CGEventSource(stateID: .privateState)  // ignore modifiers still held from the hotkey
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
