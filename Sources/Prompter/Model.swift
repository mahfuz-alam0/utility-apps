import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

enum Mode: String, Codable { case manual, auto }

enum Kind { case p, li, cue }
struct Item: Equatable { let kind: Kind; let text: String }

struct Step: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var say = ""        // what to say; blank line = paragraph, "- " = bullet, **bold** = highlight
    var cue = ""        // what to show on screen
    var seconds: Int?   // Auto mode: fixed time; nil = estimate from word count
}

struct Script: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Untitled script"
    var steps: [Step] = []
}

struct Library: Codable {
    var scripts: [Script]
    var selection: UUID?
}

struct Settings: Codable, Equatable {
    var fontSize = 26.0
    var bgAlpha = 0.45
    var locked = false
    var protect = true
    var mode = Mode.manual
    var wpm = 150
    var frame: [Double]?
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        bgAlpha = try c.decodeIfPresent(Double.self, forKey: .bgAlpha) ?? bgAlpha
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? locked
        protect = try c.decodeIfPresent(Bool.self, forKey: .protect) ?? protect
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? mode
        wpm = try c.decodeIfPresent(Int.self, forKey: .wpm) ?? wpm
        frame = try c.decodeIfPresent([Double].self, forKey: .frame)
    }
}

extension Step {
    var items: [Item] { parseBody(say) + (cue.isEmpty ? [] : [Item(kind: .cue, text: "Show: " + cue)]) }

    func duration(wpm: Int) -> Int {
        if let s = seconds, s > 0 { return s }
        let words = say.split(whereSeparator: \.isWhitespace).filter { w in w.contains { $0.isLetter || $0.isNumber } }.count
        return max(4, Int((Double(words) * 60 / Double(max(wpm, 60))).rounded()))
    }
}

extension Script {
    func summary(wpm: Int) -> String {
        if steps.isEmpty { return "No steps" }
        let secs = steps.reduce(0) { $0 + $1.duration(wpm: wpm) }
        return "\(steps.count) step\(steps.count == 1 ? "" : "s") · ~\(max(1, Int((Double(secs) / 60).rounded()))) min"
    }
}

func clock(_ s: Int) -> String { String(format: "%d:%02d", max(0, s) / 60, max(0, s) % 60) }

// MARK: - Text format (import / export)

private func lines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
}

func parseBody(_ text: String) -> [Item] {
    var items: [Item] = []
    var para: [String] = []
    func flush() {
        if !para.isEmpty { items.append(Item(kind: .p, text: para.joined(separator: " "))) }
        para = []
    }
    for s in lines(text) {
        if s.isEmpty {
            flush()
        } else if let r = s.range(of: #"^[-*]\s+"#, options: .regularExpression) {
            flush()
            items.append(Item(kind: .li, text: String(s[r.upperBound...])))
        } else if s.hasPrefix(">") {
            flush()
            items.append(Item(kind: .cue, text: s.dropFirst().trimmingCharacters(in: .whitespaces)))
        } else {
            para.append(s)
        }
    }
    flush()
    return items
}

/// "# Title" starts a step, "> Show: x" is the on-screen cue, everything else is what to say.
func importSteps(_ text: String) -> [Step] {
    var steps: [Step] = []
    var say: [String] = []
    func close() {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].say = say.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        say = []
    }
    for s in lines(text) {
        if let r = s.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
            close()
            // old scripts numbered their headings ("# 2. Folder structure"); cards are numbered already
            steps.append(Step(title: String(s[r.upperBound...]).replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)))
            continue
        }
        if s.isEmpty && steps.isEmpty { continue }
        if steps.isEmpty { steps.append(Step()) }
        if s.hasPrefix(">") {
            let c = s.dropFirst().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(?i)show:\s*"#, with: "", options: .regularExpression)
            steps[steps.count - 1].cue += (steps[steps.count - 1].cue.isEmpty ? "" : "; ") + c
        } else {
            say.append(s.range(of: #"^-{3,}$"#, options: .regularExpression) != nil ? "" : s)
        }
    }
    close()
    return steps.filter { !$0.title.isEmpty || !$0.say.isEmpty || !$0.cue.isEmpty }
}

func exportText(_ steps: [Step]) -> String {
    steps.enumerated().map { i, s in
        var out = "# \(s.title.isEmpty ? "Step \(i + 1)" : s.title)\n"
        if !s.say.isEmpty { out += s.say + "\n" }
        if !s.cue.isEmpty { out += "> Show: \(s.cue)\n" }
        return out
    }.joined(separator: "\n")
}

func alert(_ title: String, _ detail: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = detail
    a.runModal()
}

// MARK: - Store (scripts + settings, saved to ~/Library/Application Support/Prompter)

final class Store: ObservableObject {
    static let defaultKeys = [
        "next": "CommandOrControl+N",
        "prev": "CommandOrControl+Shift+N",
        "toggleAuto": "CommandOrControl+Alt+A",
        "toggleVisible": "CommandOrControl+Alt+P",
        "toggleLock": "CommandOrControl+Alt+L",
        "stop": "CommandOrControl+Alt+Q",
    ]

    @Published var scripts: [Script] = []
    @Published var selection: UUID?
    @Published var settings = Settings()
    var keys = Store.defaultKeys

    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prompter")
    var configURL: URL { dir.appendingPathComponent("config.json") }
    private var saver: AnyCancellable?

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path), let src = Bundle.main.url(forResource: "config", withExtension: "json") {
            try? fm.copyItem(at: src, to: configURL)
        }
        settings = load(Settings.self, "state.json") ?? Settings()
        if let lib = load(Library.self, "library.json") {
            scripts = lib.scripts
            selection = lib.selection
        }
        if scripts.isEmpty { scripts = [Script(steps: [Step()])] }
        if !scripts.contains(where: { $0.id == selection }) { selection = scripts[0].id }
        loadKeys()
        saver = objectWillChange.debounce(for: .seconds(0.4), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.save() }
    }

    func loadKeys() {
        struct Config: Decodable { var shortcuts: [String: String]? }
        keys = Store.defaultKeys.merging(load(Config.self, "config.json")?.shortcuts ?? [:]) { $1 }
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let v = try? JSONDecoder().decode(type, from: data) { return v }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))  // keep it, don't overwrite
        return nil
    }

    private func write<T: Encodable>(_ v: T, _ name: String) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }

    func save() {
        write(Library(scripts: scripts, selection: selection), "library.json")
        write(settings, "state.json")
    }

    var current: Script? { scripts.first { $0.id == selection } }

    // MARK: scripts

    func newScript() {
        let s = Script(steps: [Step()])
        scripts.append(s)
        selection = s.id
    }

    func duplicate(_ id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        var copy = scripts[i]
        copy.id = UUID()
        copy.name += " copy"
        copy.steps = copy.steps.map { var s = $0; s.id = UUID(); return s }
        scripts.insert(copy, at: i + 1)
        selection = copy.id
    }

    func delete(_ id: UUID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts.remove(at: i)
        if scripts.isEmpty { newScript() } else if selection == id { selection = scripts[min(i, scripts.count - 1)].id }
    }

    func importScript() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText]
        p.message = "Choose a text file. Lines starting with # become steps."
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let steps = importSteps(try String(contentsOf: url, encoding: .utf8))
            let s = Script(name: url.deletingPathExtension().lastPathComponent, steps: steps.isEmpty ? [Step()] : steps)
            scripts.append(s)
            selection = s.id
        } catch {
            alert("Could not import", error.localizedDescription)
        }
    }

    func exportScript() {
        guard let s = current else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = s.name + ".txt"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try exportText(s.steps).write(to: url, atomically: true, encoding: .utf8) } catch {
            alert("Could not export", error.localizedDescription)
        }
    }
}
