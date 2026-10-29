import AppKit
import Combine

let defaultConns = 8
let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path

enum State: String, Codable { case downloading, paused, done, failed }

struct Item: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var dir: URL
    var name: String  // placeholder until the first probe returns the real file name
    var resolved: URL?  // url after redirects
    var total: Int64?
    var validator: String?  // ETag/Last-Modified: resume only if the file is still the same
    var resumable = true
    var segments: [Segment] = []
    var state = State.downloading
    var error: String?
    var speed = 0.0  // bytes/s, only meaningful while downloading
    var headers: [String: String]?  // Cookie/Referer from the browser; stored so a resume still works (plain text on disk)

    init(url: URL, dir: URL, headers: [String: String]? = nil) {
        self.url = url
        self.dir = dir
        self.headers = headers
        name = url.lastPathComponent.isEmpty ? (url.host ?? "download") : url.lastPathComponent
    }

    var got: Int64 { segments.reduce(0) { $0 + $1.done } }
    var fileURL: URL { dir.appendingPathComponent(name) }
    var partURL: URL { dir.appendingPathComponent(name + ".part") }
    var fraction: Double? { total.flatMap { $0 > 0 ? Double(got) / Double($0) : nil } }
}

func webURL(_ s: String) -> URL? {
    guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(u.scheme?.lowercased()), u.host != nil else { return nil }
    return u
}

/// The download list + persistence. Items that were running when the app quit come back paused.
final class Store: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published var adding = false
    @Published var link = ""  // text in the Add sheet
    // UserDefaults-backed like the other apps: no @AppStorage (needs the SwiftUIMacros plugin Command Line Tools lack)
    /// Browser extension hands downloads over only while this is on.
    @Published var capture = UserDefaults.standard.bool(forKey: "capture") {
        didSet { UserDefaults.standard.set(capture, forKey: "capture") }
    }
    @Published var conns = UserDefaults.standard.object(forKey: "connections") as? Int ?? defaultConns {
        didSet { UserDefaults.standard.set(conns, forKey: "connections") }
    }
    @Published var folder = UserDefaults.standard.string(forKey: "folder") ?? defaultFolder {
        didSet { UserDefaults.standard.set(folder, forKey: "folder") }
    }

    private var jobs: [UUID: Job] = [:]
    private var saved = Date.distantPast
    private let file: URL

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloader")) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("downloads.json")
        items = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        for i in items.indices where items[i].state == .downloading { items[i].state = .paused }
    }

    var active: Bool { !jobs.isEmpty }

    func add(_ url: URL, headers: [String: String]? = nil) {
        let item = Item(url: url, dir: URL(fileURLWithPath: folder), headers: headers)
        items.insert(item, at: 0)
        start(item.id)
    }

    func start(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), jobs[id] == nil else { return }
        items[i].state = .downloading
        items[i].error = nil
        let job = Job(item: items[i], conns: conns) { [weak self] snap in DispatchQueue.main.async { self?.apply(snap) } }
        jobs[id] = job
        job.start()
    }

    func pause(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        apply(job.stop(), force: true)
    }

    func pauseAll() {
        for id in Array(jobs.keys) { pause(id) }
        save(force: true)
    }

    func remove(_ id: UUID) {
        pause(id)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].state != .done { try? FileManager.default.removeItem(at: items[i].partURL) }
        items.remove(at: i)
        save(force: true)
    }

    /// Snapshot from a job. Ignored if the job was paused/removed meanwhile (late snapshots from its queue).
    private func apply(_ snap: Item, force: Bool = false) {
        guard force || jobs[snap.id] != nil, let i = items.firstIndex(where: { $0.id == snap.id }) else { return }
        items[i] = snap
        if snap.state != .downloading { jobs[snap.id] = nil }
        save(force: snap.state != .downloading)
    }

    private func save(force: Bool) {
        guard force || Date().timeIntervalSince(saved) > 1 else { return }
        saved = Date()
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }
}
