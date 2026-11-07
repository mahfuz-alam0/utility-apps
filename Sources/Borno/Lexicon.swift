import Foundation
import os

private let log = Logger(subsystem: "com.mahfuz.inputmethod.Borno", category: "lexicon")

/// Word suggestions. Dictionary words are indexed by a loose phonetic "skeleton" (see `skeleton`), so
/// "tomake" finds তোমাকে and "bari" finds বাড়ি. Call from the main thread; `load` may run anywhere.
final class Lexicon {
  static let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Borno")
  static let userWordsURL = supportDir.appendingPathComponent("user-words.txt")
  static let shared = Lexicon(learnedURL: supportDir.appendingPathComponent("learned.json"), userWordsURL: userWordsURL)

  private struct Index {
    var keys: [[UInt8]] = []         // sorted
    var words: [String] = []         // parallel to keys
    var cons: [[UInt8]] = []         // keys without vowels, parallel to keys (for fuzzy fallback)
    var autocorrect: [String: String] = [:]
  }

  private let lock = NSLock()
  private var index = Index()
  private var counts: [String: [String: Int]]  // roman -> word -> times the user committed it
  private let learnedURL: URL?
  private let userWordsURL: URL?
  private let maxLearned: Int
  private let saveQueue = DispatchQueue(label: "borno.learned.save", qos: .utility)
  private var pendingSave: DispatchWorkItem?

  init(learnedURL: URL? = nil, userWordsURL: URL? = nil, maxLearned: Int = 20_000) {
    self.learnedURL = learnedURL
    self.userWordsURL = userWordsURL
    self.maxLearned = maxLearned
    let data = learnedURL.flatMap { try? Data(contentsOf: $0) }
    counts = data.flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) }
      ?? data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?.mapValues { [$0: 1] }  // old format
      ?? [:]
  }

  // MARK: loading

  func load(words: [String], autocorrect: [String: String] = [:]) {
    var pairs = words.compactMap { w -> ([UInt8], String)? in
      let k = Self.skeleton(w)
      return k.isEmpty ? nil : (k, w)
    }
    pairs.sort { $0.0.lexicographicallyPrecedes($1.0) }
    let built = Index(keys: pairs.map(\.0), words: pairs.map(\.1), cons: pairs.map { Self.consonants($0.0) },
                      autocorrect: autocorrect)
    lock.lock(); index = built; lock.unlock()
  }

  /// Reads words.txt / autocorrect.txt from the app bundle and the user's custom words, on a background queue.
  /// Call again to pick up edits to the custom words file.
  func loadBundled() {
    userWordsStamp = userWordsModified
    DispatchQueue.global(qos: .utility).async { [self] in loadResources() }
  }

  private var userWordsStamp: Date?
  private var userWordsModified: Date? {
    userWordsURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
  }

  /// Cheap; call whenever a text field gains focus so edits to the custom words file apply without a restart.
  func reloadIfUserWordsChanged() {
    if userWordsModified != userWordsStamp { loadBundled() }
  }

  func loadResources(from bundle: Bundle = .main) {
    var words: [String] = []
    if let w = bundle.url(forResource: "words", withExtension: "txt"), let data = try? Data(contentsOf: w) {
      words = data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
    } else {
      log.error("words.txt missing from the app bundle: no dictionary suggestions")
    }
    var auto: [String: String] = [:]
    if let a = bundle.url(forResource: "autocorrect", withExtension: "txt"),
      let text = try? String(contentsOf: a, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        let kv = line.split(separator: "\t", maxSplits: 1)
        if kv.count == 2 { auto[String(kv[0])] = String(kv[1]) }
      }
    }
    if let u = userWordsURL, let text = try? String(contentsOf: u, encoding: .utf8) {
      let mine = Self.parseUserWords(text)
      log.info("loaded \(mine.count) custom words")
      words += mine
    }
    load(words: words, autocorrect: auto)
  }

  /// One word per line; blank lines and lines starting with # are ignored.
  static func parseUserWords(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  // MARK: suggestions

  /// Ranked candidates for the roman text typed so far. Never empty for non-empty input.
  /// Words you committed before come first, most-committed first; the rest keep the order from `base`.
  func suggest(_ roman: String, limit: Int = 9) -> [String] {
    var out = base(roman, limit: limit)
    let seen = counts[roman] ?? [:]
    for w in seen.keys.sorted() where !out.contains(w) { out.append(w) }
    return out.enumerated().sorted {
      let a = seen[$0.element] ?? 0, b = seen[$1.element] ?? 0
      return a != b ? a > b : $0.offset < $1.offset
    }.prefix(limit).map(\.element)
  }

  /// Order: autocorrect, literal phonetic result, dictionary matches, dictionary completions.
  private func base(_ roman: String, limit: Int, respelled: Bool = false) -> [String] {
    let phonetic = Phonetic.transliterate(roman)
    var out: [String] = []
    func add(_ w: String) { if !w.isEmpty, !out.contains(w) { out.append(w) } }

    lock.lock(); let idx = index; lock.unlock()
    if let r = idx.autocorrect[roman] { add(Phonetic.transliterate(r)) }

    let key = Self.skeleton(phonetic)
    guard !key.isEmpty else { add(phonetic); return Array(out.prefix(limit)) }
    var i = Self.lowerBound(key, in: idx.keys)

    // Closest spelling first; on a tie prefer words that start like the input (ভালো over ওভাল for "bhalo").
    let first = phonetic.unicodeScalars.first
    var exact: [(score: Int, dist: Int, word: String)] = []
    while i < idx.keys.count, idx.keys[i] == key {
      let w = idx.words[i]
      let d = Self.distance(phonetic, w)
      exact.append((2 * d + (w.unicodeScalars.first == first ? 0 : 1), d, w)); i += 1
    }
    exact.sort { $0.score < $1.score }

    // Fuzzy matches (English-style spelling, extra vowels): vowels are noise, so compare consonants only,
    // allowing 0-2 edits. ponytail: linear scan (~10 ms on 160k words), index it if it lags.
    let q = Self.consonants(key), maxD = q.count < 4 ? 0 : q.count < 6 ? 1 : 2
    var row = [Int](repeating: 0, count: q.count + 1)
    var near: [(cons: Int, skel: Int, word: String)] = []
    if exact.isEmpty || out.count + exact.count < limit {
      for (n, c) in idx.cons.enumerated() where abs(c.count - q.count) <= maxD {
        let d = Self.edits(q, c, &row)
        if d <= maxD { near.append((d, Self.edits(key, idx.keys[n], &row), idx.words[n])) }
      }
      near.sort { $0.cons != $1.cons ? $0.cons < $1.cons : $0.skel < $1.skel }
    }

    // Completions: longer words that start with what was typed. Scan is capped, so short input gives few.
    var longer: [(Int, String)] = []
    if key.count >= 2 {
      var scanned = 0
      while i < idx.keys.count, scanned < 400, idx.keys[i].starts(with: key) {
        longer.append((idx.keys[i].count - key.count, idx.words[i])); i += 1; scanned += 1
      }
      longer.sort { $0.0 != $1.0 ? $0.0 < $1.0 : Self.distance(phonetic, $0.1) < Self.distance(phonetic, $1.1) }
    }

    // The dictionary beats the literal result when what you typed cannot be the start of any real word, so
    // the literal is a slip (গ্রিশ্মকাল -> গ্রীষ্মকাল: same sound class; সারকার -> সরকার: one stray vowel).
    // While it still can be (গ্রি -> গ্রিক গ্রিস), the literal stays first. Names the dictionary lacks keep it too.
    let len = phonetic.unicodeScalars.count
    func extends(_ w: String) -> Bool { w.unicodeScalars.starts(with: phonetic.unicodeScalars) }
    var typing = exact.contains { extends($0.word) }
    var j = Self.lowerBound(key, in: idx.keys)   // `longer` is capped; this check is not
    while !typing, j < idx.keys.count, idx.keys[j].starts(with: key) { typing = extends(idx.words[j]); j += 1 }
    if !typing, let b = exact.first {
      add(b.word)
    } else if !typing, let b = near.filter({ $0.cons == 0 && $0.word.unicodeScalars.last == phonetic.unicodeScalars.last })  // same ending: একুশে is not একুশ
      .map({ (Self.distance(phonetic, $0.word), $0.word) }).min(by: { $0.0 < $1.0 }), respelled || b.0 * 3 <= len {
      add(b.1)
    } else if !typing, !respelled, let w = englishFix(roman, limit: limit) {
      add(w)
    }
    add(phonetic)
    // Words one letter off (ভাল -> ভালো) first, then real completions of what was typed (গ্রি -> গ্রিক গ্রিস),
    // then the rest of the look-alikes (গড়ি).
    exact.filter { $0.dist <= 1 }.forEach { add($0.word) }
    longer.filter { $0.1.hasPrefix(phonetic) }.forEach { add($0.1) }
    exact.forEach { add($0.word) }
    longer.forEach { add($0.1) }
    if maxD > 0 { near.forEach { add($0.word) } }
    return Array(out.prefix(limit))
  }

  /// Plain lowercase input that is not a dictionary prefix may be an English word ("suggestion"): respell it the
  /// way it sounds ("sajeshon") and look that up. Returns a dictionary word only.
  private func englishFix(_ roman: String, limit: Int) -> String? {
    guard roman.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
    lock.lock(); let idx = index; lock.unlock()
    func known(_ w: String) -> Bool {
      let k = Self.skeleton(w)
      var i = Self.lowerBound(k, in: idx.keys)
      while i < idx.keys.count, idx.keys[i] == k { if idx.words[i] == w { return true }; i += 1 }
      return false
    }
    // "-stion" is শ্চন in question but শন in suggestion, so try both.
    for rules in [[("stion", "schon")] + Self.englishRules, Self.englishRules] {
      let spoken = rules.reduce(roman) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
      if spoken != roman, let w = base(spoken, limit: limit, respelled: true).first, known(w) { return w }
    }
    return nil
  }

  // Rough English spelling -> Avro roman, applied in order. ponytail: a handful of rules, not a pronouncing
  // dictionary; add a rule when a common word still misses.
  private static let englishRules = [
    ("([^aeiou])\\1", "$1"), ("[ct]ial", "shal"), ("tch", "ch"), ("ck", "k"), ("c(?=[eiy])", "s"), ("c(?!h)", "k"), ("ch", "c"),
    ("tion|sion|cian", "shon"), ("ture", "car"), ("qu", "ku"), ("g(?=[eiy])", "j"), ("ea", "i"),
    ("([^aeiou])\\1", "$1"),
  ]

  /// Count one commit of `word` for `roman`. Call on every commit, default pick included, so a word you keep
  /// choosing climbs past the default only once it has been chosen more often.
  /// The file is written 1 s after the last commit, off the main thread. Past `maxLearned` spellings the
  /// least-used 10% are dropped. ponytail: no decay; halve counts now and then if old picks should fade.
  func learn(_ roman: String, _ word: String) {
    counts[roman, default: [:]][word, default: 0] += 1
    if counts.count > maxLearned {
      let total = { (k: String) in self.counts[k]!.values.reduce(0, +) }
      counts.keys.filter { $0 != roman }.sorted { total($0) < total($1) }
        .prefix(counts.count - maxLearned * 9 / 10).forEach { counts[$0] = nil }
    }
    guard let url = learnedURL else { return }
    pendingSave?.cancel()
    let snapshot = counts
    var item: DispatchWorkItem!
    item = DispatchWorkItem { [weak self] in
      Self.write(snapshot, to: url)
      DispatchQueue.main.async { if self?.pendingSave === item { self?.pendingSave = nil } }   // flush() has nothing left
    }
    pendingSave = item
    saveQueue.asyncAfter(deadline: .now() + 1, execute: item)
  }

  /// Writes a pending save now (call when the input method goes away).
  func flush() {
    guard let url = learnedURL, let item = pendingSave else { return }
    item.cancel(); pendingSave = nil
    let snapshot = counts
    saveQueue.sync { Self.write(snapshot, to: url) }
  }

  /// Forgets every learned pick, in memory and on disk.
  func clearLearned() {
    pendingSave?.cancel(); pendingSave = nil
    counts = [:]
    if let url = learnedURL { saveQueue.sync { try? FileManager.default.removeItem(at: url) } }
  }

  private static func write(_ counts: [String: [String: Int]], to url: URL) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(counts).write(to: url, options: .atomic)
    } catch {
      log.error("could not save learned words: \(error.localizedDescription)")
    }
  }

  // MARK: helpers

  private static let classes: [UInt32: UInt8] = {
    var m: [UInt32: UInt8] = [:]
    // Letters people mix up when typing (s/sh/S, n/N, t/T, d/D, j/z, r/R) share one class.
    // অ ও ো are in no class: the o-vowel is optional, so "tomake" matches তোমাকে.
    for (chars, c) in [
      ("ক", "k"), ("খ", "K"), ("গ", "g"), ("ঘ", "G"), ("ঙং", "N"), ("চ", "c"), ("ছ", "C"), ("জয", "j"), ("ঝ", "J"),
      ("ঞ", "Y"), ("টত", "t"), ("ঠথ", "T"), ("ডদ", "d"), ("ঢধ", "D"), ("নণ", "n"), ("প", "p"), ("ফ", "f"),
      ("ব", "b"), ("ভ", "v"), ("ম", "m"), ("র", "r"), ("ল", "l"), ("শষস", "s"), ("হ", "h"), ("ৎ", "t"),
      ("আা", "a"), ("ইঈিী", "i"), ("উঊুূ", "u"), ("ঋৃ", "R"), ("এে", "e"), ("ঐৈ", "E"), ("ঔৌ", "W"),
    ] as [(String, Character)] {
      for u in chars.unicodeScalars { m[u.value] = c.asciiValue! }
    }
    m[0x09DC] = m[0x09B0]; m[0x09DD] = m[0x09B0]   // ড় ঢ় ~ র
    m[0x09DF] = Character("y").asciiValue!          // য়
    return m
  }()

  /// Loose phonetic key. Drops hasanta, chandrabindu, visarga and the o-vowel, merges look-alike letters and
  /// vowel lengths, so spelling slips and missing conjuncts still hit the same dictionary entry.
  static func skeleton(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var prev: UInt32 = 0
    for u in s.unicodeScalars {
      if u.value == 0x09BC {  // nukta: ড+় ঢ+় -> র class, য+় -> য়
        if prev == 0x09A1 || prev == 0x09A2 { out[out.count - 1] = classes[0x09B0]! }
        else if prev == 0x09AF { out[out.count - 1] = classes[0x09DF]! }
      } else if let c = classes[u.value] { out.append(c) }
      prev = u.value
    }
    return out
  }

  /// `skeleton` minus vowels.
  static func consonants(_ key: [UInt8]) -> [UInt8] { key.filter { !"aiuReEW".utf8.contains($0) } }

  /// Levenshtein distance over small byte arrays; `row` is scratch space, at least `a.count + 1` long.
  private static func edits(_ a: [UInt8], _ b: [UInt8], _ row: inout [Int]) -> Int {
    if row.count < a.count + 1 { row = [Int](repeating: 0, count: a.count + 1) }
    for j in 0...a.count { row[j] = j }
    for (i, y) in b.enumerated() {
      var diag = row[0]
      row[0] = i + 1
      for (j, x) in a.enumerated() {
        let up = row[j + 1]
        row[j + 1] = min(up + 1, row[j] + 1, diag + (x == y ? 0 : 1))
        diag = up
      }
    }
    return row[a.count]
  }

  private static func lowerBound(_ target: [UInt8], in keys: [[UInt8]]) -> Int {
    var lo = 0, hi = keys.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if keys[mid].lexicographicallyPrecedes(target) { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// Levenshtein distance over unicode scalars.
  static func distance(_ a: String, _ b: String) -> Int {
    let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
    if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
    var row = Array(0...y.count)
    for i in 1...x.count {
      var diag = row[0]
      row[0] = i
      for j in 1...y.count {
        let up = row[j]
        row[j] = min(row[j] + 1, row[j - 1] + 1, diag + (x[i - 1] == y[j - 1] ? 0 : 1))
        diag = up
      }
    }
    return row[y.count]
  }
}
