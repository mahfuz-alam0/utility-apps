import Foundation

typealias Packet = [UInt8]

private func u16(_ b: Packet, _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
private func u32(_ b: Packet, _ i: Int) -> Int { u16(b, i) << 16 | u16(b, i + 2) }
private func put16(_ v: Int) -> Packet { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func put32(_ v: Int) -> Packet { put16(v >> 16 & 0xFFFF) + put16(v & 0xFFFF) }

private let flagQR = 0x8000
private let flagTC = 0x0200
private let flagRD = 0x0100
private let flagRA = 0x0080
private let rcodeServFail = 2
private let rcodeNXDomain = 3
private let typeSOA = 6
private let typeOPT = 41

private struct Record {
  let type: Int
  let cls: Int
  let ttl: Int
  let rdata: Range<Int>
}

private struct Message {
  let flags: Int
  let questions: Int
  let answers: [Record]
  let authorities: [Record]
  let additionals: [Record]
}

/// Offset just past the (possibly compressed) name at `start`.
private func skipName(_ b: Packet, _ start: Int) -> Int? {
  var i = start
  while i < b.count {
    let len = Int(b[i])
    if len == 0 { return i + 1 }
    if len & 0xC0 == 0xC0 { return i + 2 <= b.count ? i + 2 : nil }
    if len & 0xC0 != 0 { return nil }
    i += 1 + len
  }
  return nil
}

private func readRecords(_ b: Packet, _ start: Int, _ count: Int) -> ([Record], Int)? {
  var i = start
  var out: [Record] = []
  for _ in 0..<count {
    guard let p = skipName(b, i), p + 10 <= b.count else { return nil }
    let end = p + 10 + u16(b, p + 8)
    guard end <= b.count else { return nil }
    out.append(Record(type: u16(b, p), cls: u16(b, p + 2), ttl: u32(b, p + 4), rdata: (p + 10)..<end))
    i = end
  }
  return (out, i)
}

private func parse(_ b: Packet) -> Message? {
  guard b.count >= 12 else { return nil }
  var i = 12
  for _ in 0..<u16(b, 4) {
    guard let p = skipName(b, i), p + 4 <= b.count else { return nil }
    i = p + 4
  }
  guard let (answers, a) = readRecords(b, i, u16(b, 6)),
    let (authorities, n) = readRecords(b, a, u16(b, 8)),
    let (additionals, _) = readRecords(b, n, u16(b, 10))
  else { return nil }
  return Message(flags: u16(b, 2), questions: u16(b, 4), answers: answers, authorities: authorities, additionals: additionals)
}

private func encodeName(_ name: String) -> Packet {
  var out: Packet = []
  for label in name.split(separator: ".") {
    out.append(UInt8(label.utf8.count))
    out += Array(label.utf8)
  }
  return out + [0]
}

private func header(id: Int, flags: Int, questions: Int, authorities: Int, additionals: Int) -> Packet {
  put16(id) + put16(flags) + put16(questions) + put16(0) + put16(authorities) + put16(additionals)
}

struct DnsQuery {
  let id: Int
  let flags: Int
  /// Lowercased, without trailing dot.
  let name: String
  let type: Int
  let qclass: Int
  /// EDNS payload size, nil when the query has no OPT record.
  let udpSize: Int?
  let dnssecOK: Bool
  /// Raw first question (name, type, class), echoed in replies.
  fileprivate let question: Packet

  init?(_ b: Packet) {
    guard let message = parse(b), message.flags & flagQR == 0, message.questions > 0 else { return nil }
    var labels: [String] = []
    var i = 12
    while true {
      guard i < b.count else { return nil }
      let len = Int(b[i])
      if len == 0 { i += 1; break }
      guard len & 0xC0 == 0, i + 1 + len <= b.count else { return nil }
      labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
      i += 1 + len
    }
    guard i + 4 <= b.count else { return nil }
    let opt = message.additionals.first { $0.type == typeOPT }
    id = u16(b, 0)
    flags = message.flags
    name = labels.joined(separator: ".").lowercased()
    type = u16(b, i)
    qclass = u16(b, i + 2)
    udpSize = opt?.cls
    dnssecOK = (opt?.ttl ?? 0) & 0x8000 != 0
    question = Array(b[12..<(i + 4)])
  }
}

private func replyFlags(_ q: DnsQuery, rcode: Int) -> Int { flagQR | (q.flags & flagRD) | flagRA | rcode }

/// NXDOMAIN with a short-lived SOA so clients cache the block.
func negativeResponse(_ q: DnsQuery, ttl: Int = 120) -> Packet {
  var out = header(id: q.id, flags: replyFlags(q, rcode: rcodeNXDomain), questions: 1, authorities: 1, additionals: q.udpSize == nil ? 0 : 1)
  out += q.question
  let rdata = encodeName("adwall.local") + encodeName("hostmaster.adwall.local")
    + put32(1) + put32(3600) + put32(600) + put32(86400) + put32(ttl)
  out += [0xC0, 0x0C] + put16(typeSOA) + put16(1) + put32(ttl) + put16(rdata.count) + rdata
  if q.udpSize != nil { out += [0] + put16(typeOPT) + put16(1232) + put32(0) + put16(0) }
  return out
}

func servfailResponse(_ q: DnsQuery) -> Packet {
  header(id: q.id, flags: replyFlags(q, rcode: rcodeServFail), questions: 1, authorities: 0, additionals: 0) + q.question
}

func buildQuery(_ name: String, type: Int = 1, id: Int = 7, edns: Bool = true) -> Packet {
  var out = header(id: id, flags: flagRD, questions: 1, authorities: 0, additionals: edns ? 1 : 0)
  out += encodeName(name) + put16(type) + put16(1)
  if edns { out += [0] + put16(typeOPT) + put16(4096) + put32(0) + put16(0) }
  return out
}

/// Seconds a response may be cached, nil when it must not be (truncated, errors, malformed).
func cacheTTL(of response: Packet) -> Int? {
  guard response.count <= 1232, let m = parse(response), m.flags & flagTC == 0 else { return nil }
  let rcode = m.flags & 0xF
  guard rcode == 0 || rcode == rcodeNXDomain else { return nil }

  var ttl: Int
  if let lowest = m.answers.map(\.ttl).min() {
    ttl = lowest
  } else if let soa = m.authorities.first(where: { $0.type == typeSOA }), soa.rdata.count >= 4 {
    ttl = min(soa.ttl, u32(response, soa.rdata.upperBound - 4))
  } else {
    ttl = 30
  }
  return min(max(ttl, 5), 3600)
}
