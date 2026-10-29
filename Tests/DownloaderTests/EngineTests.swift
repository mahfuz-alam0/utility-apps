import Foundation
import Network
import Testing
@testable import Downloader

/// Minimal HTTP server over a byte blob: honours `Range`, records every Range header it sees.
final class BlobServer {
    let data: Data
    let honourRanges: Bool
    private let lock = NSLock()
    private var seen: [String] = []
    private var cookieSeen: [String] = []
    private var listener: NWListener?
    var ranges: [String] { lock.withLock { seen } }
    var cookies: [String] { lock.withLock { cookieSeen } }

    init(_ data: Data, honourRanges: Bool = true) {
        self.data = data
        self.honourRanges = honourRanges
    }

    func start() async throws -> URL {
        let l = try NWListener(using: .tcp)
        listener = l
        l.newConnectionHandler = { [self] c in handle(c) }
        let port: UInt16 = await withCheckedContinuation { k in
            l.stateUpdateHandler = { if case .ready = $0 { k.resume(returning: l.port!.rawValue) } }
            l.start(queue: .global())
        }
        return URL(string: "http://127.0.0.1:\(port)/blob.bin")!
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] buf, _, _, _ in
            let lines = String(decoding: buf ?? Data(), as: UTF8.self).components(separatedBy: "\r\n")
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if let ck = lines.first(where: { $0.lowercased().hasPrefix("cookie:") }) { lock.withLock { cookieSeen.append(String(ck.dropFirst(7)).trimmingCharacters(in: .whitespaces)) } }
            var head = "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nAccept-Ranges: bytes\r\n"
            var body = data
            if honourRanges, let range {
                lock.withLock { seen.append(range) }
                let nums = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                let lo = nums[0] ?? 0, hi = min(nums[1] ?? data.count - 1, data.count - 1)
                head = "HTTP/1.1 206 Partial Content\r\nETag: \"v1\"\r\nContent-Range: bytes \(lo)-\(hi)/\(data.count)\r\n"
                body = data[lo...hi]
            }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

private func run(_ item: Item, conns: Int = 4) async -> Item {
    let lock = NSLock()
    var finished = false
    return await withCheckedContinuation { k in
        let job = Job(item: item, conns: conns) { snap in
            lock.lock(); defer { lock.unlock() }
            if snap.state != .downloading && !finished { finished = true; k.resume(returning: snap) }
        }
        job.start()
    }
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let blob = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })

@Test func splitCoversEverythingOnce() {
    let s = split(total: 10_000_001, parts: 8)
    #expect(s.count == 8 && s.first?.start == 0 && s.last?.end == 10_000_000)
    #expect(zip(s, s.dropFirst()).allSatisfy { $0.end + 1 == $1.start })
    #expect(split(total: 100, parts: 8).count == 1)  // below minSize: not worth splitting
    #expect(split(total: 0, parts: 8).isEmpty)
}

@Test func uniqueNames() throws {
    let d = tempDir()
    #expect(uniqueName("a.zip", in: d) == "a.zip")
    try Data().write(to: d.appendingPathComponent("a.zip"))
    try Data().write(to: d.appendingPathComponent("a (1).zip.part"))
    #expect(uniqueName("a.zip", in: d) == "a (2).zip")
    #expect(safeName("../.x/y:z") == "_.x_y_z")
}

@Test func segmentedDownloadMatchesSource() async throws {
    let server = BlobServer(blob)
    let dir = tempDir()
    let done = await run(Item(url: try await server.start(), dir: dir))
    #expect(done.state == .done, "\(done.error ?? "")")
    #expect(try Data(contentsOf: dir.appendingPathComponent("blob.bin")) == blob)
    #expect(server.ranges.count > 2)  // really split across several requests
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("blob.bin.part").path))
}

@Test func resumeSkipsFinishedBytes() async throws {
    let server = BlobServer(blob)
    let dir = tempDir()
    var item = Item(url: try await server.start(), dir: dir)
    // as if an earlier run had fetched the first 600_000 bytes of a 4-way split, then was paused
    item.name = "blob.bin"
    item.total = Int64(blob.count)
    item.validator = "\"v1\""
    item.segments = split(total: item.total!, parts: 4)
    item.segments[0].done = 600_000
    var part = Data(count: blob.count)
    part.replaceSubrange(0..<600_000, with: blob[0..<600_000])
    try part.write(to: item.partURL)

    let done = await run(item)
    #expect(done.state == .done, "\(done.error ?? "")")
    #expect(try Data(contentsOf: item.fileURL) == blob)
    #expect(server.ranges.contains { $0.hasPrefix("bytes=600000-") })
    #expect(!server.ranges.contains { $0.hasPrefix("bytes=0-") && $0 != "bytes=0-0" })  // bytes=0-0 is the probe
}

@Test func serverWithoutRangesStillDownloads() async throws {
    let server = BlobServer(blob, honourRanges: false)
    let dir = tempDir()
    let done = await run(Item(url: try await server.start(), dir: dir))
    #expect(done.state == .done, "\(done.error ?? "")")
    #expect(try Data(contentsOf: dir.appendingPathComponent("blob.bin")) == blob)
    #expect(done.resumable == false)
}

@Test func browserCookieIsSentOnEveryRequest() async throws {
    let server = BlobServer(blob)
    let dir = tempDir()
    let done = await run(Item(url: try await server.start(), dir: dir, headers: ["Cookie": "sid=42"]))
    #expect(done.state == .done, "\(done.error ?? "")")
    #expect(server.cookies.count == server.ranges.count && server.cookies.allSatisfy { $0 == "sid=42" })  // probe + every segment
}

@Test func cookieStaysOnItsHost() {
    let t = URLSession.shared.dataTask(with: URL(string: "http://a.example/x")!)
    var cdn = URLRequest(url: URL(string: "http://cdn.example/y")!)
    cdn.setValue("s=1", forHTTPHeaderField: "Cookie")
    #expect(dropCookieCrossHost(cdn, from: t).value(forHTTPHeaderField: "Cookie") == nil)
    var same = URLRequest(url: URL(string: "http://a.example/z")!)
    same.setValue("s=1", forHTTPHeaderField: "Cookie")
    #expect(dropCookieCrossHost(same, from: t).value(forHTTPHeaderField: "Cookie") == "s=1")
}

@Test func requestWaitsForFullBody() {
    let head = "POST /add HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
    #expect(CaptureServer.split(Data((head + "abc").utf8)) == nil)
    #expect(CaptureServer.split(Data((head + "abcde").utf8))?.1 == Data("abcde".utf8))
    #expect(CaptureServer.split(Data("GET /status HTTP/1.1\r\nHost: x".utf8)) == nil)
}

@Test func captureServerRules() async throws {
    let lock = NSLock()
    var on = false
    var added: [(URL, [String: String])] = []
    let server = CaptureServer(port: 48621, isOn: { lock.withLock { on } }, onAdd: { u, h in lock.withLock { added.append((u, h)) } })
    server.start()
    try await Task.sleep(for: .milliseconds(300))  // listener comes up
    func call(_ method: String, _ path: String, origin: String? = nil, body: String = "") async throws -> Int {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:48621\(path)")!)
        r.httpMethod = method
        if let origin { r.setValue(origin, forHTTPHeaderField: "Origin") }
        if method == "POST" { r.httpBody = Data(body.utf8) }
        return (try await URLSession.shared.data(for: r).1 as! HTTPURLResponse).statusCode
    }
    let ok = #"{"url":"http://example.com/a.zip","referrer":"http://example.com/","cookie":"s=1"}"#
    let ext = "chrome-extension://abc"
    #expect(try await call("GET", "/status") == 200)
    #expect(try await call("POST", "/add", origin: ext, body: ok) == 409)  // switch off
    lock.withLock { on = true }
    #expect(try await call("POST", "/add", body: ok) == 403)  // no Origin: not a browser extension
    #expect(try await call("POST", "/add", origin: "https://evil.example", body: ok) == 403)  // a web page
    #expect(try await call("POST", "/add", origin: ext, body: #"{"url":"file:///etc/passwd"}"#) == 400)
    #expect(try await call("GET", "/nope") == 404)
    #expect(lock.withLock { added.isEmpty })
    #expect(try await call("POST", "/add", origin: ext, body: ok) == 200)
    #expect(lock.withLock { added.map { $0.0.absoluteString } } == ["http://example.com/a.zip"])
    #expect(lock.withLock { added[0].1 } == ["Referer": "http://example.com/", "Cookie": "s=1"])
}
