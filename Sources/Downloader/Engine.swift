import Foundation

struct DLError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

struct Segment: Codable, Equatable {
    var start: Int64
    var end: Int64  // inclusive
    var done: Int64 = 0
    var next: Int64 { start + done }
    var finished: Bool { next > end }
}

/// About `parts` pieces of at least `minSize` bytes, covering 0..<total. More pieces than connections, so a fast
/// connection picks up the next piece instead of idling while a slow one finishes.
func split(total: Int64, parts: Int, minSize: Int64 = 1 << 20) -> [Segment] {
    guard total > 0 else { return [] }
    let n = max(1, min(Int64(parts), total / minSize))
    let size = (total + n - 1) / n
    return stride(from: 0, to: total, by: Int(size)).map { Segment(start: $0, end: min($0 + size, total) - 1) }
}

/// Free name in `dir`: "a.zip", then "a (1).zip", "a (2).zip"… (also avoids a leftover ".part")
func uniqueName(_ name: String, in dir: URL) -> String {
    let fm = FileManager.default
    func taken(_ n: String) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(n).path) || fm.fileExists(atPath: dir.appendingPathComponent(n + ".part").path)
    }
    let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    var n = name, i = 0
    while taken(n) {
        i += 1
        n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
    }
    return n
}

struct Probe {
    var url: URL  // after redirects
    var name: String
    var total: Int64?
    var ranges: Bool
    var validator: String?  // ETag or Last-Modified
}

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

private func sessionConfig() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.httpMaximumConnectionsPerHost = 1
    c.timeoutIntervalForRequest = 30
    // identity: a gzip-decoded body would no longer match the byte ranges or Content-Length
    c.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Encoding": "identity"]
    return c
}

/// A cookie meant for the page's host must not follow a redirect to another host (a CDN).
func dropCookieCrossHost(_ new: URLRequest, from task: URLSessionTask) -> URLRequest {
    var r = new
    if r.url?.host != task.originalRequest?.url?.host { r.setValue(nil, forHTTPHeaderField: "Cookie") }
    return r
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(dropCookieCrossHost(newRequest, from: task))
    }
}

/// Asks for byte 0 only: 206 + Content-Range gives size and proves range support in one cheap request.
func probe(_ url: URL, headers: [String: String] = [:]) async throws -> Probe {
    var req = URLRequest(url: url)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    let s = URLSession(configuration: sessionConfig())
    defer { s.invalidateAndCancel() }  // a server that ignores Range starts sending the whole file: drop it
    let (_, resp) = try await s.bytes(for: req, delegate: RedirectGuard())
    guard let r = resp as? HTTPURLResponse else { throw DLError("Not an HTTP response") }
    guard r.statusCode == 200 || r.statusCode == 206 else { throw DLError("HTTP \(r.statusCode)") }
    func h(_ k: String) -> String? { r.value(forHTTPHeaderField: k) }
    // suggestedFilename reads Content-Disposition, but otherwise appends an extension guessed from the content type
    let fromURL = (r.url ?? url).lastPathComponent
    let name = h("Content-Disposition") == nil && fromURL.contains(".") ? fromURL : r.suggestedFilename ?? "download"
    var p = Probe(url: r.url ?? url, name: safeName(name), total: nil, ranges: false,
                  validator: h("ETag") ?? h("Last-Modified"))
    if r.statusCode == 206 {
        if let t = h("Content-Range")?.split(separator: "/").last.flatMap({ Int64($0) }) { (p.total, p.ranges) = (t, true) }
    } else if r.expectedContentLength >= 0 {
        p.total = r.expectedContentLength
    }
    return p
}

func safeName(_ s: String) -> String {
    let n = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    let trimmed = n.drop { $0 == "." }
    return trimmed.isEmpty ? "download" : String(trimmed)
}

/// One download. Writes straight into `<name>.part` at each segment's offset, renames it when complete.
/// All mutable state lives on `q`; `report` is called there too.
final class Job: NSObject, URLSessionDataDelegate {
    private let q = DispatchQueue(label: "download.job")
    private let ops = OperationQueue()
    private let conns: Int
    private let report: (Item) -> Void
    private var item: Item
    private var sessions: [URLSession] = []  // one session per connection, see launch()
    private var tasks: [ObjectIdentifier: (seg: Int, slot: Int)] = [:]
    private var failure: [ObjectIdentifier: (msg: String, retry: Bool)] = [:]
    private var tries: [Int: Int] = [:]
    private var waiting: Set<Int> = []  // segments sleeping before a retry
    private var fd: Int32 = -1
    private var stopped = false
    private var gotten: Int64 = 0  // bytes since the last timer tick
    private var timer: DispatchSourceTimer?
    private var probing: Task<Void, Never>?

    init(item: Item, conns: Int, report: @escaping (Item) -> Void) {
        self.item = item
        self.conns = conns
        self.report = report
        ops.maxConcurrentOperationCount = 1
        ops.underlyingQueue = q
    }

    func start() {
        let (url, headers) = (item.url, item.headers ?? [:])  // url, not `resolved`: re-follow redirects, signed CDN links expire
        probing = Task {
            do {
                let p = try await probe(url, headers: headers)
                q.async { self.begin(p) }
            } catch {
                q.async { if !self.stopped { self.fail(error.localizedDescription) } }
            }
        }
    }

    /// Pause: returns the final state (progress included) so the caller can store it right away.
    func stop() -> Item {
        q.sync {
            guard !stopped else { return item }
            halt()
            item.state = .paused
            item.speed = 0
            return item
        }
    }

    // MARK: lifecycle (on q)

    private func begin(_ p: Probe) {
        guard !stopped else { return }
        let fm = FileManager.default
        let resume = !item.segments.isEmpty && p.ranges && item.total == p.total && item.validator == p.validator
            && fm.fileExists(atPath: item.partURL.path)
        item.resolved = p.url
        item.total = p.total
        item.validator = p.validator
        item.resumable = p.ranges
        if !resume {
            try? fm.createDirectory(at: item.dir, withIntermediateDirectories: true)
            if item.segments.isEmpty { item.name = uniqueName(p.name, in: item.dir) }
            item.segments = p.total.map { t in p.ranges ? split(total: t, parts: conns * 4) : [Segment(start: 0, end: t - 1)] }
                ?? [Segment(start: 0, end: .max - 1)]  // size unknown: one stream, ends where the server stops
        }
        fd = open(item.partURL.path, O_RDWR | O_CREAT | (resume ? 0 : O_TRUNC), 0o644)
        guard fd >= 0 else { return fail("Cannot write \(item.partURL.path): \(String(cString: strerror(errno)))") }
        if !resume, let t = p.total { ftruncate(fd, off_t(t)) }
        sessions = (0..<min(conns, max(1, item.segments.count))).map { _ in
            URLSession(configuration: sessionConfig(), delegate: self, delegateQueue: ops)
        }
        item.state = .downloading
        timer = DispatchSource.makeTimerSource(queue: q)
        timer?.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer?.setEventHandler { [unowned self] in
            let now = Double(gotten) / 0.5
            gotten = 0
            item.speed = item.speed == 0 ? now : item.speed * 0.6 + now * 0.4
            report(item)
        }
        timer?.resume()
        report(item)
        pump()
    }

    private func pump() {
        guard !stopped else { return }
        if item.segments.allSatisfy(\.finished) { return finish() }
        let active = Set(tasks.values.map(\.seg))
        for i in item.segments.indices where tasks.count < sessions.count && !item.segments[i].finished
            && !active.contains(i) && !waiting.contains(i) { launch(i) }
    }

    private func launch(_ i: Int) {
        let used = Set(tasks.values.map(\.slot))
        guard let slot = sessions.indices.first(where: { !used.contains($0) }) else { return }
        let target = item.resolved ?? item.url
        var req = URLRequest(url: target)
        for (k, v) in item.headers ?? [:] where k != "Cookie" || target.host == item.url.host { req.setValue(v, forHTTPHeaderField: k) }
        if item.resumable {
            req.setValue("bytes=\(item.segments[i].next)-\(item.segments[i].end)", forHTTPHeaderField: "Range")
            // if the file changed since we started, the server answers 200 instead of 206 and we stop
            if let v = item.validator, !v.hasPrefix("W/") { req.setValue(v, forHTTPHeaderField: "If-Range") }
        }
        // Own session per connection: over HTTP/2 a single session would multiplex every segment onto one TCP
        // connection, and per-connection speed caps are the thing this app exists to get around.
        let t = sessions[slot].dataTask(with: req)
        tasks[ObjectIdentifier(t)] = (i, slot)
        t.resume()
    }

    private func halt() {
        stopped = true
        probing?.cancel()
        timer?.cancel()
        sessions.forEach { $0.invalidateAndCancel() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func finish() {
        halt()
        do {
            var dest = item.fileURL
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = item.dir.appendingPathComponent(uniqueName(item.name, in: item.dir))
            }
            try FileManager.default.moveItem(at: item.partURL, to: dest)
            item.name = dest.lastPathComponent
            item.state = .done
            item.speed = 0
            report(item)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ msg: String) {
        halt()
        item.state = .failed
        item.error = msg
        item.speed = 0
        report(item)
    }

    // MARK: URLSession (on q)

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(dropCookieCrossHost(newRequest, from: task))
    }

    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive r: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == (item.resumable ? 206 : 200) { return completionHandler(.allow) }
        failure[ObjectIdentifier(t)] = code == 200 ? ("File changed on the server", false) : ("HTTP \(code)", code >= 500 || code == 429)
        completionHandler(.cancel)
    }

    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let i = tasks[ObjectIdentifier(t)]?.seg else { return }
        let seg = item.segments[i]
        let chunk = data.prefix(Int(min(Int64(data.count), seg.end - seg.next + 1)))  // never past the segment's end
        if let e = write(chunk, at: seg.next) {
            failure[ObjectIdentifier(t)] = ("Disk write failed: \(e)", false)
            return t.cancel()
        }
        item.segments[i].done += Int64(chunk.count)
        gotten += Int64(chunk.count)
        tries[i] = nil
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        guard !stopped, let i = tasks.removeValue(forKey: ObjectIdentifier(t))?.seg else { return }
        let bad = failure.removeValue(forKey: ObjectIdentifier(t))
        if let bad, !bad.retry { return fail(bad.msg) }
        if e == nil, bad == nil {
            if !item.resumable, item.total == nil { item.segments[i].end = item.segments[i].next - 1 }  // stream ended: that was the size
            if item.segments[i].finished { return pump() }
        }
        // error, bad status, or the server closed early: retry this segment from where it stopped
        let n = tries[i, default: 0] + 1
        tries[i] = n
        guard n <= 4 else { return fail(bad?.msg ?? e?.localizedDescription ?? "Connection closed early") }
        if !item.resumable { item.segments[i].done = 0 }  // no ranges: the stream restarts from byte 0
        waiting.insert(i)
        q.asyncAfter(deadline: .now() + Double(n)) { [self] in
            waiting.remove(i)
            pump()
        }
    }

    /// nil on success, else the error text
    private func write(_ d: Data, at off: Int64) -> String? {
        d.withUnsafeBytes { buf in
            var p = 0
            while p < buf.count {
                let n = pwrite(fd, buf.baseAddress! + p, buf.count - p, off_t(off) + off_t(p))
                if n < 0 {
                    if errno == EINTR { continue }
                    return String(cString: strerror(errno))
                }
                p += n
            }
            return nil
        }
    }
}
