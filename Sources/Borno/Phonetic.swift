import Foundation

/// Avro Phonetic transliteration (roman -> Bangla). Rules follow the Avro Keyboard 5.6 phonetic guide.
/// Pure function, no state between calls.
enum Phonetic {
  private enum Rule {
    case vowel(ind: String, kar: String)
    case cons(String)    // one consonant
    case conj(String)    // consonants (one scalar each) joined by hasanta
    case sign(String)    // ং ঃ ঁ ৎ hasanta: output as is, next vowel is independent
    case lit(String)     // digit or punctuation: output as is
    case special         // y Y Z w r rr aZ `: context rules in `transliterate`
  }

  private enum Ctx { case none, cons, vowel, inherent, sign }

  private static let hasanta = "\u{09CD}"
  private static let nukta = "\u{09BC}"

  // Roman -> rule. Longest key wins, so "kkh" beats "kk" beats "k".
  private static let table: [String: Rule] = {
    var t: [String: Rule] = [:]
    func add(_ keys: String, _ rule: Rule) { for k in keys.split(separator: " ") { t[String(k)] = rule } }

    add("o", .vowel(ind: "অ", kar: ""))
    add("a aa", .vowel(ind: "আ", kar: "া"))
    add("i", .vowel(ind: "ই", kar: "ি"))
    add("I ee", .vowel(ind: "ঈ", kar: "ী"))
    add("u oo", .vowel(ind: "উ", kar: "ু"))
    add("U", .vowel(ind: "ঊ", kar: "ূ"))
    add("rri", .vowel(ind: "ঋ", kar: "ৃ"))
    add("e", .vowel(ind: "এ", kar: "ে"))
    add("OI", .vowel(ind: "ঐ", kar: "ৈ"))
    add("O", .vowel(ind: "ও", kar: "ো"))
    add("OU", .vowel(ind: "ঔ", kar: "ৌ"))

    for (k, v) in [
      ("k", "ক"), ("q", "ক"), ("kh", "খ"), ("g", "গ"), ("gh", "ঘ"), ("Ng", "ঙ"), ("c", "চ"), ("ch", "ছ"),
      ("j", "জ"), ("jh", "ঝ"), ("NG", "ঞ"), ("T", "ট"), ("Th", "ঠ"), ("D", "ড"), ("Dh", "ঢ"), ("N", "ণ"),
      ("t", "ত"), ("th", "থ"), ("d", "দ"), ("dh", "ধ"), ("n", "ন"), ("p", "প"), ("ph", "ফ"), ("f", "ফ"),
      ("b", "ব"), ("bh", "ভ"), ("v", "ভ"), ("m", "ম"), ("z", "য"), ("l", "ল"), ("sh", "শ"), ("S", "শ"),
      ("Sh", "ষ"), ("s", "স"), ("h", "হ"), ("R", "ড" + nukta), ("Rh", "ঢ" + nukta), ("J", "জ" + nukta),
    ] { t[k] = .cons(v) }

    for k in ["y", "Y", "w", "r", "rr", "Z", "aZ", "`"] { t[k] = .special }

    for (k, v) in [("ng", "ং"), (":", "ঃ"), ("^", "ঁ"), ("t``", "ৎ"), (",,", hasanta + "\u{200C}")] { t[k] = .sign(v) }
    for (k, v) in [(".", "।"), (".`", "."), (":`", ":"), ("$", "৳")] { t[k] = .lit(v) }
    for (i, d) in "০১২৩৪৫৬৭৮৯".enumerated() { t[String(i)] = .lit(String(d)) }

    // Conjuncts from the guide's table: Bangla consonants (joined by hasanta) = roman spellings.
    // ফলা (y Z w r after a consonant) come from context, not from here.
    for entry in """
      কক=kk কট=kT কত=kt কম=km কল=kl কষ=kkh,kx কষণ=kkhN কষম=kkhm কস=ks,x
      গণ=gN গধ=gdh গন=gn গম=gm গল=gl ঘন=ghn
      ঙক=nk,Ngk ঙকষ=Ngkkh,Ngkx ঙখ=Ngkh ঙগ=Ngg ঙঘ=Nggh ঙম=Ngm
      চচ=cc চছ=cch চঞ=cNG জজ=jj জঝ=jjh জঞ=gg,jNG
      ঞচ=nc,NGc ঞছ=nch,NGch ঞজ=nj,NGj ঞঝ=njh,NGjh
      টট=TT টম=Tm ডড=DD ণট=NT ণঠ=NTh ণড=ND ণঢ=NDh ণণ=Nn ণম=Nm
      তত=tt তথ=tth তন=tn তম=tm দগ=dg দঘ=dgh দদ=dd দধ=ddh দভ=dv,dbh দম=dm ধন=dhn ধম=dhm
      নট=nT নঠ=nTh নড=nD নত=nt নথ=nth নদ=nd নধ=ndh নন=nn নম=nm নস=ns
      পট=pT পত=pt পন=pn পপ=pp পল=pl পস=ps ফল=fl,phl
      বজ=bj বদ=bd বধ=bdh বব=bb বল=bl ভল=vl,bhl
      মন=mn মপ=mp মফ=mf,mph মব=mb মভ=mv,mbh মম=mm মল=ml মথ=mth
      লক=lk লগ=lg লট=lT লড=lD লপ=lp লধ=ldh লব=lb,lw লভ=lv,lbh লম=lm লল=ll
      শচ=shc,Sc শছ=shch,Sch শত=sht,St শন=shn,Sn শম=shm,Sm শল=shl,Sl
      ষক=Shk ষট=ShT ষঠ=ShTh ষণ=ShN ষপ=Shp ষফ=Shph,Shf ষম=Shm
      সক=sk সখ=skh সট=sT সত=st সথ=sth সন=sn সপ=sp সফ=sf,sph সম=sm সল=sl সকল=skl
      হণ=hN হন=hn হম=hm হল=hl
      """.split(whereSeparator: \.isWhitespace) {
      let p = entry.split(separator: "=")
      let joined = p[0].map(String.init).joined(separator: hasanta)
      for k in p[1].split(separator: ",") { t[String(k)] = .conj(joined) }
    }
    return t
  }()

  private static let maxKey = table.keys.map(\.count).max()!

  static func transliterate(_ input: String) -> String {
    let s = Array(input)
    var out = ""
    var ctx = Ctx.none
    var i = 0

    func match(_ at: Int) -> (key: String, rule: Rule)? {
      for len in stride(from: min(maxKey, s.count - at), through: 1, by: -1) {
        let k = String(s[at..<at + len])
        if let r = table[k] { return (k, r) }
      }
      return nil
    }

    var afterAccent = false
    while i < s.count {
      guard let (key, rule) = match(i) else { out.append(s[i]); i += 1; ctx = .none; afterAccent = false; continue }
      i += key.count
      let wasAccent = afterAccent
      afterAccent = false

      switch rule {
      case .vowel(let ind, let kar):
        if i < s.count, s[i] == "`" {  // vowel + ` forces the vowel sign
          i += 1
          out += kar
          ctx = kar.isEmpty ? .inherent : .vowel
        } else if ctx == .cons {
          out += kar
          ctx = kar.isEmpty ? .inherent : .vowel
        } else {
          out += (key == "a" || key == "aa") && ctx == .vowel ? "য়া" : ind  // samia -> সামিয়া
          ctx = .vowel
        }
      case .cons(let v): out += v; ctx = .cons
      case .conj(let v): out += v; ctx = .cons
      case .sign(let v): out += v; ctx = .sign
      case .lit(let v):
        // "." between digits stays a dot (3.5); elsewhere it is the danda ।
        let afterDigit = out.unicodeScalars.last.map { (0x09E6...0x09EF).contains($0.value) } ?? false
        let beforeDigit = i < s.count && s[i].isASCII && s[i].isNumber
        out += key == "." && afterDigit && beforeDigit ? "." : v
        ctx = .none
      case .special:
        switch key {
        case "`": ctx = .none; afterAccent = true
        case "y":
          if ctx == .cons { out += hasanta + "য" }
          else { out += ctx == .none && !wasAccent ? "ইয়" : "য়" }  // yahoo -> ইয়াহু, niyom -> নিয়ম
          ctx = .cons
        case "Y": out += "য়"; ctx = .cons
        case "Z": out += hasanta + "য"; ctx = .cons
        case "w":
          if ctx == .cons { out += hasanta + "ব" } else { out += "ও"; ctx = .vowel }
        case "r":
          out += ctx == .cons ? hasanta + "র" : "র"
          ctx = .cons
        case "rr":  // reph before a consonant: arrtonad -> আর্তনাদ
          var reph = false
          switch match(i)?.rule { case .cons?, .conj?: reph = true; default: break }
          out += reph ? "র" + hasanta : "রর"
          ctx = reph ? .sign : .cons
        default:  // "aZ": aZDmin -> অ্যাডমিন, baZk -> ব্যাক
          out += ctx == .cons ? hasanta + "যা" : "অ" + hasanta + "যা"
          ctx = .vowel
        }
      }
    }
    return out
  }
}
