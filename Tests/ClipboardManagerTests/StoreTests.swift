import Foundation
import Testing
@testable import ClipboardManager

@Test func storeDedupesPinsCapsAndPersists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.maxItems = 3

    let s = ClipStore(dir: dir, settings: settings)
    ["a", "b", "a", "c", "d"].forEach { s.add(text: $0) }
    #expect(s.items.map(\.text) == ["d", "c", "a"])  // newest first, "a" deduped, capped at 3

    s.togglePin(s.items[2])  // pin "a" -> moves to top, exempt from cap
    ["e", "f"].forEach { s.add(text: $0) }
    #expect(s.items.map(\.text) == ["a", "f", "e", "d"])

    s.add(png: Data([1, 2, 3]))
    #expect(s.items.count == 4 && s.items[1].image != nil)

    #expect(ClipStore(dir: dir, settings: settings).items == s.items)  // survives restart

    settings.maxItems = 1  // shrinking the cap trims live
    #expect(s.items.count == 2)

    s.clear()  // keeps pinned
    #expect(s.items.map(\.text) == ["a"])
}

@Test func settingsClampMaxItems() {
    let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    settings.maxItems = -5
    #expect(settings.maxItems == 1)
    settings.maxItems = 9999
    #expect(settings.maxItems == 500)
}
