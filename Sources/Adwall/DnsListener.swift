import Foundation
import Network

private final class ByteBuffer: @unchecked Sendable {
  var bytes: Packet = []
}

/// UDP + TCP DNS front end for a `DnsService`.
final class DnsListener {
  private let service: DnsService
  private let queue = DispatchQueue(label: "adwall.dns")
  private var tcp: NWListener?
  private var udpFd: Int32 = -1
  private let stopped = Once()

  init(service: DnsService) { self.service = service }

  func start(host: String, port: UInt16) async throws {
    try startUdp(host, port)
    try await startTcp(host, port)
  }

  func stop() {
    _ = stopped.claim()
    tcp?.cancel()
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

  private func startTcp(_ host: String, _ port: UInt16) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [service, queue] connection in
      connection.start(queue: queue)
      // ponytail: hard 10s cap per connection, add idle tracking if clients pipeline long-lived TCP
      queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
      let buffer = ByteBuffer()

      func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, complete, error in
          if let data { buffer.bytes += data }
          while buffer.bytes.count >= 2 {
            let length = Int(buffer.bytes[0]) << 8 | Int(buffer.bytes[1])
            if buffer.bytes.count < 2 + length { break }
            let message = Array(buffer.bytes[2..<(2 + length)])
            buffer.bytes.removeFirst(2 + length)
            Task {
              guard let response = await service.handle(message, viaUDP: false) else { return }
              let frame = [UInt8(response.count >> 8), UInt8(response.count & 0xFF)] + response
              connection.send(content: Data(frame), completion: .contentProcessed { _ in })
            }
          }
          if error != nil || complete { return connection.cancel() }
          read()
        }
      }
      read()
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if once.claim() { continuation.resume() }
        case .failed(let error):
          if once.claim() { continuation.resume(throwing: AdwallError("cannot bind tcp \(host):\(port): \(error)")) }
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    tcp = listener
  }
}
