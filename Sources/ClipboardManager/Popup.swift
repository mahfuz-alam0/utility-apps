import AppKit
import SwiftUI
import Carbon.HIToolbox

/// UI state lives here, not in @State: the Command Line Tools SDK can't expand SwiftUI's @State macro.
final class PopupModel: ObservableObject {
    enum Tab { case clipboard, emoji }

    static let emojiColumns = 8

    @Published var selected: UUID?  // by id, so new copies / pinning don't move the selection
    @Published var shown = false
    @Published var hovered: UUID?
    @Published var tab = Tab.clipboard
    @Published var query = ""  // typed keys: the panel swallows key events, so there is no real text field
    @Published var emoji = 0  // index into emojis
    @Published var hoveredEmoji: Int?

    var emojis: [Emoji.Entry] {
        let q = query.lowercased()
        return q.isEmpty ? Emoji.all : Emoji.all.filter { $0.name.contains(q) }
    }
}

/// Key but never active: the previously focused app stays frontmost, so ⌘V lands there.
final class Panel: NSPanel {
    var onKey: ((NSEvent) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }  // click outside dismisses
    override func sendEvent(_ e: NSEvent) { e.type == .keyDown ? onKey?(e) : super.sendEvent(e) }
}

final class PopupController {
    private let store: ClipStore
    private let settings: Settings
    private let model = PopupModel()
    private let panel = Panel()
    private var target: NSRunningApplication?  // app that was frontmost when the popup opened: gets the paste

    init(store: ClipStore, settings: Settings) {
        self.store = store
        self.settings = settings
        panel.onKey = { [weak self] in self?.key($0) }
    }

    func toggle() { panel.isVisible ? hide() : show() }
    func hide() { panel.orderOut(nil) }

    private func show() {
        target = NSWorkspace.shared.frontmostApplication
        let pid = target?.processIdentifier
        let caret = settings.openAtCaret ? pid.flatMap(Caret.rect) : nil
        let anchor = caret ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        model.selected = store.items.first?.id
        model.shown = false
        model.tab = .clipboard
        model.query = ""
        model.emoji = 0

        let fx = NSVisualEffectView(frame: panel.contentLayoutRect)
        fx.material = .popover  // follows light/dark
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PopupView(store: store, model: model, settings: settings, pick: pick,
                                                       pickEmoji: { [self] in pick(ClipItem(text: $0)) }))  // own write: not recorded
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        panel.contentView = fx

        panel.setFrameOrigin(origin(near: anchor, size: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    /// Below the anchor (flipped above if it won't fit), clamped to the screen holding the anchor.
    private func origin(near a: NSRect, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(a.origin, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var o = NSPoint(x: a.minX, y: a.minY - size.height - 6)
        if o.y < v.minY { o.y = a.maxY + 6 }
        return NSPoint(x: min(max(o.x, v.minX), v.maxX - size.width), y: min(max(o.y, v.minY), v.maxY - size.height))
    }

    private func emojiKey(_ e: NSEvent) {
        let list = model.emojis
        func move(_ d: Int) { if !list.isEmpty { model.emoji = max(0, min(model.emoji + d, list.count - 1)) } }
        switch Int(e.keyCode) {
        case kVK_RightArrow: move(1)
        case kVK_LeftArrow: move(-1)
        case kVK_DownArrow: move(PopupModel.emojiColumns)
        case kVK_UpArrow: move(-PopupModel.emojiColumns)
        case kVK_Return, kVK_ANSI_KeypadEnter: if list.indices.contains(model.emoji) { pick(ClipItem(text: list[model.emoji].char)) }
        case kVK_Escape: hide()
        case kVK_Delete: if !model.query.isEmpty { model.query.removeLast(); model.emoji = 0 }
        default:
            if let c = e.characters, !c.isEmpty, c.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }) {
                model.query += c
                model.emoji = 0
            }
        }
    }

    private func key(_ e: NSEvent) {
        if Int(e.keyCode) == kVK_Tab { model.tab = model.tab == .emoji ? .clipboard : .emoji; return }
        if model.tab == .emoji { return emojiKey(e) }
        let items = store.items
        let i = items.firstIndex { $0.id == model.selected } ?? 0
        func select(_ j: Int) {
            let n = store.items
            if !n.isEmpty { model.selected = n[max(0, min(j, n.count - 1))].id }
        }
        switch Int(e.keyCode) {
        case kVK_DownArrow: select(i + 1)
        case kVK_UpArrow: select(i - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter: if !items.isEmpty { pick(items[i]) }
        case kVK_Escape: hide()
        case kVK_Delete, kVK_ForwardDelete: if !items.isEmpty { store.remove(items[i]); select(i) }
        case kVK_ANSI_P: if !items.isEmpty { store.togglePin(items[i]) }
        default: break
        }
    }

    private func pick(_ item: ClipItem) {
        store.copyToPasteboard(item)
        hide()
        target?.activate()  // hand key focus back explicitly: the panel took it, ⌘V must land in the target's field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paste.commandV() }  // let focus return first
    }
}

// MARK: - Windows 11 flyout look. Card fills/strokes are dynamic so they follow the light/dark appearance.

extension Color {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let card = dynamic(light: NSColor.white.withAlphaComponent(0.7), dark: NSColor.white.withAlphaComponent(0.06))
    static let cardHover = dynamic(light: NSColor.white.withAlphaComponent(0.95), dark: NSColor.white.withAlphaComponent(0.1))
    static let cardStroke = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.06))
}

struct PopupView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var model: PopupModel
    @ObservedObject var settings: Settings
    let pick: (ClipItem) -> Void
    let pickEmoji: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(.emoji, symbol: "face.smiling", label: "Emoji")
                tabButton(.clipboard, symbol: "doc.on.clipboard", label: "Clipboard history")
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 36)

            if model.tab == .emoji {
                EmojiPicker(model: model, pick: pickEmoji)
            } else {
                HStack {
                    Text("Clipboard history").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if store.items.contains(where: { !$0.pinned }) {
                        Button("Clear all", action: store.clear).buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16).frame(height: 40)

                if settings.paused { pausedBanner }
                if store.items.isEmpty { empty } else { list }
            }
        }
        .frame(width: 360, height: 480)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cardStroke, lineWidth: 1))
        .scaleEffect(model.shown ? 1 : 0.96, anchor: .top)
        .opacity(model.shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.12)) { model.shown = true } }
    }

    private func tabButton(_ tab: PopupModel.Tab, symbol: String, label: String) -> some View {
        let on = model.tab == tab
        return Button { model.tab = tab } label: {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
                .overlay(alignment: .bottom) { if on { Capsule().fill(Color.accentColor).frame(width: 16, height: 2) } }
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text("Recording is paused").font(.system(size: 12))
            Spacer()
            Button("Resume") { settings.paused = false }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.cardStroke))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Nothing copied yet").font(.system(size: 14, weight: .semibold))
            Text("Text and images you copy will show up here").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.items) { item in
                        Row(item: item, store: store, model: model, settings: settings)
                            .id(item.id)
                            .onTapGesture { pick(item) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .onChange(of: model.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
            }
        }
    }
}

struct Row: View {
    let item: ClipItem
    let store: ClipStore
    @ObservedObject var model: PopupModel
    @ObservedObject var settings: Settings

    private var selected: Bool { model.selected == item.id }
    private var hovered: Bool { model.hovered == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = item.text {
                Text(t).font(.system(size: 13)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            } else if let n = item.image {
                // fixed slot: row height must not depend on aspect ratio or on whether the thumbnail has loaded
                Color.primary.opacity(0.05).frame(maxWidth: .infinity).frame(height: 96)
                    .overlay(alignment: .leading) {
                        if let img = store.thumbnail(n) { Image(nsImage: img).resizable().scaledToFit() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if settings.showTimestamps {
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, item.pinned ? 16 : 0)  // room for the pin mark; hover buttons overlay instead so nothing reflows
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected || hovered ? Color.cardHover : Color.card))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(selected ? Color.accentColor : Color.cardStroke, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) { actions }
        .contentShape(Rectangle())
        .onHover { if $0 { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var actions: some View {
        if selected || hovered {
            HStack(spacing: 0) {
                IconButton(symbol: item.pinned ? "pin.slash" : "pin", label: item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
                IconButton(symbol: "xmark", label: "Delete") { store.remove(item) }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(.top, 8).padding(.trailing, 8)
        } else if item.pinned {
            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 12).padding(.trailing, 12)
        }
    }
}

struct EmojiPicker: View {
    @ObservedObject var model: PopupModel
    let pick: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: PopupModel.emojiColumns)

    var body: some View {
        let list = model.emojis
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "Type to search" : model.query)
                    .foregroundStyle(model.query.isEmpty ? Color.secondary : Color.primary)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.card))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.cardStroke))
            .padding(.horizontal, 8).padding(.bottom, 6)

            if list.isEmpty {
                Text("No emoji found").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(list.indices, id: \.self) { i in
                                Text(list[i].char).font(.system(size: 24))
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(RoundedRectangle(cornerRadius: 4)
                                        .fill(i == model.emoji || i == model.hoveredEmoji ? Color.cardHover : Color.clear))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.accentColor, lineWidth: i == model.emoji ? 2 : 0))
                                    .contentShape(Rectangle())
                                    .id(i)
                                    .onTapGesture { pick(list[i].char) }
                                    .onHover { if $0 { model.hoveredEmoji = i } else if model.hoveredEmoji == i { model.hoveredEmoji = nil } }
                                    .accessibilityLabel(list[i].name)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .onChange(of: model.emoji) { _, i in proxy.scrollTo(i) }
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(label)
    }
}
