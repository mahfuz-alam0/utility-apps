import Foundation

struct ParsedRules {
  var block = Set<String>()
  var allow = Set<String>()
  init() {}
}

private let hostIPs: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1", "0"]

/// Lowercase hostname with at least two labels and an alphabetic TLD.
func isDomain(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard !bytes.isEmpty, bytes.count <= 253 else { return false }
  let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
  guard labels.count >= 2 else { return false }

  func alnum(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
  for (index, label) in labels.enumerated() {
    let isTld = index == labels.count - 1
    guard (1...63).contains(label.count), let first = label.first, let last = label.last else { return false }
    if isTld {
      guard label.count >= 2, first >= 97, first <= 122, alnum(last) else { return false }
      guard label.allSatisfy({ alnum($0) || $0 == UInt8(ascii: "-") }) else { return false }
    } else {
      let edge = { (c: UInt8) in alnum(c) || c == UInt8(ascii: "_") }
      guard edge(first), edge(last) else { return false }
      guard label.allSatisfy({ edge($0) || $0 == UInt8(ascii: "-") }) else { return false }
    }
  }
  return true
}

private func trim(_ s: Substring) -> Substring {
  var s = s
  while let c = s.first, c.isWhitespace { s.removeFirst() }
  while let c = s.last, c.isWhitespace { s.removeLast() }
  return s
}

private func isCosmetic(_ line: String) -> Bool {
  guard line.contains("#") else { return false }
  return ["##", "#@#", "#?#", "#$#", "#%#"].contains { line.contains($0) }
}

/// `||domain^` or `||domain^$important`, optionally prefixed with `@@`.
private func parseAdblock(_ line: String) -> (allow: Bool, domain: String)? {
  var rest = Substring(line)
  var allow = false
  if rest.hasPrefix("@@") {
    allow = true
    rest = rest.dropFirst(2)
  }
  guard rest.hasPrefix("||") else { return nil }
  rest = rest.dropFirst(2)
  guard let caret = rest.firstIndex(of: "^") else { return nil }
  let domain = rest[..<caret]
  let tail = rest[rest.index(after: caret)...]
  guard !domain.isEmpty, domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
  guard tail.isEmpty || tail.lowercased() == "$important" else { return nil }
  return (allow, domain.lowercased())
}

/// Reads hosts, plain-domain, wildcard and adblock (`||domain^`) lines.
func parseRules(_ text: String, into rules: inout ParsedRules) {
  for raw in text.utf8.split(separator: UInt8(ascii: "\n")) {
    var line = trim(Substring(String(decoding: raw, as: UTF8.self)))
    guard let first = line.first, first != "#", first != "!", first != "[" else { continue }
    if isCosmetic(String(line)) { continue }

    if let (allow, domain) = parseAdblock(String(line)) {
      if isDomain(domain) { if allow { rules.allow.insert(domain) } else { rules.block.insert(domain) } }
      continue
    }

    if let hash = line.firstIndex(of: "#") { line = trim(line[..<hash]) }
    if line.isEmpty { continue }

    let parts = line.split(whereSeparator: \.isWhitespace)
    var domains: [Substring]
    if parts.count > 1, hostIPs.contains(String(parts[0])) {
      domains = Array(parts.dropFirst())
    } else if parts.count == 1 {
      domains = [parts[0].hasPrefix("*.") ? parts[0].dropFirst(2) : parts[0]]
    } else {
      continue
    }

    for entry in domains {
      var domain = entry.lowercased()
      if domain.hasSuffix(".") { domain.removeLast() }
      if isDomain(domain) { rules.block.insert(domain) }
    }
  }
}

func parseRules(_ text: String) -> ParsedRules {
  var rules = ParsedRules()
  parseRules(text, into: &rules)
  return rules
}

struct Matcher {
  let block: Set<String>
  let allow: Set<String>

  static let empty = Matcher(block: [], allow: [])

  init(block: Set<String>, allow: Set<String>) {
    self.block = block
    self.allow = allow
  }

  var size: Int { block.count }

  /// Blocks a name or any subdomain of it; an allow entry on the way up wins. Bare TLDs are never checked.
  func isBlocked(_ name: String) -> Bool {
    var blocked = false
    var candidate = Substring(name)
    while let dot = candidate.firstIndex(of: ".") {
      let key = String(candidate)
      if allow.contains(key) { return false }
      if block.contains(key) { blocked = true }
      candidate = candidate[candidate.index(after: dot)...]
    }
    return blocked
  }
}
