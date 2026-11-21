// Port of iAvro 1.5 (OmicronLab, https://github.com/torifat/iAvro). This file is under the
// Mozilla Public License 1.1 (https://www.mozilla.org/MPL/1.1/), not the MIT License of the rest of Borno.

import Foundation
import SQLite3
import os

private let log = Logger(subsystem: "com.mahfuz.inputmethod.Borno", category: "lexicon")

/// Literal UTF-16 equality, like NSString `isEqual:`. Swift `==` would merge ড় with ড + ়, which iAvro keeps apart.
func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
private func has(_ list: [String], _ s: String) -> Bool { list.contains { same($0, s) } }

/// Suggestions, ported from iAvro 1.5 (OmicronLab, MPL 1.1): Suggestion.m, Database.m, AutoCorrect.m and
/// CacheManager.m, with iAvro's own data (database.db3, autodict.plist). Same candidates, same order, same
/// remembered pick per spelling. Main thread only.
final class Lexicon {
  static let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Borno")
  static let userWordsURL = supportDir.appendingPathComponent("user-words.txt")
  static let shared: Lexicon = {
    do {
      return try Lexicon(resources: Bundle.main.resourceURL!, weightURL: supportDir.appendingPathComponent("weight.plist"),
                         userWordsURL: userWordsURL)
    } catch {
      fatalError("Borno resources missing or unreadable: \(error)")
    }
  }()
  /// iAvro's remembered picks, taken over on first run if iAvro was used on this Mac.
  private static let iAvroWeightURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("OmicronLab/Avro Keyboard/weight.plist")

  let bangla: Phonetic
  private let regex: Phonetic
  private var tables: [String: [NSString]] = [:]   // dictionary words, one table per first Bangla letter
  private var suffixes: [String: String] = [:]     // roman suffix -> Bangla ("der" -> "দের")
  private let autocorrect: [String: String]
  private var freq: [String: Int] = [:]            // Borno extra: how often each word is used (freq.txt)
  private var userWords: [NSString] = []           // Borno extra: searched like a table, after iAvro's
  private var userWordsStamp: Date?
  private let weightURL: URL?, userWordsURL: URL?
  private var weight: [String: String]             // roman -> last highlighted word (iAvro weight.plist)
  private var weightChanged = false
  private var cache: [String: [String]] = [:]      // roman -> autocorrect + dictionary words
  private var recentBase: [String: (base: String, item: String)] = [:]   // word made by suffixing -> its parts

  init(resources dir: URL, weightURL: URL? = nil, userWordsURL: URL? = nil) throws {
    bangla = try Phonetic(dir.appendingPathComponent("data.json"))
    regex = try Phonetic(dir.appendingPathComponent("regex.json"), regex: true)
    autocorrect = NSDictionary(contentsOf: dir.appendingPathComponent("autodict.plist")) as? [String: String] ?? [:]
    self.weightURL = weightURL
    self.userWordsURL = userWordsURL
    func read(_ u: URL?) -> [String: String]? { u.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } }
    weight = read(weightURL) ?? (weightURL == nil ? nil : read(Self.iAvroWeightURL)) ?? [:]

    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(dir.appendingPathComponent("database.db3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    else { throw CocoaError(.fileReadNoSuchFile) }
    func rows(_ sql: String, _ each: (_ col: (Int32) -> NSString?) -> Void) {
      var st: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
      defer { sqlite3_finalize(st) }
      while sqlite3_step(st) == SQLITE_ROW {
        each { i in sqlite3_column_text(st, i).flatMap { NSString(utf8String: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } }
      }
    }
    var names: [String] = []
    rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'Suffix'") { if let n = $0(0) { names.append(n as String) } }
    for name in names {
      var words: [NSString] = []
      rows("SELECT Words FROM \"\(name)\"") { if let w = $0(0) { words.append(w) } }
      tables[name.lowercased()] = words
    }
    rows("SELECT English, Bangla FROM Suffix") { if let e = $0(0), let b = $0(1) { suffixes[e as String] = b as String } }

    // Borno extra: word counts rank the matches, and words the dictionary lacks (করবো, যাবো) join the table of
    // their first letter.
    var tableOf: [unichar: String] = [:]
    for (name, words) in tables { for w in words where w.length > 0 { tableOf[w.character(at: 0)] = name } }
    var known = Set(tables.values.joined().map { $0 as String })
    let text = (try? String(contentsOf: dir.appendingPathComponent("freq.txt"), encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") {
      let cols = line.split(separator: "\t")
      guard cols.count == 2, let n = Int(cols[1]) else { continue }
      let w = String(cols[0])
      freq[w] = n
      if known.insert(w).inserted, let name = tableOf[(w as NSString).character(at: 0)] { tables[name]?.append(w as NSString) }
    }
    reloadIfUserWordsChanged()
  }

  // MARK: custom words

  /// Cheap; call whenever a text field gains focus so edits to the custom words file apply without a restart.
  func reloadIfUserWordsChanged() {
    let stamp = userWordsURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
    guard stamp != userWordsStamp else { return }
    userWordsStamp = stamp
    let text = userWordsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    userWords = Self.parseUserWords(text).map { $0 as NSString }
    cache.removeAll()
    log.info("loaded \(self.userWords.count) custom words")
  }

  /// One word per line; blank lines and lines starting with # are ignored. ড় ঢ় য় typed as letter + nukta become
  /// the single characters iAvro's rules match (NFC leaves them split).
  static func parseUserWords(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .map { w in
        [("\u{09A1}\u{09BC}", "\u{09DC}"), ("\u{09A2}\u{09BC}", "\u{09DD}"), ("\u{09AF}\u{09BC}", "\u{09DF}")]
          .reduce(w) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .literal) }
      }
  }

  // MARK: suggestions

  // AvroKeyboardController's split of the typed text: leading punctuation, the word, trailing punctuation.
  // `,,` (hasanta) stays in the word. Always matches.
  private static let splitter = try! NSRegularExpression(pattern:
    #"(^(?::`|\.`|[-\]\\~!@#&*()_=+\[{}'";<>/?|.,])*?(?=(?:,{2,}))|^(?::`|\.`|[-\]\\~!@#&*()_=+\[{}'";<>/?|.,])*)(.*?(?:,,)*)((?::`|\.`|[-\]\\~!@#&*()_=+\[{}'";<>/?|.,])*$)"#)

  static func split(_ typed: String) -> (prefix: String, term: String, suffix: String) {
    let s = typed as NSString
    guard let m = splitter.firstMatch(in: typed, range: NSRange(location: 0, length: s.length)) else { return ("", "", "") }
    func part(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : s.substring(with: m.range(at: i)) }
    return (part(1), part(2), part(3))
  }

  /// Suggestion.m `getList:`. Autocorrect, then dictionary words closest to the phonetic result first, then
  /// words built from a shorter dictionary word plus a suffix (`amarder` -> আমার + দের), then the phonetic
  /// result itself if it is not in the list yet. Empty only for empty input.
  func suggest(_ term: String) -> [String] {
    guard !term.isEmpty else { return [] }
    let parsed = bangla.parse(term)
    var list = words(term)

    var alreadySelected = false
    recentBase.removeAll()
    let t = term as NSString
    for i in stride(from: t.length - 1, to: 0, by: -1) {
      guard let suffix = suffixes[t.substring(from: i).lowercased()] else { continue }
      let base = t.substring(to: i)
      // iAvro reads the base from its cache, which only holds spellings that were a whole word while typing.
      guard same(Self.split(base).term, base) else { continue }
      let selected = alreadySelected ? nil : weight[base]
      for item in words(base) where !same(item, base) && !item.isEmpty {   // skip autocorrect's kept English words
        let s = item as NSString, cut = s.length - 1
        let last = s.substring(from: cut), first = (suffix as NSString).substring(to: 1)
        let word: String
        if Self.vowels.contains(last), Self.kars.contains(first) {
          word = item + "\u{09DF}" + suffix                       // vowel + kar: য় between
        } else if last == "\u{09CE}" {
          word = s.substring(to: cut) + "\u{09A4}" + suffix       // ৎ -> ত
        } else if last == "\u{0982}" {
          word = s.substring(to: cut) + "\u{0999}" + suffix       // ং -> ঙ
        } else {
          word = item + suffix
        }
        recentBase[word] = (base, item)
        if !has(list, word) {
          if !alreadySelected, let selected, same(item, selected) {   // the base word you picked before: pick it again
            if weight[term] == nil { weight[term] = word; weightChanged = true }
            alreadySelected = true
          }
          list.append(word)
        }
      }
    }
    if !has(list, parsed) { list.append(parsed) }
    return list
  }

  /// Autocorrect entry plus dictionary words for `term`, closest to its phonetic result first. iAvro caches
  /// this per spelling as you type; the suffix step reads the cached list of the shorter spelling.
  private func words(_ term: String) -> [String] {
    if let hit = cache[term], !hit.isEmpty { return hit }
    let parsed = bangla.parse(term)
    let auto = autocorrect(term)
    let dict = find(term)
    var list: [String] = []
    if let auto, !has(dict, auto) { list.append(auto) }
    // Borno: common words first, unless far from what was typed (iAvro sorted by distance alone).
    list += dict.map { w in (w, Foundation.log(Double(freq[w] ?? 0) + 1) * Self.freqWeight - Double(Self.levenshtein(parsed, w))) }
      .sorted { $0.1 > $1.1 }.map(\.0)
    if cache.count > 5000 { cache.removeAll() }   // ponytail: iAvro never empties it; this only caps memory
    cache[term] = list
    return list
  }

  /// AutoCorrect.m `find:`: English words and emoticons typed as is.
  func autocorrect(_ roman: String) -> String? { autocorrect[bangla.fix(roman)] }

  /// Database.m `find:`: words the regex form of `term` matches in full, from the tables its first letter can
  /// start (`a` -> অ আ এ ঐ ও ঞ য, ...). Unordered (NSMutableSet order, like iAvro); `words` sorts them.
  func find(_ term: String) -> [String] {
    let names = term.lowercased().first.flatMap { Self.tablesFor[$0] } ?? []
    guard let re = try? NSRegularExpression(pattern: "^" + regex.parse(term) + "$") else { return [] }
    let found = NSMutableSet(capacity: 0)
    for w in names.flatMap({ tables[$0] ?? [] }) + userWords
    where re.firstMatch(in: w as String, range: NSRange(location: 0, length: w.length)) != nil {
      found.add(w)
    }
    return found.allObjects.map { $0 as! String }
  }

  // MARK: remembered picks

  /// The word last highlighted for `term`, which iAvro highlights first next time.
  func remembered(_ term: String) -> String? { weight[term] }

  /// AvroKeyboardController `candidateSelectionChanged:`. `candidate` is the row as shown (with punctuation);
  /// if it was built from base + suffix, the base word is remembered for the base spelling too.
  func highlight(_ word: String, candidate: String, for term: String) {
    weight[term] = word
    if let b = recentBase[candidate] { weight[b.base] = b.item }
    weightChanged = true
  }

  /// Writes the remembered picks if they changed (iAvro: on commit).
  func save() {
    guard weightChanged, let url = weightURL else { return }
    weightChanged = false
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(fromPropertyList: weight, format: .xml, options: 0).write(to: url, options: .atomic)
    } catch {
      log.error("could not save remembered words: \(error.localizedDescription)")
    }
  }

  /// Forgets every remembered pick. Saves an empty file so iAvro's picks are not imported again.
  func clearLearned() {
    weight = [:]
    weightChanged = true
    save()
  }

  // MARK: helpers

  static var freqWeight = 1.0

  private static let kars = Set("\u{09BE}\u{09BF}\u{09C0}\u{09C1}\u{09C2}\u{09C3}\u{09C7}\u{09C8}\u{09CB}\u{09CC}\u{09C4}".map(String.init))
  private static let vowels = Set(("\u{0985}\u{0986}\u{0987}\u{0988}\u{0989}\u{098A}\u{098B}\u{098F}\u{0990}\u{0993}\u{0994}"
    + "\u{098C}\u{09E1}\u{09BE}\u{09BF}\u{09C0}\u{09C1}\u{09C2}\u{09C3}\u{09C7}\u{09C8}\u{09CB}\u{09CC}").map(String.init))

  /// Database.m: which tables a word typed with this first letter may come from.
  private static let tablesFor: [Character: [String]] = [
    "a": ["a", "aa", "e", "oi", "o", "nya", "y"], "b": ["b", "bh"], "c": ["c", "ch", "k"], "d": ["d", "dh", "dd", "ddh"],
    "e": ["i", "ii", "e", "y"], "f": ["ph"], "g": ["g", "gh", "j"], "h": ["h"], "i": ["i", "ii", "y"],
    "j": ["j", "jh", "z"], "k": ["k", "kh"], "l": ["l"], "m": ["h", "m"], "n": ["n", "nya", "nga", "nn"],
    "o": ["a", "u", "uu", "oi", "o", "ou", "y"], "p": ["p", "ph"], "q": ["k"], "r": ["rri", "h", "r", "rr", "rrh"],
    "s": ["s", "sh", "ss"], "t": ["t", "th", "tt", "tth", "khandatta"], "u": ["u", "uu", "y"], "v": ["bh"],
    "w": ["o"], "x": ["e", "k"], "y": ["i", "y"], "z": ["h", "j", "jh", "z"],
  ]

  /// NSString+Levenshtein.m: edit distance over UTF-16 units, -1 if either string is empty.
  static func levenshtein(_ a: String, _ b: String) -> Int {
    let x = Array(a.utf16), y = Array(b.utf16)
    if x.isEmpty || y.isEmpty { return -1 }
    var row = Array(0...y.count)
    for i in 1...x.count {
      var diag = row[0]
      row[0] = i
      for j in 1...y.count {
        let up = row[j]
        row[j] = min(up + 1, row[j - 1] + 1, diag + (x[i - 1] == y[j - 1] ? 0 : 1))
        diag = up
      }
    }
    return row[y.count]
  }
}
