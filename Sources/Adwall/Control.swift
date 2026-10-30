import Foundation

private func unixAddress(_ path: String) -> sockaddr_un {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
  return addr
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
  var sent = 0
  while sent < bytes.count {
    let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if n <= 0 { return }
    sent += n
  }
}

private func readAll(_ fd: Int32, stopAtNewline: Bool) -> [UInt8] {
  var data: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 1024)
  let capacity = chunk.count
  while data.count < 1 << 20 {
    let n = read(fd, &chunk, capacity)
    if n <= 0 { break }
    data += chunk[0..<n]
    if stopAtNewline && data.contains(10) { break }
  }
  return data
}

private struct ErrorReply: Codable {
  let error: String
}

/// Line protocol over a unix socket: one command line in, one JSON `Status` (or `{"error":…}`) out.
/// Commands: `status`, `pause`, `resume`, `update`, `allow <domain>`.
final class ControlServer {
  init(path: String, handler: @escaping (String) async throws -> Status) throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = unixAddress(path)
    guard fd >= 0, withSockAddr(&addr, { bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
      throw AdwallError("cannot listen on \(path): \(String(cString: strerror(errno)))")
    }
    // Only root and the admin group may talk to the daemon.
    chmod(path, 0o660)
    chown(path, 0, adminGid)

    Thread.detachNewThread {
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        setTimeouts(client, seconds: 2)
        let command = String(decoding: readAll(client, stopAtNewline: true), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
          let encoder = JSONEncoder()
          let reply: Data
          do {
            reply = try encoder.encode(try await handler(command))
          } catch {
            reply = (try? encoder.encode(ErrorReply(error: error.localizedDescription))) ?? Data()
          }
          writeAll(client, Array(reply) + [10])
          close(client)
        }
      }
    }
  }
}

enum Control {
  static func send(_ command: String, path: String = Paths.socket) throws -> Status {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AdwallError("socket failed") }
    defer { close(fd) }
    setTimeouts(fd, seconds: 3)
    var addr = unixAddress(path)
    guard withSockAddr(&addr, { connect(fd, $0, $1) }) == 0 else { throw AdwallError("daemon not reachable") }
    writeAll(fd, Array((command + "\n").utf8))
    let reply = Data(readAll(fd, stopAtNewline: false))
    if let status = try? JSONDecoder().decode(Status.self, from: reply) { return status }
    throw AdwallError((try? JSONDecoder().decode(ErrorReply.self, from: reply))?.error ?? "bad reply")
  }
}
