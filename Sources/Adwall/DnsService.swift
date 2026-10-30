import Foundation

private let maxCacheEntries = 5000
private let maxRecent = 30

actor DnsService {
  private(set) var matcher = Matcher.empty
  private(set) var enabled = true
  private(set) var stats = DnsStats()
  private(set) var recent: [String] = []

  private var cache: [String: (response: Packet, expires: Date)] = [:]
  private let upstreams: Upstreams

  init(upstreams: Upstreams) { self.upstreams = upstreams }

  func setMatcher(_ matcher: Matcher) { self.matcher = matcher }
  func setEnabled(_ enabled: Bool) { self.enabled = enabled }

  func handle(_ message: Packet, viaUDP: Bool) async -> Packet? {
    guard let query = DnsQuery(message) else { return nil }
    if query.name == healthName { return negativeResponse(query) }

    stats.total += 1
    if enabled && matcher.isBlocked(query.name) {
      stats.blocked += 1
      remember(query.name)
      return negativeResponse(query)
    }

    let key = "\(query.name)|\(query.type)|\(query.qclass)|\(query.dnssecOK ? 1 : 0)"
    let limit = query.udpSize ?? 512
    if let hit = cache[key], hit.expires > Date(), !viaUDP || hit.response.count <= limit {
      stats.cacheHits += 1
      var response = hit.response
      response[0] = message[0]
      response[1] = message[1]
      return response
    }

    do {
      let response = try await upstreams.resolve(message)
      store(key, response)
      return response
    } catch {
      return servfailResponse(query)
    }
  }

  private func remember(_ name: String) {
    recent.removeAll { $0 == name }
    recent.insert(name, at: 0)
    if recent.count > maxRecent { recent.removeLast() }
  }

  private func store(_ key: String, _ response: Packet) {
    guard let ttl = cacheTTL(of: response) else { return }
    cache[key] = (response, Date().addingTimeInterval(Double(ttl)))
    // ponytail: evicts an arbitrary entry, swap for LRU if the hit rate matters
    if cache.count > maxCacheEntries, let victim = cache.keys.first(where: { $0 != key }) { cache.removeValue(forKey: victim) }
  }
}
