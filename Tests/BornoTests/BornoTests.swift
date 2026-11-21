import Foundation
import Testing

@testable import Borno

private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("Resources/borno")

/// Suggestions after typing `roman` one key at a time, the way the input method calls the engine.
private func typed(_ lex: Lexicon, _ roman: String) -> [String] {
  var s = "", out: [String] = []
  for c in roman { s.append(c); out = lex.suggest(Lexicon.split(s).term) }
  return out
}

private func temp(_ ext: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("borno-\(UUID().uuidString).\(ext)")
}

@Test func phoneticMatchesAvro() throws {
  let p = try Lexicon(resources: resources).bangla
  let cases: [(String, String)] = [
    ("ami", "আমি"), ("amar", "আমার"), ("bhalo", "ভাল"), ("tOmake", "তোমাকে"), ("bangladesh", "বাংলাদেশ"),
    ("shikkha", "শিক্ষা"), ("amra", "আম্রা"), ("am`ra", "আমরা"), ("ek`i", "একই"), ("baRi", "বাড়ি"), ("kOI", "কৈ"),
    ("rri", "ঋ"), ("OI", "ঐ"), ("t``", "ৎ"), ("3.5", "৩.৫"), ("tumi.", "তুমি।"), ("bolchi", "বলছি"), ("kotha", "কথা"),
  ]
  for (roman, bangla) in cases { #expect(p.parse(roman) == bangla, "\(roman)") }
}

@Test func splitKeepsPunctuationOutOfTheWord() {
  #expect(Lexicon.split("\"ami\"") == ("\"", "ami", "\""))
  #expect(Lexicon.split("tumi.") == ("", "tumi", "."))
  #expect(Lexicon.split("ami,,") == ("", "ami,,", ""))     // ,, is hasanta: part of the word
  #expect(Lexicon.split(":-)") == ("", ":", "-)"))
}

@Test func suggestionsInIAvroOrder() throws {
  let lex = try Lexicon(resources: resources)
  #expect(typed(lex, "bhalo").prefix(2) == ["ভাল", "ভালো"])           // closest to the phonetic result first
  #expect(typed(lex, "amra") == ["আমরা", "আমড়া", "এমরা", "আম্রা"])  // phonetic result last when not a word
  #expect(typed(lex, "facebook").first == "ফেইসবুক")                  // autocorrect first
  #expect(typed(lex, "computergulo").first == "কম্পিউটারগুলো")         // autocorrect word + suffix
  #expect(typed(lex, "manusher").first == "মানুষের")                  // dictionary word + suffix
  #expect(lex.autocorrect(":-)") == ":-)")                            // emoticons stay as typed
}

@Test func rememberedPicks() throws {
  let file = temp("plist")
  defer { try? FileManager.default.removeItem(at: file) }
  let lex = try Lexicon(resources: resources, weightURL: file)
  _ = typed(lex, "bhalo")
  lex.highlight("ভালো", candidate: "ভালো", for: "bhalo")
  #expect(lex.remembered("bhalo") == "ভালো")
  _ = typed(lex, "bhalor")
  #expect(lex.remembered("bhalor") == "ভালোর")    // a word with a suffix follows the pick for its base
  lex.save()
  #expect(try Lexicon(resources: resources, weightURL: file).remembered("bhalo") == "ভালো")   // survives restart
  lex.clearLearned()
  #expect(lex.remembered("bhalo") == nil)
  #expect(try Lexicon(resources: resources, weightURL: file).remembered("bhalo") == nil)    // not re-imported
}

@Test func customWordsJoinTheDictionary() throws {
  #expect(Lexicon.parseUserWords("# note\n  তোমাকে \n\nকাল\r\n") == ["তোমাকে", "কাল"])
  let word = "\u{09B0}\u{09BE}\u{09AB}\u{09C0}\u{09DF}\u{09BE}"   // রাফীয়া with the single-character য়
  #expect(!typed(try Lexicon(resources: resources), "rafiya").contains(word))
  let file = temp("txt")
  defer { try? FileManager.default.removeItem(at: file) }
  try "# mine\n\u{09B0}\u{09BE}\u{09AB}\u{09C0}\u{09AF}\u{09BC}\u{09BE}\n".write(to: file, atomically: true, encoding: .utf8)  // য + ়
  #expect(typed(try Lexicon(resources: resources, userWordsURL: file), "rafiya").contains { same($0, word) })
}

@Test func levenshteinLikeIAvro() {
  #expect(Lexicon.levenshtein("ভাল", "ভালো") == 1)
  #expect(Lexicon.levenshtein("", "ভাল") == -1)   // NSString+Levenshtein: empty is an error
}
