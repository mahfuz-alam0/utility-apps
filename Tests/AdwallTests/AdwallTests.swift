import Foundation
import Testing

@testable import Adwall

@Test func parsesHostsPlainWildcardAndAdblockFormats() {
  let rules = parseRules(
    [
      "# comment",
      "127.0.0.1 localhost",
      "0.0.0.0 ads.example.com tracker.example.net # inline",
      "plain.example.org",
      "*.wild.example.org",
      "||adblock.example.com^",
      "||withmod.example.com^$third-party",
      "@@||allowed.example.com^",
      "example.com##.banner",
      "0.0.0.0 0.0.0.0"
    ].joined(separator: "\n"))
  #expect(rules.block.sorted() == ["adblock.example.com", "ads.example.com", "plain.example.org", "tracker.example.net", "wild.example.org"])
  #expect(rules.allow == ["allowed.example.com"])
}

@Test func matchesSubdomainsNeverBareTldsAndAllowWins() {
  let matcher = Matcher(block: ["tracker.com", "com"], allow: ["ok.tracker.com"])
  #expect(matcher.isBlocked("tracker.com"))
  #expect(matcher.isBlocked("a.b.tracker.com"))
  #expect(!matcher.isBlocked("ok.tracker.com"))
  #expect(!matcher.isBlocked("x.ok.tracker.com"))
  #expect(!matcher.isBlocked("other.com"))
  #expect(!matcher.isBlocked("localhost"))
}

@Test func restoreScriptQuotesAwkwardServiceNamesAndRestoresEmptyLists() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adwall-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let stub = dir.appendingPathComponent("networksetup").path
  try "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done; echo\n".write(toFile: stub, atomically: true, encoding: .utf8)
  chmod(stub, 0o755)
  let script = dir.appendingPathComponent("restore.sh").path
  try restoreScript(
    ["John's iPhone USB": ["1.1.1.1", "8.8.8.8"], "Wi-Fi": [], "USB 10/100/1000 LAN": ["9.9.9.9"]], networksetup: stub
  ).write(toFile: script, atomically: true, encoding: .utf8)

  let output = try runProcess("/bin/sh", [script]).split(separator: "\n").map(String.init)
  #expect(output == [
    "[-setdnsservers][John's iPhone USB][1.1.1.1][8.8.8.8]",
    "[-setdnsservers][USB 10/100/1000 LAN][9.9.9.9]",
    "[-setdnsservers][Wi-Fi][Empty]"
  ])
}

@Test func runScriptIsValidShAndQuotesTheAppPath() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString).sh").path
  let script = runScript(app: "/Applications/Ad's Wall.app/Contents/MacOS/Adwall")
  try script.write(toFile: file, atomically: true, encoding: .utf8)
  try runProcess("/bin/sh", ["-n", file])
  #expect(script.contains("APP='/Applications/Ad'\\''s Wall.app/Contents/MacOS/Adwall'"))
  #expect(script.hasSuffix("exec '/Library/Application Support/Adwall/adwalld' serve\n"))
}

@Test func launchdPlistParsesAndRunsTheWrapperScriptAtLoad() throws {
  let parsed = try PropertyListSerialization.propertyList(from: Data(launchdPlist().utf8), format: nil) as? [String: Any]
  #expect(parsed?["Label"] as? String == "com.adwall.daemon")
  #expect(parsed?["ProgramArguments"] as? [String] == ["/bin/sh", "/Library/Application Support/Adwall/run.sh"])
  #expect(parsed?["RunAtLoad"] as? Bool == true)
  #expect(parsed?["KeepAlive"] as? Bool == true)
}

// MARK: DNS end to end

private let proxyPort: UInt16 = 25353
private let upstreamPort: UInt16 = 25354

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func bump() { lock.lock(); value += 1; lock.unlock() }
  var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Answers every A query with 93.184.216.34, ttl 60.
private func startFakeUpstream(hits: Counter) -> Int32 {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  var addr = inetAddress("127.0.0.1", upstreamPort)
  precondition(withSockAddr(&addr) { bind(fd, $0, $1) } == 0)
  Thread.detachNewThread {
    var buffer = Packet(repeating: 0, count: 4096)
    let capacity = buffer.count
    while true {
      var from = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let n = withUnsafeMutablePointer(to: &from) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, capacity, 0, $0, &length) }
      }
      if n < 0 { return }
      hits.bump()
      let query = DnsQuery(Array(buffer[0..<n]))!
      let question = buildQuery(query.name, id: query.id, edns: false).dropFirst(12)
      let header: Packet = [UInt8(query.id >> 8), UInt8(query.id & 0xFF), 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
      let answer: Packet = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
      let response = header + question + answer
      _ = withSockAddr(&from) { address, size in response.withUnsafeBytes { sendto(fd, $0.baseAddress, response.count, 0, address, size) } }
    }
  }
  return fd
}

private func askUdp(_ query: Packet) -> Packet {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  defer { close(fd) }
  setTimeouts(fd, seconds: 3)
  var addr = inetAddress("127.0.0.1", proxyPort)
  _ = withSockAddr(&addr) { sendto(fd, query, query.count, 0, $0, $1) }
  var buffer = Packet(repeating: 0, count: 4096)
  let n = recv(fd, &buffer, buffer.count, 0)
  return n > 0 ? Array(buffer[0..<n]) : []
}

private func askTcp(_ query: Packet) -> Packet {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  setTimeouts(fd, seconds: 3)
  var addr = inetAddress("127.0.0.1", proxyPort)
  guard withSockAddr(&addr, { connect(fd, $0, $1) }) == 0 else { return [] }
  let frame = [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query
  _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, frame.count) }
  var buffer = Packet(repeating: 0, count: 4096)
  let n = recv(fd, &buffer, buffer.count, 0)
  return n > 2 ? Array(buffer[2..<n]) : []
}

private func rcode(_ response: Packet) -> Int { Int(response[3] & 0xF) }
private func answerCount(_ response: Packet) -> Int { Int(response[6]) << 8 | Int(response[7]) }
private func id(_ response: Packet) -> Int { Int(response[0]) << 8 | Int(response[1]) }

@Test func dnsProxyBlocksForwardsCachesAndSpeaksTcp() async throws {
  let hits = Counter()
  let upstream = startFakeUpstream(hits: hits)
  defer { close(upstream) }

  let service = DnsService(upstreams: Upstreams(["127.0.0.1:\(upstreamPort)"]))
  await service.setMatcher(Matcher(block: ["ads.example.com", "tracker.net"], allow: ["safe.tracker.net"]))
  let listener = DnsListener(service: service)
  try await listener.start(host: "127.0.0.1", port: proxyPort)
  defer { listener.stop() }

  // blocked names and subdomains get NXDOMAIN without touching upstream
  var before = hits.count
  let direct = askUdp(buildQuery("ads.example.com"))
  let nested = askUdp(buildQuery("x.y.tracker.net", type: 28))
  #expect(rcode(direct) == 3)
  #expect(id(direct) == 7)
  #expect(rcode(nested) == 3)
  #expect(hits.count == before)

  // allowed names are forwarded once, then served from cache with the new query id
  before = hits.count
  let first = askUdp(buildQuery("example.org", id: 11))
  let second = askUdp(buildQuery("example.org", id: 12))
  #expect(rcode(first) == 0 && answerCount(first) == 1)
  #expect(id(second) == 12 && answerCount(second) == 1)
  #expect(hits.count == before + 1)

  // allowlist beats a blocked parent
  #expect(answerCount(askUdp(buildQuery("safe.tracker.net"))) == 1)

  // tcp is filtered and forwarded too
  #expect(rcode(askTcp(buildQuery("ads.example.com"))) == 3)
  #expect(answerCount(askTcp(buildQuery("tcp.example.org"))) == 1)

  // pausing disables blocking; the health name is always answered locally
  await service.setEnabled(false)
  #expect(answerCount(askUdp(buildQuery("ads.example.com"))) == 1)
  await service.setEnabled(true)
  before = hits.count
  #expect(rcode(askUdp(buildQuery(healthName))) == 3)
  #expect(hits.count == before)

  let stats = await service.stats
  #expect(stats.blocked >= 3)
  #expect(stats.cacheHits >= 1)
  #expect(await service.recent.contains("ads.example.com"))
}

@Test func configKeepsBrokenFileAndClampsInterval() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adwall-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("config.json").path

  try "{ not json".write(toFile: file, atomically: true, encoding: .utf8)
  #expect(Config.load(file).lists.count == 2)
  #expect(try String(contentsOfFile: file, encoding: .utf8) == "{ not json")

  try #"{"updateIntervalHours": 0}"#.write(toFile: file, atomically: true, encoding: .utf8)
  #expect(Config.load(file).updateIntervalHours == 1)
  try #"{"updateIntervalHours": 1e12}"#.write(toFile: file, atomically: true, encoding: .utf8)
  #expect(Config.load(file).updateIntervalHours == 8760)

  let fresh = dir.appendingPathComponent("fresh.json").path
  _ = Config.load(fresh)
  #expect(FileManager.default.fileExists(atPath: fresh))
}
