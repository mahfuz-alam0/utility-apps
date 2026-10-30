import Foundation

let healthName = "health.adwall.test"
let adminGid: gid_t = 80

enum Paths {
  static let dir = "/Library/Application Support/Adwall"
  static let rulesDir = dir + "/rules"
  static let listsDir = dir + "/lists"
  static let backup = dir + "/dns-backup.json"
  static let restoreScript = dir + "/restore-dns.sh"
  static let runScript = dir + "/run.sh"
  static let daemon = dir + "/adwalld"
  static let plist = "/Library/LaunchDaemons/com.adwall.daemon.plist"
  static let label = "com.adwall.daemon"
  static let socket = "/var/run/adwall.sock"
  static let log = "/var/log/adwall.log"
}

struct DnsStats: Codable {
  var total = 0
  var blocked = 0
  var cacheHits = 0
  var startedAt = Date().timeIntervalSince1970
  init() {}
}

struct Status: Codable {
  var enabled: Bool
  var ruleCount: Int
  var updating: Bool
  var stats: DnsStats
  var recent: [String]

  init(enabled: Bool, ruleCount: Int, updating: Bool, stats: DnsStats, recent: [String]) {
    self.enabled = enabled
    self.ruleCount = ruleCount
    self.updating = updating
    self.stats = stats
    self.recent = recent
  }
}

struct AdwallError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Runs a command to completion; throws with its stderr on non-zero exit.
@discardableResult
func runProcess(_ path: String, _ args: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args
  let out = Pipe()
  let err = Pipe()
  process.standardOutput = out
  process.standardError = err
  try process.run()
  let stdout = out.fileHandleForReading.readDataToEndOfFile()
  let stderr = err.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw AdwallError(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }
  return String(decoding: stdout, as: UTF8.self)
}

func flushSystemDns() {
  for (command, args) in [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }
}

func withSockAddr<T, R>(_ addr: inout T, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
  withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<T>.size)) }
  }
}

func inetAddress(_ host: String, _ port: UInt16) -> sockaddr_in {
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  inet_pton(AF_INET, host, &addr.sin_addr)
  return addr
}

func setTimeouts(_ fd: Int32, seconds: Int) {
  var tv = timeval(tv_sec: seconds, tv_usec: 0)
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Thread-safe one-shot latch: `claim()` is true only for the first caller.
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false

  var isClaimed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return fired
  }

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if fired { return false }
    fired = true
    return true
  }
}
