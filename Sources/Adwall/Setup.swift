import Foundation

// Runs as root (via the app's administrator prompt): installs/removes the launch daemon and flips system DNS.

private let localDns = "127.0.0.1"

private func listServices() throws -> [String] {
  try runProcess("/usr/sbin/networksetup", ["-listallnetworkservices"])
    .split(separator: "\n").dropFirst()
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("*") }
}

private func getDns(_ service: String) throws -> [String] {
  let output = try runProcess("/usr/sbin/networksetup", ["-getdnsservers", service])
  if output.contains("aren't any") { return [] }
  return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func setDns(_ service: String, _ servers: [String]) throws {
  try runProcess("/usr/sbin/networksetup", ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers))
}

private func readBackup() -> Backup {
  guard let data = FileManager.default.contents(atPath: Paths.backup) else { return [:] }
  return (try? JSONDecoder().decode(Backup.self, from: data)) ?? [:]
}

private func writeFile(_ text: String, to path: String, mode: mode_t, gid: gid_t = 0) throws {
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  chmod(path, mode)
  chown(path, 0, gid)
}

/// True once the daemon answers the health name on 127.0.0.1:53.
private func probe() -> Bool {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  var tv = timeval(tv_sec: 1, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  var addr = inetAddress(localDns, 53)
  let query = buildQuery(healthName, id: 1, edns: false)
  let sent = withSockAddr(&addr) { sendto(fd, query, query.count, 0, $0, $1) }
  guard sent == query.count else { return false }
  var buffer = [UInt8](repeating: 0, count: 512)
  return recv(fd, &buffer, buffer.count, 0) > 0
}

private func waitForDaemon() -> Bool {
  for _ in 0..<20 {
    if probe() { return true }
    Thread.sleep(forTimeInterval: 0.5)
  }
  return false
}

private func prepareFiles() throws {
  let fm = FileManager.default
  try fm.createDirectory(atPath: Paths.rulesDir, withIntermediateDirectories: true)
  chmod(Paths.dir, 0o755)
  chmod(Paths.rulesDir, 0o775)
  chown(Paths.rulesDir, 0, adminGid)
  for name in ["allowlist.txt", "blocklist.txt"] {
    let file = "\(Paths.rulesDir)/\(name)"
    if !fm.fileExists(atPath: file) { try "# one domain per line\n".write(toFile: file, atomically: true, encoding: .utf8) }
    chmod(file, 0o664)
    chown(file, 0, adminGid)
  }

  let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  try? fm.removeItem(atPath: Paths.daemon)
  try fm.copyItem(at: source, to: URL(fileURLWithPath: Paths.daemon))
  chmod(Paths.daemon, 0o755)
  chown(Paths.daemon, 0, 0)

  // run.sh restores DNS and removes the daemon if the app binary it was installed from is gone.
  try writeFile(runScript(app: source.path), to: Paths.runScript, mode: 0o755)
  try writeFile(launchdPlist(), to: Paths.plist, mode: 0o644)
}

private func startDaemon() throws {
  _ = try? runProcess("/bin/launchctl", ["bootout", "system/\(Paths.label)"])
  do {
    try runProcess("/bin/launchctl", ["bootstrap", "system", Paths.plist])
  } catch {
    Thread.sleep(forTimeInterval: 1)
    try runProcess("/bin/launchctl", ["bootstrap", "system", Paths.plist])
  }
}

private func switchDns() throws {
  var backup = readBackup()
  let services = try listServices()
  for service in services where backup[service] == nil {
    let current = try getDns(service)
    backup[service] = current == [localDns] ? [] : current
  }
  try JSONEncoder().encode(backup).write(to: URL(fileURLWithPath: Paths.backup))
  try writeFile(restoreScript(backup), to: Paths.restoreScript, mode: 0o755)
  for service in services { try setDns(service, [localDns]) }
}

private func restoreDns() {
  let backup = readBackup()
  for (service, servers) in backup { try? setDns(service, servers) }
  for service in (try? listServices()) ?? [] where backup[service] == nil {
    if (try? getDns(service)) == [localDns] { try? setDns(service, []) }
  }
}

func install() throws {
  try prepareFiles()
  try startDaemon()
  guard waitForDaemon() else {
    uninstall()
    throw AdwallError("The blocking service did not start. See \(Paths.log) for details.")
  }
  try switchDns()
  flushSystemDns()
}

func uninstall() {
  restoreDns()
  _ = try? runProcess("/bin/launchctl", ["bootout", "system/\(Paths.label)"])
  for file in [Paths.plist, Paths.runScript, Paths.restoreScript, Paths.daemon, Paths.backup, Paths.socket, Paths.listsDir] {
    try? FileManager.default.removeItem(atPath: file)
  }
  flushSystemDns()
}
