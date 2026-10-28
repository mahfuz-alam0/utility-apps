import AppKit
import Carbon.HIToolbox

enum Paste {
    /// Posts ⌘V to the frontmost app. Without Accessibility permission macOS drops the event, so ask for it instead.
    static func commandV() {
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        let src = CGEventSource(stateID: .privateState)  // ignore modifiers still held from the hotkey
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
