import Foundation

/// Original DNS servers per network service, saved before pointing the Mac at Adwall.
typealias Backup = [String: [String]]

func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func restoreScript(_ backup: Backup, networksetup: String = "/usr/sbin/networksetup") -> String {
  let lines = backup.keys.sorted().map { service in
    let servers = backup[service] ?? []
    return "\(networksetup) -setdnsservers \(shellQuote(service)) \(servers.isEmpty ? "Empty" : servers.map(shellQuote).joined(separator: " "))"
  }
  return "#!/bin/sh\n" + lines.joined(separator: "\n") + "\n"
}

/// Launched by launchd. If the app was deleted, puts DNS back and removes the daemon instead of leaving DNS dangling.
func runScript(app: String) -> String {
  """
  #!/bin/sh
  APP=\(shellQuote(app))
  if [ ! -x "$APP" ]; then
    /bin/sh \(shellQuote(Paths.restoreScript))
    /bin/rm -f \(shellQuote(Paths.plist))
    /bin/launchctl bootout system/\(Paths.label)
    exit 0
  fi
  exec \(shellQuote(Paths.daemon)) serve

  """
}

func launchdPlist() -> String {
  let dict: [String: Any] = [
    "Label": Paths.label,
    "ProgramArguments": ["/bin/sh", Paths.runScript],
    "RunAtLoad": true,
    "KeepAlive": true,
    "ThrottleInterval": 5,
    "StandardOutPath": Paths.log,
    "StandardErrorPath": Paths.log
  ]
  let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
  return String(decoding: data, as: UTF8.self)
}
