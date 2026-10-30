import Foundation
import Network

private let udpTimeout = 2.0
private let dohTimeout = 2.5
private let truncatedBit: UInt8 = 0x02

/// One query/response over a fresh UDP or TCP (length-framed) connection.
private func exchange(host: String, port: UInt16, tcp: Bool, query: Packet, timeout: TimeInterval) async throws -> Packet {
  try await withCheckedThrowingContinuation { continuation in
    let queue = DispatchQueue(label: "adwall.upstream")
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tcp ? .tcp : .udp)
    let once = Once()
    let finish = { (result: Result<Packet, Error>) in
      guard once.claim() else { return }
      connection.cancel()
      continuation.resume(with: result)
    }

    func receiveFramed(_ buffer: Packet) {
      if buffer.count >= 2, buffer.count >= 2 + (Int(buffer[0]) << 8 | Int(buffer[1])) {
        let length = Int(buffer[0]) << 8 | Int(buffer[1])
        return finish(.success(Array(buffer[2..<(2 + length)])))
      }
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, complete, error in
        if let error { return finish(.failure(error)) }
        guard let data, !(complete && data.isEmpty) else { return finish(.failure(AdwallError("tcp closed"))) }
        receiveFramed(buffer + data)
      }
    }

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        if tcp {
          connection.send(content: Data([UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query), completion: .contentProcessed { error in
            if let error { finish(.failure(error)) } else { receiveFramed([]) }
          })
        } else {
          connection.send(content: Data(query), completion: .contentProcessed { error in
            if let error { return finish(.failure(error)) }
            connection.receiveMessage { data, _, _, error in
              if let error { return finish(.failure(error)) }
              let response = Packet(data ?? Data())
              guard response.count >= 12, response[0] == query[0], response[1] == query[1] else {
                return finish(.failure(AdwallError("bad udp response")))
              }
              finish(.success(response))
            }
          })
        }
      case .failed(let error):
        finish(.failure(error))
      default:
        break
      }
    }
    queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(AdwallError("upstream timeout"))) }
    connection.start(queue: queue)
  }
}

private let dohSession: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.connectionProxyDictionary = [:]
  config.urlCache = nil
  return URLSession(configuration: config)
}()

private func dohQuery(_ url: URL, _ query: Packet) async throws -> Packet {
  var request = URLRequest(url: url, timeoutInterval: dohTimeout)
  request.httpMethod = "POST"
  request.setValue("application/dns-message", forHTTPHeaderField: "content-type")
  request.setValue("application/dns-message", forHTTPHeaderField: "accept")
  request.httpBody = Data(query)
  let (data, response) = try await dohSession.data(for: request)
  guard (response as? HTTPURLResponse)?.statusCode == 200, data.count >= 12 else { throw AdwallError("bad doh response") }
  return Packet(data)
}

private func parseHostPort(_ upstream: String) -> (host: String, port: UInt16) {
  if IPv6Address(upstream) != nil { return (upstream, 53) }
  guard let colon = upstream.lastIndex(of: ":"), let port = UInt16(upstream[upstream.index(after: colon)...]) else { return (upstream, 53) }
  return (String(upstream[..<colon]), port)
}

private func ask(_ upstream: String, _ query: Packet) async throws -> Packet {
  if upstream.hasPrefix("https://") || upstream.hasPrefix("http://") {
    guard let url = URL(string: upstream) else { throw AdwallError("bad upstream \(upstream)") }
    return try await dohQuery(url, query)
  }
  let (host, port) = parseHostPort(upstream)
  let response = try await exchange(host: host, port: port, tcp: false, query: query, timeout: udpTimeout)
  if response[2] & truncatedBit != 0 {
    return try await exchange(host: host, port: port, tcp: true, query: query, timeout: udpTimeout * 2)
  }
  return response
}

/// Tries upstreams in order; the last one that worked moves to the front.
actor Upstreams {
  private var list: [String]

  init(_ list: [String]) { self.list = list }

  func resolve(_ query: Packet) async throws -> Packet {
    var lastError: Error = AdwallError("no upstream configured")
    for upstream in list {
      do {
        let response = try await ask(upstream, query)
        if list.first != upstream {
          list.removeAll { $0 == upstream }
          list.insert(upstream, at: 0)
        }
        return response
      } catch {
        lastError = error
      }
    }
    throw lastError
  }
}
