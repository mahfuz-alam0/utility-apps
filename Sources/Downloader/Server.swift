import Foundation
import Network

/// Localhost endpoint for the browser extension. Loopback only.
///   GET  /status  -> {"capture":true|false}
///   POST /add     -> {"url","referrer","cookie"}; only from a browser extension, only while capture is on
/// A web page can fire requests at 127.0.0.1 too, but it cannot forge `Origin: chrome-extension://…`, so /add checks that.
final class CaptureServer {
    static let defaultPort: UInt16 = 48620
    private let q = DispatchQueue(label: "capture.server")
    private let port: UInt16
    private let isOn: () -> Bool
    private let onAdd: (URL, [String: String]) -> Void
    private var listener: NWListener?

    init(port: UInt16 = defaultPort, isOn: @escaping () -> Bool, onAdd: @escaping (URL, [String: String]) -> Void) {
        self.port = port
        self.isOn = isOn
        self.onAdd = onAdd
    }

    func start() {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: port)!) else { return }  // port taken: capture just won't work
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self?.q ?? .main)
            self?.read(c, Data())
        }
        l.start(queue: q)
        listener = l
    }

    private func read(_ c: NWConnection, _ have: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            let buf = have + (data ?? Data())
            if let (head, body) = Self.split(buf) { return self?.respond(c, head, body) ?? c.cancel() }
            if done || err != nil || buf.count > 1 << 20 { return c.cancel() }
            self?.read(c, buf)
        }
    }

    /// (header lines, body) once the whole request has arrived
    static func split(_ buf: Data) -> ([String], Data)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let body = buf[end.upperBound...]
        let len = head.compactMap { $0.lowercased().hasPrefix("content-length:") ? Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
        return body.count >= len ? (head, Data(body.prefix(len))) : nil
    }

    private func respond(_ c: NWConnection, _ head: [String], _ body: Data) {
        let request = head[0].split(separator: " ")
        let origin = head.first { $0.lowercased().hasPrefix("origin:") }.map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) } ?? ""
        var code = 404, text = "{}"
        switch (request.first, request.dropFirst().first) {
        case ("GET", "/status"):
            (code, text) = (200, "{\"capture\":\(isOn())}")
        case ("POST", "/add"):
            if !(origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://")) {
                code = 403
            } else if !isOn() {
                (code, text) = (409, "{\"capture\":false}")
            } else if let m = try? JSONDecoder().decode(Capture.self, from: body), let url = webURL(m.url) {
                var h: [String: String] = [:]
                if let r = m.referrer, !r.isEmpty { h["Referer"] = r }
                if let ck = m.cookie, !ck.isEmpty { h["Cookie"] = ck }
                onAdd(url, h)
                code = 200
            } else {
                code = 400
            }
        default: break
        }
        let out = "HTTP/1.1 \(code) X\r\nContent-Type: application/json\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
        c.send(content: Data(out.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private struct Capture: Decodable {
        var url: String
        var referrer: String?
        var cookie: String?
    }
}
