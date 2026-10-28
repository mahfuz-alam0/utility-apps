import AppKit
import Carbon

// Global shortcuts via Carbon hot keys: no Accessibility permission needed.

let modifiers: [String: (sym: String, mask: Int)] = [
    "COMMANDORCONTROL": ("⌘", cmdKey), "CMDORCTRL": ("⌘", cmdKey), "COMMAND": ("⌘", cmdKey), "CMD": ("⌘", cmdKey),
    "CONTROL": ("⌃", controlKey), "CTRL": ("⌃", controlKey),
    "ALT": ("⌥", optionKey), "OPTION": ("⌥", optionKey), "SHIFT": ("⇧", shiftKey),
]

let keyCodes: [String: UInt32] = [
    "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12,
    "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34,
    "P": 35, "RETURN": 36, "ENTER": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "N": 45, "M": 46, ".": 47, "TAB": 48, "SPACE": 49, "`": 50, "ESC": 53, "ESCAPE": 53,
    "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101,
    "F10": 109, "F11": 103, "F12": 111,
]

func parseAccel(_ accel: String) -> (code: UInt32, mods: UInt32)? {
    var mods = 0
    var code: UInt32?
    for part in accel.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
        if let m = modifiers[part] { mods |= m.mask } else { code = keyCodes[part] }
    }
    return code.map { ($0, UInt32(mods)) }
}

func pretty(_ accel: String) -> String {
    accel.split(separator: "+").map { modifiers[$0.uppercased()]?.sym ?? $0.uppercased() }.joined()
}

private var hotKeyActions: [UInt32: () -> Void] = [:]
private var hotKeyRefs: [EventHotKeyRef] = []

func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        hotKeyActions[id.id]?()
        return noErr
    }, 1, &spec, nil, nil)
}

func unregisterHotKeys() {
    hotKeyRefs.forEach { UnregisterEventHotKey($0) }
    hotKeyRefs = []
    hotKeyActions = [:]
}

/// Replaces all registered hot keys. Returns a warning for each one macOS refused.
func registerHotKeys(_ list: [(name: String, accel: String, action: () -> Void)]) -> [String] {
    unregisterHotKeys()
    var warnings: [String] = []
    for (n, b) in list.enumerated() where !b.accel.isEmpty {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5052_4D54, id: UInt32(n))
        if let (code, mods) = parseAccel(b.accel),
           RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            hotKeyRefs.append(ref)
            hotKeyActions[id.id] = b.action
        } else {
            warnings.append("\(pretty(b.accel)) is unavailable for \"\(b.name)\". Change it in config.json.")
        }
    }
    return warnings
}
