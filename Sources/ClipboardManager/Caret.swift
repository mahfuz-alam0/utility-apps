import AppKit
import ApplicationServices

/// Text-caret rect of the focused field in `pid`, in Cocoa screen coords. Nil when the app doesn't expose it.
// ponytail: zero-length selections return empty bounds in some apps (and Chrome/Electron expose no AX text
// by default); we fall back to the mouse. Upgrade: retry with a 1-char range before the caret.
enum Caret {
    static func rect(pid: pid_t) -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: AnyObject?, range: AnyObject?, bounds: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let el = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range,
              AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.height > 0, r.origin != .zero else { return nil }
        // AX origin is top-left of the primary screen; Cocoa's is bottom-left
        r.origin.y = NSScreen.screens[0].frame.height - r.maxY
        return r
    }
}
