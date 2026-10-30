import Foundation

struct ListSource: Codable {
  var id: String
  var name: String
  var url: String
  var enabled: Bool
}

/// Missing keys in config.json fall back to the defaults.
struct Config: Codable {
  var upstreams = ["https://1.1.1.1/dns-query", "https://9.9.9.9/dns-query", "1.1.1.1", "9.9.9.9"]
  var lists = [
    ListSource(
      id: "hagezi-pro", name: "HaGeZi Pro",
      url: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt", enabled: true),
    ListSource(
      id: "stevenblack", name: "StevenBlack Unified Hosts",
      url: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", enabled: true)
  ]
  var updateIntervalHours = 24.0

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Config()
    upstreams = try c.decodeIfPresent([String].self, forKey: .upstreams) ?? defaults.upstreams
    lists = try c.decodeIfPresent([ListSource].self, forKey: .lists) ?? defaults.lists
    // Clamped: 0 would hammer the list hosts and a huge value overflows the sleep.
    updateIntervalHours = min(max(try c.decodeIfPresent(Double.self, forKey: .updateIntervalHours) ?? defaults.updateIntervalHours, 1), 8760)
  }

  static func load(_ file: String) -> Config {
    // A file that exists but does not parse is left alone, so a typo never wipes the user's edits.
    if let data = FileManager.default.contents(atPath: file) { return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config() }
    let config = Config()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try? encoder.encode(config).write(to: URL(fileURLWithPath: file))
    return config
  }
}

private let minDomains = 50

func listFile(_ source: ListSource, in dir: String) -> String { "\(dir)/\(source.id).txt" }

func readList(_ source: ListSource, in dir: String) -> String {
  (try? String(contentsOfFile: listFile(source, in: dir), encoding: .utf8)) ?? ""
}

/// Downloads a list and swaps it in atomically; returns the number of blocked domains.
func downloadList(_ source: ListSource, to dir: String) async throws -> Int {
  guard let url = URL(string: source.url) else { throw AdwallError("\(source.name): bad url") }
  let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 90))
  let status = (response as? HTTPURLResponse)?.statusCode ?? 0
  guard status == 200 else { throw AdwallError("\(source.name): HTTP \(status)") }
  let text = String(decoding: data, as: UTF8.self)
  let count = parseRules(text).block.count
  guard count >= minDomains else { throw AdwallError("\(source.name): list looks empty") }
  try text.write(toFile: listFile(source, in: dir), atomically: true, encoding: .utf8)
  return count
}
