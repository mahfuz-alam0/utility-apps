import Foundation

/// Word suggestions. Dictionary words are indexed by a loose phonetic "skeleton" (see `skeleton`), so
/// "tomake" finds তোমাকে and "bari" finds বাড়ি. Call from the main thread; `load` may run anywhere.
final class Lexicon {
  static let shared = Lexicon(learnedURL: FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Borno/learned.json"))

  private struct Index {
    var keys: [[UInt8]] = []         // sorted
    var words: [String] = []         // parallel to keys
    var autocorrect: [String: String] = [:]
  }

  private let lock = NSLock()
  private var index = Index()
  private var learned: [String: String]  // roman -> word the user picked last time
  private let learnedURL: URL?

  init(learnedURL: URL? = nil) {
    self.learnedURL = learnedURL
    learned = learnedURL.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
  }

  // MARK: loading

  func load(words: [String], autocorrect: [String: String] = [:]) {
    var pairs = words.compactMap { w -> ([UInt8], String)? in
      let k = Self.skeleton(w)
      return k.isEmpty ? nil : (k, w)
    }
    pairs.sort { $0.0.lexicographicallyPrecedes($1.0) }
    let built = Index(keys: pairs.map(\.0), words: pairs.map(\.1), autocorrect: autocorrect)
    lock.lock(); index = built; lock.unlock()
  }

  /// Reads words.txt / autocorrect.txt from the app bundle on a background queue.
  func loadBundled() {
    DispatchQueue.global(qos: .utility).async { [self] in
      guard let w = Bundle.main.url(forResource: "words", withExtension: "txt"),
        let data = try? Data(contentsOf: w) else { return }
      let words = data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
      var auto: [String: String] = [:]
      if let a = Bundle.main.url(forResource: "autocorrect", withExtension: "txt"),
        let text = try? String(contentsOf: a, encoding: .utf8) {
        for line in text.split(separator: "\n") {
          let kv = line.split(separator: "\t", maxSplits: 1)
          if kv.count == 2 { auto[String(kv[0])] = String(kv[1]) }
        }
      }
      load(words: words, autocorrect: auto)
    }
  }

  // MARK: suggestions

  /// Ranked candidates for the roman text typed so far. Never empty for non-empty input.
  /// Order: learned pick, autocorrect, literal phonetic result, dictionary matches, dictionary completions.
  func suggest(_ roman: String, limit: Int = 9) -> [String] {
    let phonetic = Phonetic.transliterate(roman)
    var out: [String] = []
    func add(_ w: String) { if !w.isEmpty, !out.contains(w) { out.append(w) } }

    lock.lock(); let idx = index; lock.unlock()
    if let w = learned[roman] { add(w) }
    if let r = idx.autocorrect[roman] { add(Phonetic.transliterate(r)) }
    add(phonetic)

    let key = Self.skeleton(phonetic)
    guard !key.isEmpty else { return Array(out.prefix(limit)) }
    var i = Self.lowerBound(key, in: idx.keys)

    // Closest spelling first; on a tie prefer words that start like the input (ভালো over ওভাল for "bhalo").
    let first = phonetic.unicodeScalars.first
    var exact: [(Int, String)] = []
    while i < idx.keys.count, idx.keys[i] == key {
      let w = idx.words[i]
      exact.append((2 * Self.distance(phonetic, w) + (w.unicodeScalars.first == first ? 0 : 1), w)); i += 1
    }
    exact.sort { $0.0 < $1.0 }
    exact.forEach { add($0.1) }

    // Completions: longer words that start with what was typed. Scan is capped, so short input gives few.
    if key.count >= 2 {
      var longer: [(Int, String)] = []
      var scanned = 0
      while i < idx.keys.count, scanned < 400, idx.keys[i].starts(with: key) {
        longer.append((idx.keys[i].count - key.count, idx.words[i])); i += 1; scanned += 1
      }
      longer.sort { $0.0 != $1.0 ? $0.0 < $1.0 : Self.distance(phonetic, $0.1) < Self.distance(phonetic, $1.1) }
      longer.forEach { add($0.1) }
    }
    return Array(out.prefix(limit))
  }

  /// Remember that `word` was chosen for `roman`; it becomes the first suggestion next time.
  func learn(_ roman: String, _ word: String) {
    guard learned[roman] != word else { return }
    learned[roman] = word
    guard let url = learnedURL, let data = try? JSONEncoder().encode(learned) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
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
