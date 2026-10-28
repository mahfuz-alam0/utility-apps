import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon. Needs no permission, unlike a CGEventTap.
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    /// Replaces any previously registered hotkey.
    static func register(_ spec: HotKeySpec, action: @escaping () -> Void) {
        self.action = action
        if !handlerInstalled {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action?(); return noErr },
                                1, &type, nil, nil)
            handlerInstalled = true
        }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let status = RegisterEventHotKey(UInt32(spec.code), UInt32(spec.mods), EventHotKeyID(signature: 0x434C4950, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("hotkey registration failed (\(status)); another app owns it?") }
    }
}
