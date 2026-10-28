import Testing
@testable import ClipboardManager

@Test func emojiListFiltersAndSearchesByName() {
    let all = Emoji.all
    #expect(all.first?.char == "😀")  // faces lead
    #expect(all.contains { $0.char == "❤\u{FE0F}" })  // text-style symbol gets U+FE0F
    #expect(!all.contains { $0.char.unicodeScalars.first!.properties.isEmojiModifier })  // no bare skin-tone swatches
    #expect(all.contains { $0.name == "grinning face" })

    let m = PopupModel()
    m.query = "GRINNING"  // case-insensitive
    #expect(!m.emojis.isEmpty && m.emojis.allSatisfy { $0.name.contains("grinning") })
}
