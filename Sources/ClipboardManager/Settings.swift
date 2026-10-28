import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Theme: Int, CaseIterable, Identifiable {
    case system, light, dark
    var id: Int { rawValue }
    var title: String { ["System", "Light", "Dark"][rawValue] }
    /// nil = follow the system
    var appearance: NSAppearance? { [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][rawValue] }
}

struct HotKeySpec: Codable, Equatable {
    var code: Int
    var mods: Int  // Carbon modifier mask
    var label: String
    static let standard = HotKeySpec(code: kVK_ANSI_V, mods: controlKey | shiftKey, label: "⌃⇧V")
}

/// User preferences, persisted in UserDefaults. Plain @Published + didSet (no @AppStorage) so it works in any SDK.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d: UserDefaults

    @Published var maxItems: Int {
        didSet {
            let c = min(max(maxItems, 1), 500)
            if c != maxItems { maxItems = c }
            d.set(c, forKey: "maxItems")
        }
    }
    @Published var persistHistory: Bool { didSet { d.set(persistHistory, forKey: "persistHistory") } }
    @Published var recordText: Bool { didSet { d.set(recordText, forKey: "recordText") } }
    @Published var recordImages: Bool { didSet { d.set(recordImages, forKey: "recordImages") } }
    @Published var ignoreSecrets: Bool { didSet { d.set(ignoreSecrets, forKey: "ignoreSecrets") } }
    @Published var paused: Bool { didSet { d.set(paused, forKey: "paused") } }
    @Published var showTimestamps: Bool { didSet { d.set(showTimestamps, forKey: "showTimestamps") } }
    @Published var openAtCaret: Bool { didSet { d.set(openAtCaret, forKey: "openAtCaret") } }
    @Published var theme: Theme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var hotKey: HotKeySpec { didSet { d.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        defaults.register(defaults: [
            "maxItems": 25,  // Windows keeps 25
            "persistHistory": true, "recordText": true, "recordImages": true, "ignoreSecrets": true,
            "showTimestamps": true, "openAtCaret": true,
        ])
        maxItems = defaults.integer(forKey: "maxItems")
        persistHistory = defaults.bool(forKey: "persistHistory")
        recordText = defaults.bool(forKey: "recordText")
        recordImages = defaults.bool(forKey: "recordImages")
        ignoreSecrets = defaults.bool(forKey: "ignoreSecrets")
        paused = defaults.bool(forKey: "paused")
        showTimestamps = defaults.bool(forKey: "showTimestamps")
        openAtCaret = defaults.bool(forKey: "openAtCaret")
        theme = Theme(rawValue: defaults.integer(forKey: "theme")) ?? .system
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .standard
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
