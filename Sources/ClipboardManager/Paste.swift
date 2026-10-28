import AppKit
import Carbon.HIToolbox

enum Paste {
    /// Posts ⌘V to the frontmost app. Silently does nothing without Accessibility permission.
    static func commandV() {
        let src = CGEventSource(stateID: .privateState)  // ignore modifiers still held from the hotkey
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
