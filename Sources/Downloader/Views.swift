import SwiftUI
import UniformTypeIdentifiers

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

extension Item {
    var status: String {
        let size = total.map { "\(bytes(got)) of \(bytes($0))" } ?? bytes(got)
        switch state {
        case .downloading:
            guard speed > 0 else { return size }
            var s = "\(size) · \(bytes(Int64(speed)))/s"
            if let t = total {
                let left = DateComponentsFormatter()
                left.unitsStyle = .abbreviated
                left.maximumUnitCount = 2
                if let eta = left.string(from: Double(t - got) / speed) { s += " · \(eta) left" }
            }
            return s
        case .paused: return "Paused · " + size
        case .done: return bytes(got)
        case .failed: return error ?? "Failed"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Press ⌘N, or drop a link here."))
            } else {
                List(store.items) { Row(item: $0, store: store) }
            }
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Toggle("Capture browser downloads", isOn: $store.capture).toggleStyle(.switch)
                    Spacer()
                }
                HStack {
                    Stepper("Connections: \(store.conns)", value: $store.conns, in: 1...32)
                    Spacer()
                    Text((store.folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Button("Change…", action: pickFolder)
                }
            }
            .padding(10)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add URL", systemImage: "plus") { store.adding = true }
                Button("Pause All", systemImage: "pause.fill") { store.pauseAll() }
            }
        }
        .sheet(isPresented: $store.adding) { AddSheet(store: store) }
        .dropDestination(for: URL.self) { urls, _ in
            urls.compactMap { webURL($0.absoluteString) }.forEach { store.add($0) }
            return !urls.isEmpty
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: store.folder)
        if p.runModal() == .OK, let u = p.url { store.folder = u.path }
    }
}

struct Row: View {
    let item: Item
    let store: Store

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileURL.pathExtension) ?? .data))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.state != .done { ProgressView(value: item.fraction).tint(item.state == .failed ? .red : nil) }
                Text(item.status).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer()
            switch item.state {
            case .downloading: button("pause.fill", "Pause") { store.pause(item.id) }
            case .paused: button("play.fill", "Resume") { store.start(item.id) }
            case .failed: button("arrow.clockwise", "Retry") { store.start(item.id) }
            case .done: button("magnifyingglass", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
            }
            button("xmark", "Remove from list") { store.remove(item.id) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.state == .done { NSWorkspace.shared.open(item.fileURL) } }
    }

    private func button(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(help)
    }
}

struct AddSheet: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download from URL").font(.headline)
            TextField("https://…", text: $store.link).onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { store.adding = false }.keyboardShortcut(.cancelAction)
                Button("Download", action: go).keyboardShortcut(.defaultAction).disabled(webURL(store.link) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { store.link = NSPasteboard.general.string(forType: .string).flatMap(webURL)?.absoluteString ?? "" }
    }

    private func go() {
        guard let u = webURL(store.link) else { return }
        store.add(u)
        store.adding = false
    }
}
