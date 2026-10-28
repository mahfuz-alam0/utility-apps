import AppKit
import Combine

/// One run of a script: owns the overlay window, the current step, the Auto-mode timer and the global shortcuts.
final class Session {
    let store: Store
    let win: Overlay
    let view: OverlayView
    var onChange: () -> Void = {}
    var onStop: () -> Void = {}

    private(set) var steps: [Step] = []
    private(set) var index = 0
    private(set) var running = false
    private(set) var playing = false
    private var finished = false
    private var elapsed = 0.0
    private var last = 0.0
    private var left = -1
    private var warnings: [String] = []
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    private var mode: Mode { store.settings.mode }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init(store: Store) {
        self.store = store
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let wa = screen.visibleFrame
        let width = min(780, wa.width - 40)
        var frame = NSRect(x: wa.midX - width / 2, y: wa.maxY - 24 - 230, width: width, height: 230)
        if let f = store.settings.frame, f.count == 4 {
            let saved = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: saved.midX, y: saved.midY)) }) { frame = saved }
        }
        view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        win = Overlay(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.contentView = view
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 360, height: 120)
        view.onAction = { [weak self] in self?.act($0) }
        for n in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: n, object: win, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                let f = self.win.frame
                self.store.settings.frame = [f.minX, f.minY, f.width, f.height].map(Double.init)
            }
        }
        // editor sliders / mode picker update the overlay live; window moves (frame) don't re-render it
        store.$settings.dropFirst()
            .removeDuplicates { var a = $0; a.frame = $1.frame; return a == $1 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &bag)
    }

    // MARK: lifecycle

    func start(_ script: Script, at i: Int) {
        steps = script.steps
        index = min(max(i, 0), steps.count - 1)
        elapsed = 0
        finished = false
        playing = false  // Auto starts paused: get your recording going, then press Play
        running = true
        store.settings.locked = false
        store.loadKeys()
        let k = store.keys
        warnings = registerHotKeys([("next", "next"), ("prev", "prev"), ("toggleAuto", "play"), ("toggleVisible", "visible"),
                                    ("toggleLock", "lock"), ("stop", "stop")].map { cfg, action in
            (name: cfg, accel: k[cfg] ?? "", action: { [weak self] in self?.act(action) })
        })
        last = now
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)  // keeps counting while a menu is open
        timer = t
        win.orderFrontRegardless()
        apply()
    }

    func stop() {
        guard running else { return }
        running = false
        playing = false
        timer?.invalidate()
        timer = nil
        unregisterHotKeys()
        win.orderOut(nil)
        onStop()
    }

    // MARK: actions

    func act(_ name: String) {
        guard running else { return }
        let s = store.settings
        switch name {
        case "next": go(min(steps.count - 1, index + 1))
        case "prev": go(max(0, index - 1))
        case "play": togglePlay()
        case "mode": store.settings.mode = mode == .auto ? .manual : .auto
        case "fontUp": store.settings.fontSize = min(60, s.fontSize + 2)
        case "fontDown": store.settings.fontSize = max(14, s.fontSize - 2)
        case "alphaUp": store.settings.bgAlpha = min(0.9, ((s.bgAlpha + 0.1) * 100).rounded() / 100)
        case "alphaDown": store.settings.bgAlpha = max(0, ((s.bgAlpha - 0.1) * 100).rounded() / 100)
        case "lock": store.settings.locked.toggle()
        case "protect": store.settings.protect.toggle()
        case "visible":
            if win.isVisible { win.orderOut(nil) } else { win.orderFrontRegardless() }
            onChange()
        case "stop": stop()
        default: break
        }
    }

    private func go(_ i: Int) {
        if i != index {
            index = i
            elapsed = 0
            finished = false
            last = now
        }
        push()
    }

    private func togglePlay() {
        guard mode == .auto else { return }
        if finished {
            elapsed = 0
            finished = false
            playing = true
        } else {
            playing.toggle()
        }
        last = now
        push()
    }

    private func tick() {
        let t = now
        defer { last = t }
        guard running, playing, mode == .auto else { return }
        elapsed += t - last
        let d = duration
        if elapsed >= d {
            if index + 1 < steps.count {
                index += 1
                elapsed = 0
            } else {
                playing = false
                finished = true
                elapsed = d
            }
            push()
            return
        }
        view.setProgress(elapsed / d)
        if Int(ceil(d - elapsed)) != left { push() }
    }

    // MARK: rendering

    private var duration: Double { Double(steps[index].duration(wpm: store.settings.wpm)) }

    /// Applies window-level settings, then redraws.
    private func apply() {
        guard running else { return }
        win.sharingType = store.settings.protect ? .none : .readOnly
        win.ignoresMouseEvents = store.settings.locked
        if mode == .manual { playing = false }
        push()
    }

    private func push() {
        guard running, !steps.isEmpty else { return }
        let s = store.settings
        left = Int(ceil(duration - elapsed))
        view.render(Snapshot(
            steps: steps, index: index, fontSize: CGFloat(s.fontSize), bgAlpha: CGFloat(s.bgAlpha),
            locked: s.locked, protect: s.protect, mode: s.mode, playing: playing, finished: finished, left: left,
            warnings: warnings))
        view.setProgress(elapsed / duration)
        onChange()
    }
}
