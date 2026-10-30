import Foundation

private final class ByteBuffer: @unchecked Sendable {
  var bytes: Packet = []
}

/// UDP + TCP DNS front end for a `DnsService`.
final class DnsListener {
  private let service: DnsService
  private var udpFd: Int32 = -1
  private let stopped = Once()

  init(service: DnsService) { self.service = service }

  func start(host: String, port: UInt16) async throws {
    try startUdp(host, port)
    try startTcp(host, port)
  }

  func stop() {
    _ = stopped.claim()
  }

  // UDP uses a plain socket: no per-flow state, replies go back with sendto.
  private func startUdp(_ host: String, _ port: UInt16) throws {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw AdwallError("udp socket failed") }
    var addr = inetAddress(host, port)
    guard withSockAddr(&addr, { bind(fd, $0, $1) }) == 0 else {
      close(fd)
      throw AdwallError("cannot bind udp \(host):\(port): \(String(cString: strerror(errno)))")
    }
    setTimeouts(fd, seconds: 1)
    udpFd = fd

    let service = service
    let stopped = stopped
    Thread.detachNewThread {
      var buffer = Packet(repeating: 0, count: 65535)
      let capacity = buffer.count
      while !stopped.isClaimed {
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, capacity, 0, $0, &length) }
        }
        if count < 0 {
          if errno == EAGAIN || errno == EINTR { continue }
          break
        }
        let message = Array(buffer[0..<count])
        let sender = from
        Task {
          guard let response = await service.handle(message, viaUDP: true) else { return }
          var to = sender
          _ = withSockAddr(&to) { address, size in response.withUnsafeBytes { sendto(fd, $0.baseAddress, response.count, 0, address, size) } }
        }
      }
      close(fd)
    }
  }

  // TCP is a plain socket too: NWListener binds all of loopback, which collides with other resolvers on 127.0.x.x:53 (e.g. Cloudflare WARP).
  private func startTcp(_ host: String, _ port: UInt16) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AdwallError("tcp socket failed") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = inetAddress(host, port)
    guard withSockAddr(&addr, { bind(fd, $0, $1) }) == 0, listen(fd, 64) == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      throw AdwallError("cannot bind tcp \(host):\(port): \(reason)")
    }
    setTimeouts(fd, seconds: 1)  // lets accept() wake up and notice stop()

    let service = service
    let stopped = stopped
    Thread.detachNewThread {
      while !stopped.isClaimed {
        let client = accept(fd, nil, nil)
        if client < 0 {
          if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { continue }
          break
        }
        setTimeouts(client, seconds: 10)
        Thread.detachNewThread { serveTcp(client, service) }
      }
      close(fd)
    }
  }
}

/// One TCP connection: 2-byte length-prefixed messages, answered in order.
private func serveTcp(_ fd: Int32, _ service: DnsService) {
  defer { close(fd) }
  // ponytail: hard 10s cap per connection, add idle tracking if clients pipeline long-lived TCP
  let deadline = Date().addingTimeInterval(10)
  var buffer = Packet()
  var chunk = Packet(repeating: 0, count: 65535)
  let capacity = chunk.count
  while Date() < deadline {
    while buffer.count >= 2 {
      let length = Int(buffer[0]) << 8 | Int(buffer[1])
      if buffer.count < 2 + length { break }
      let message = Array(buffer[2..<(2 + length)])
      buffer.removeFirst(2 + length)
      let reply = ByteBuffer()
      let done = DispatchSemaphore(value: 0)
      Task {
        reply.bytes = await service.handle(message, viaUDP: false) ?? []
        done.signal()
      }
      done.wait()
      if !reply.bytes.isEmpty { writeAll(fd, [UInt8(reply.bytes.count >> 8), UInt8(reply.bytes.count & 0xFF)] + reply.bytes) }
    }
    let n = read(fd, &chunk, capacity)
    if n <= 0 { return }
    buffer += chunk[0..<n]
  }
}
