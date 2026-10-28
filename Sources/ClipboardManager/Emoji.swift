import Foundation

/// Every single-scalar emoji in the Unicode tables the OS ships, so the list matches the system emoji font.
/// ponytail: no skin tones, flags, ZWJ sequences (👨‍👩‍👧) or Apple's categories (private API). Add a curated list if needed.
enum Emoji {
    struct Entry { let char: String; let name: String }

    static let all: [Entry] = {
        // faces first, then the rest in code point order
        let ranges: [ClosedRange<UInt32>] = [0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1FAFF, 0x1F000...0x1F2FF, 0x203C...0x3299]
        return ranges.joined().compactMap { v in
            guard let s = Unicode.Scalar(v), s.properties.isEmoji, !s.properties.isEmojiModifier,
                  !(0x1F1E6...0x1F1FF).contains(v) else { return nil }  // skin-tone swatches, lone flag letters
            // text-style symbols (❤ ☺) need U+FE0F to render as emoji
            return Entry(char: String(s) + (s.properties.isEmojiPresentation ? "" : "\u{FE0F}"), name: (s.properties.name ?? "").lowercased())
        }
    }()
}
