import Foundation
import Testing

@testable import Borno

@Test func phoneticRules() {
  let cases: [(String, String)] = [
    ("amar", "আমার"), ("bangla", "বাংলা"), ("bangladesh", "বাংলাদেশ"), ("bhalo", "ভাল"), ("tOmake", "তোমাকে"),
    ("kintu", "কিন্তু"), ("bondhu", "বন্ধু"), ("prosonno", "প্রসন্ন"), ("bybohar", "ব্যবহার"), ("niyom", "নিয়ম"),
    ("okkhor", "অক্ষর"), ("brahmoN", "ব্রাহ্মণ"), ("arrtonad", "আর্তনাদ"), ("podma", "পদ্মা"), ("bishwo", "বিশ্ব"),
    ("aZDmin", "অ্যাডমিন"), ("baZk", "ব্যাক"), ("samia", "সামিয়া"), ("yahoo", "ইয়াহু"), ("ek`i", "একই"),
    ("ag`lanO", "আগলানো"), ("am`ra", "আমরা"), ("grriho", "গৃহ"), ("kOI", "কৈ"), ("dUr", "দূর"), ("kI", "কী"),
    ("boojhi", "বুঝি"), ("biggo", "বিজ্ঞ"), ("Igol", "ঈগল"), ("OtoprOto", "ওতপ্রোত"), ("hoy", "হয়"), ("koi", "কই"),
    ("tumi.", "তুমি।"), ("3.5", "৩.৫"), ("2024", "২০২৪"), ("$", "৳"), ("t``", "ৎ"), ("ca^d", "চাঁদ"),
    ("du:kho", "দুঃখ"), ("ami tumi", "আমি তুমি"), ("baRi", "বাড়ি"),
  ]
  for (roman, bangla) in cases { #expect(Phonetic.transliterate(roman) == bangla, "\(roman)") }
}

private func realLexicon(learnedURL: URL? = nil) throws -> Lexicon {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let data = try Data(contentsOf: root.appendingPathComponent("Resources/borno/words.txt"))
  let lex = Lexicon(learnedURL: learnedURL)
  lex.load(words: data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) })
  return lex
}

@Test func dictionarySuggestionsFixLooseSpelling() throws {
  let lex = try realLexicon()
  #expect(lex.suggest("tomake").contains("তোমাকে"))
  #expect(lex.suggest("bari").contains("বাড়ি"))
  #expect(lex.suggest("bhalo").first == "ভাল")          // literal phonetic result stays first
  #expect(lex.suggest("bhalo").contains("ভালো"))
  #expect(lex.suggest("bangla").first == "বাংলা")
  #expect(lex.suggest("bhalobasha").contains("ভালোবাসা"))
  #expect(lex.suggest("bhalob", limit: 50).contains("ভালোবাসা"))   // completion while still typing
}

@Test func autocorrectAndLearning() throws {
  let lex = Lexicon()
  lex.load(words: [], autocorrect: ["academy": "oZakaDemi"])
  #expect(lex.suggest("academy").first == Phonetic.transliterate("oZakaDemi"))

  let file = FileManager.default.temporaryDirectory.appendingPathComponent("borno-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: file) }
  let a = try realLexicon(learnedURL: file)
  a.learn("bhalo", "ভালো")
  #expect(a.suggest("bhalo").first == "ভালো")
  #expect(Lexicon(learnedURL: file).suggest("bhalo").first == "ভালো")  // survives restart
}
