import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

func serve() {
  setvbuf(stdout, nil, _IOLBF, 0)
  let env = ProcessInfo.processInfo.environment
  let dir = env["ADWALL_DIR"] ?? Paths.dir
  let host = env["ADWALL_HOST"] ?? "127.0.0.1"
  let port = UInt16(env["ADWALL_PORT"] ?? "") ?? 53
  let socketPath = env["ADWALL_SOCK"] ?? Paths.socket

  let fm = FileManager.default
  for sub in ["lists", "rules"] { try? fm.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true) }
  for name in ["allowlist.txt", "blocklist.txt"] where !fm.fileExists(atPath: "\(dir)/rules/\(name)") {
    fm.createFile(atPath: "\(dir)/rules/\(name)", contents: Data("# one domain per line\n".utf8), attributes: [.posixPermissions: 0o664])
  }

  let config = Config.load("\(dir)/config.json")
  let service = DnsService(upstreams: Upstreams(config.upstreams))
  let engine = Engine(service: service, config: config, dir: dir)
  let listener = DnsListener(service: service)

  Task {
    do {
      try await listener.start(host: host, port: port)
      log("dns listening on \(host):\(port)")
      await engine.rebuild()
      _ = try ControlServer(path: socketPath) { try await engine.handle($0) }
    } catch {
      fail("fatal: \(error.localizedDescription)")
    }
    await engine.requestUpdate()
    Task {
      // ponytail: polls rule-file mtimes every 2s instead of FSEvents, switch if that ever shows up in a profile
      while true {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await engine.rebuildIfEdited()
      }
    }
    while true {
      try? await Task.sleep(nanoseconds: UInt64(config.updateIntervalHours * 3_600_000_000_000))
      await engine.requestUpdate()
    }
  }

  for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
      listener.stop()
      unlink(socketPath)
      exit(0)
    }
    source.resume()
    signals.append(source)
  }
  dispatchMain()
}

var signals: [DispatchSourceSignal] = []
