import AppKit
import Combine
import ImageIO

struct ClipItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String?
    var image: String?  // PNG file name inside imagesDir
    var pinned = false
}

/// History + persistence. Order: pinned first, then newest first. Pinned items ignore the size cap and "Clear all".
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// pasteboard changeCount after our own write, so the monitor skips it
    var ownChange = -1

    private let settings: Settings
    private let file: URL
    private let imagesDir: URL
    private let thumbs = NSCache<NSString, NSImage>()
    private var bag = Set<AnyCancellable>()

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardManager"), settings: Settings = .shared) {
        self.settings = settings
        file = dir.appendingPathComponent("history.json")
        imagesDir = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        if settings.persistHistory {
            items = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([ClipItem].self, from: $0) } ?? []
        } else {  // session-only: drop whatever a previous session left behind
            try? FileManager.default.removeItem(at: file)
            (try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil))?
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }
        settings.$maxItems.dropFirst().sink { [weak self] n in self?.trim(to: max(1, n)) }.store(in: &bag)
        settings.$persistHistory.dropFirst().sink { [weak self] on in
            guard let self else { return }
            if on { write() } else { try? FileManager.default.removeItem(at: file) }
        }.store(in: &bag)
    }

    func add(text: String) {
        let pinned = items.contains { $0.text == text && $0.pinned }  // re-copy moves to top, keeps pin
        items.removeAll { $0.text == text }
        insert(ClipItem(text: text, pinned: pinned))
    }

    // ponytail: no image dedupe, add a content hash if repeated copies annoy
    func add(png: Data) {
        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: imagesDir.appendingPathComponent(name))) != nil else { return }
        insert(ClipItem(image: name))
    }

    func togglePin(_ item: ClipItem) {
        guard var it = items.first(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        it.pinned.toggle()
        insert(it)
    }

    func remove(_ item: ClipItem) {
        deleteFiles(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Removes everything except pinned items.
    func clear() {
        items.filter { !$0.pinned }.forEach(deleteFiles)
        items.removeAll { !$0.pinned }
        save()
    }

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = item.text {
            pb.setString(t, forType: .string)
        } else if let n = item.image, let png = try? Data(contentsOf: imagesDir.appendingPathComponent(n)) {
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
        ownChange = pb.changeCount
    }

    func thumbnail(_ name: String) -> NSImage? {
        if let hit = thumbs.object(forKey: name as NSString) { return hit }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(imagesDir.appendingPathComponent(name) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        thumbs.setObject(img, forKey: name as NSString)
        return img
    }

    /// Top of its group: pinned items above unpinned, newest first within each.
    private func insert(_ item: ClipItem) {
        let i = items.firstIndex { $0.pinned == item.pinned ? $0.date <= item.date : !$0.pinned } ?? items.count
        items.insert(item, at: i)
        trim(to: settings.maxItems)
    }

    private func trim(to n: Int) {
        var kept = 0
        items = items.filter { item in
            if item.pinned { return true }
            kept += 1
            if kept <= n { return true }
            deleteFiles(item)
            return false
        }
        save()
    }

    private func deleteFiles(_ item: ClipItem) {
        if let n = item.image { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(n)) }
    }

    private func save() { if settings.persistHistory { write() } }
    private func write() { try? JSONEncoder().encode(items).write(to: file, options: .atomic) }
}
