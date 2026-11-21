// Port of iAvro 1.5 (OmicronLab, https://github.com/torifat/iAvro). This file is under the
// Mozilla Public License 1.1 (https://www.mozilla.org/MPL/1.1/), not the MIT License of the rest of Borno.

import Foundation

/// Avro Phonetic, ported rule for rule from iAvro 1.5 (OmicronLab, MPL 1.1): AvroParser.m and RegexParser.m.
/// One matcher, two rule files: `data.json` turns roman into Bangla, `regex.json` turns roman into a regex that
/// matches every dictionary spelling the roman could stand for. iAvro's quirks are kept on purpose so the output
/// is the same: an `exact` rule needs a character after the match, the regex tail is `([ঃঁ]?)`, and the
/// regex file has no `number` scope (such a rule always passes).
final class Phonetic {
  private struct Match { let suffix: Bool; let scope: String; let value: NSString; let negative: Bool }
  private struct Rule { let matches: [Match]; let replace: String }
  private struct Pattern { let find: NSString; let replace: String; let rules: [Rule] }

  private let vowel: NSString, consonant: NSString, number: NSString, caseSensitive: NSString
  private let patterns: [Pattern]   // sorted by iAvro: longest `find` first, then ascending; binary-searched
  private let maxLength: Int
  private let isRegex: Bool
  private static let regexTail = "(\u{09CD}[\u{09AF}\u{09AC}\u{09AE}])?(\u{09CD}?)([\u{0983}\u{0981}]?)"

  /// `regex: true` for regex.json: its "casesensitive" list is regex syntax to drop, not letters to keep.
  init(_ url: URL, regex: Bool = false) throws {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let list = json["patterns"] as? [[String: Any]]
    else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
    func text(_ v: Any?) -> NSString { (v as? String ?? "") as NSString }
    vowel = text(json["vowel"]); consonant = text(json["consonant"])
    number = text(json["number"]); caseSensitive = text(json["casesensitive"])
    patterns = list.map { p in
      Pattern(find: text(p["find"]), replace: text(p["replace"]) as String,
        rules: (p["rules"] as? [[String: Any]] ?? []).map { r in
          Rule(matches: (r["matches"] as? [[String: Any]] ?? []).map { m in
            Match(suffix: m["type"] as? String == "suffix", scope: m["scope"] as? String ?? "",
                  value: text(m["value"]), negative: text(m["negative"]).boolValue)
          }, replace: text(r["replace"]) as String)
        })
    }
    maxLength = patterns.first?.find.length ?? 0
    isRegex = regex
  }

  func parse(_ input: String) -> String {
    if input.isEmpty { return "" }
    let s = fix(input) as NSString, len = s.length
    var out = ""
    var cur = 0
    while cur < len {
      let start = cur
      var matched = false
      var chunkLen = maxLength
      while chunkLen > 0, !matched {
        let end = start + chunkLen
        if end <= len, let p = find(s.substring(with: NSRange(location: start, length: chunkLen)) as NSString) {
          let rule = p.rules.first { $0.matches.allSatisfy { holds($0, in: s, start, end) } }
          out += (rule?.replace ?? p.replace) + (isRegex ? Self.regexTail : "")
          cur = end - 1
          matched = true
        }
        chunkLen -= 1
      }
      if !matched { out += s.substring(with: NSRange(location: cur, length: 1)) }
      cur += 1
    }
    return out
  }

  /// AvroParser `fix:` lowercases A-Z except case-sensitive letters (`O` stays ও, `o` is অ).
  /// RegexParser `clean:` lowercases and drops its listed characters.
  func fix(_ input: String) -> String {
    let s = input as NSString
    var out: [unichar] = []
    for i in 0..<s.length {
      let c = s.character(at: i)
      if !Self.has(caseSensitive, c) { out.append(Self.lower(c)) } else if !isRegex { out.append(c) }
    }
    return NSString(characters: out, length: out.count) as String
  }

  private func find(_ chunk: NSString) -> Pattern? {
    var left = 0, right = patterns.count - 1
    while right >= left {
      let mid = (right + left) / 2, f = patterns[mid].find
      if f.isEqual(to: chunk as String) { return patterns[mid] }
      if f.length > chunk.length || (f.length == chunk.length && f.compare(chunk as String) == .orderedAscending) {
        left = mid + 1
      } else {
        right = mid - 1
      }
    }
    return nil
  }

  private func holds(_ m: Match, in s: NSString, _ start: Int, _ end: Int) -> Bool {
    let len = s.length, chk = m.suffix ? end : start - 1
    func at(_ set: NSString) -> Bool { chk >= 0 && chk < len && Self.has(set, s.character(at: chk)) }
    let hit: Bool
    switch m.scope {
    case "punctuation": hit = chk < 0 || chk >= len || (!at(vowel) && !at(consonant))
    case "vowel": hit = at(vowel)
    case "consonant": hit = at(consonant)
    case "number" where !isRegex: hit = at(number)
    case "exact":
      let n = m.value.length, a = m.suffix ? end : start - n, b = m.suffix ? end + n : start
      hit = a >= 0 && b < len && m.value.isEqual(to: s.substring(with: NSRange(location: a, length: n)))  // iAvro: b < len
    default: return true
    }
    return hit != m.negative
  }

  private static func lower(_ c: unichar) -> unichar { c >= 65 && c <= 90 ? c + 32 : c }

  private static func has(_ set: NSString, _ c: unichar) -> Bool {
    let c = lower(c)
    for i in 0..<set.length where set.character(at: i) == c { return true }
    return false
  }
}
