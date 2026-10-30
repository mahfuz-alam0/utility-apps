import Foundation

func log(_ message: String) {
  print(ISO8601DateFormatter().string(from: Date()), message)
}

/// Owns rules, list updates and the control-socket commands for the running daemon.
actor Engine {
  let service: DnsService
  private let config: Config
  private let listsDir: String
  private let allowlist: String
  private let blocklist: String
  private var updating = false
  private var rulesStamp: [Date?] = []

  init(service: DnsService, config: Config, dir: String) {
    self.service = service
    self.config = config
    listsDir = dir + "/lists"
    allowlist = dir + "/rules/allowlist.txt"
    blocklist = dir + "/rules/blocklist.txt"
  }

  private func readText(_ file: String) -> String {
    (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
  }

  private func stamp() -> [Date?] {
    [allowlist, blocklist].map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
  }

  func rebuild() async {
    rulesStamp = stamp()
    var rules = ParsedRules()
    for list in config.lists where list.enabled { parseRules(readList(list, in: listsDir), into: &rules) }
    parseRules(readText(blocklist), into: &rules)
    rules.allow.formUnion(parseRules(readText(allowlist)).block)
    await service.setMatcher(Matcher(block: rules.block, allow: rules.allow))
    log("rules loaded: \(rules.block.count) blocked, \(rules.allow.count) allowed")
  }

  /// Rebuilds when the user edited the rule files by hand.
  func rebuildIfEdited() async {
    if stamp() != rulesStamp { await rebuild() }
  }

  func requestUpdate() {
    guard !updating else { return }
    updating = true
    Task { await runUpdate() }
  }

  private func runUpdate() async {
    defer { updating = false }
    var changed = false
    for list in config.lists where list.enabled {
      do {
        let count = try await downloadList(list, to: listsDir)
        changed = true
        log("updated \(list.name): \(count) domains")
      } catch {
        log("update failed: \(error.localizedDescription)")
      }
    }
    if changed { await rebuild() }
  }

  func allow(_ input: String) async throws {
    var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if domain.hasSuffix(".") { domain.removeLast() }
    guard isDomain(domain) else { throw AdwallError("invalid domain") }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: allowlist))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n\(domain)\n".utf8))
    try handle.close()
    await rebuild()
    flushSystemDns()
  }

  func setEnabled(_ enabled: Bool) async {
    await service.setEnabled(enabled)
    log(enabled ? "blocking resumed" : "blocking paused")
  }

  func status() async -> Status {
    Status(
      enabled: await service.enabled,
      ruleCount: await service.matcher.size,
      updating: updating,
      stats: await service.stats,
      recent: Array(await service.recent.prefix(20)))
  }

  func handle(_ command: String) async throws -> Status {
    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "status": break
    case "pause": await setEnabled(false)
    case "resume": await setEnabled(true)
    case "update": requestUpdate()
    case "allow": try await allow(parts.count > 1 ? parts[1] : "")
    default: throw AdwallError("not found")
    }
    return await status()
  }
}
