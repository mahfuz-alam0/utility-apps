import SwiftUI
import AppKit

let brand = Color(red: 1, green: 207.0 / 255, blue: 92.0 / 255)

/// Tiny observable boolean for popover state (`@State` needs the SwiftUIMacros plugin, which Command Line Tools lack).
final class Flag: ObservableObject { @Published var on = false }

func confirm(_ title: String, _ detail: String, ok: String = "Delete") -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = detail
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}

// MARK: - Window content: scripts on the left, steps + run controls on the right

struct EditorView: View {
    @ObservedObject var store: Store
    let start: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private func askDelete(_ id: UUID) {
        let name = store.scripts.first { $0.id == id }?.name ?? ""
        if confirm("Delete “\(name)”?", "The script and all its steps will be lost.") { store.delete(id) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("Prompter").font(.system(size: 20, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            List(selection: $store.selection) {
                Section("Scripts") {
                    ForEach(store.scripts) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name.isEmpty ? "Untitled script" : s.name).lineLimit(1)
                            Text(s.summary(wpm: store.settings.wpm)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Duplicate") { store.duplicate(s.id) }
                            Button("Delete…", role: .destructive) { askDelete(s.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button { store.newScript() } label: { Label("New Script", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var detail: some View {
        if store.scripts.contains(where: { $0.id == store.selection }) {
            ForEach($store.scripts) { $script in
                if script.id == store.selection {
                    ScriptView(script: $script, store: store, start: start, delete: { askDelete(script.id) }).id(script.id)
                }
            }
        } else {
            Text("Select or create a script").foregroundStyle(.secondary)
        }
    }
}

// MARK: - One script: header, text area, run bar

struct ScriptView: View {
    @Binding var script: Script
    @ObservedObject var store: Store
    let start: (Int) -> Void
    let delete: () -> Void
    @StateObject private var display = Flag()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            textArea
            Divider()
            runBar
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Script name", text: $script.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                Text(script.summary(wpm: store.settings.wpm)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { clear() } label: { Label("Clear", systemImage: "trash") }
                .disabled(script.text.isEmpty)
                .help("Remove all the text in this script")
            Menu {
                Button("Duplicate") { store.duplicate(script.id) }
                Button("Import text file…") { store.importScript() }
                Button("Export as text…") { store.exportScript() }
                Divider()
                Button("Delete script…", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $script.text).scrollContentBackground(.hidden)
            if script.text.isEmpty {
                Text(verbatim: "Type or paste your script. Each paragraph (blank line between) becomes a step when you press Start.\n\nOr name steps with “# Title” lines.  “- ” = bullet  ·  **bold** = highlight\n“> Show: text” = on-screen cue  ·  “> Time: 20” = fixed seconds (Auto mode)")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .font(.system(size: 15))
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clear() {
        if confirm("Clear this script?", "All the text in it will be removed.", ok: "Clear") { script.text = "" }
    }

    private var runBar: some View {
        let auto = store.settings.mode == .auto
        let k = store.keys
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Mode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Mode", selection: $store.settings.mode) {
                        Text("Manual").tag(Mode.manual)
                        Text("Auto").tag(Mode.auto)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    if auto {
                        Stepper(value: $store.settings.wpm, in: 80...260, step: 10) {
                            Text("\(store.settings.wpm) words/min").monospacedDigit()
                        }
                    }
                }
                Text(auto
                     ? "Each step advances by itself after the time it takes to say it. Starts paused: press Play or \(pretty(k["toggleAuto"] ?? ""))."
                     : "You move between steps yourself: Next / Prev buttons or \(pretty(k["next"] ?? "")) / \(pretty(k["prev"] ?? "")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { display.on.toggle() } label: { Label("Display", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $display.on, arrowEdge: .top) { DisplayPanel(store: store) }
            Button { start(0) } label: {
                Label("Start prompter", systemImage: "play.fill").foregroundStyle(.black).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(brand)
            .controlSize(.large)
            .disabled(script.steps.isEmpty)
            .help("⌘↩")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

// MARK: - Display popover (live: changes show on the overlay while it runs)

struct DisplayPanel: View {
    @ObservedObject var store: Store
    private let shortcuts = [
        ("next", "Next step"), ("prev", "Previous step"), ("toggleAuto", "Play / pause (Auto)"),
        ("toggleVisible", "Show / hide overlay"), ("toggleLock", "Lock / unlock overlay"), ("stop", "Stop, back to editor"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider("Text size", "\(Int(store.settings.fontSize)) pt", $store.settings.fontSize, 14...60, 2)
            slider("Background", "\(Int(store.settings.bgAlpha * 100))%", $store.settings.bgAlpha, 0...0.9, 0.05)
            Toggle("Hide overlay from screen recordings", isOn: $store.settings.protect)
            Divider()
            Text("Shortcuts while running").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(shortcuts, id: \.0) { key, label in
                HStack {
                    Text(label)
                    Spacer()
                    Text(pretty(store.keys[key] ?? "")).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button("Edit shortcuts (config.json)") { NSWorkspace.shared.open(store.configURL) }
                .buttonStyle(.link)
            Text("Shortcut changes apply the next time you start.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func slider(_ label: String, _ value: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: v, in: range, step: step)
        }
    }
}
