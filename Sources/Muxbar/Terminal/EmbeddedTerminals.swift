import AppKit
import MuxbarCore
import SwiftTerm

/// One built-in terminal pane: a real PTY running the tmux attach for a session (or, without
/// tmux, the command itself). Claude Code runs unmodified inside it; Muxbar never reads or sends
/// keystrokes — the pane is just a terminal.
@MainActor
final class EmbeddedSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case running
        case exited(Int32?)
    }

    let key: String
    @Published private(set) var state: State = .running
    @Published private(set) var title: String = ""
    private(set) var view: LocalProcessTerminalView
    private(set) var pid: pid_t = 0
    private(set) var starts = 0

    /// Told when the pane's process ends by itself (not when Muxbar stops it).
    var onExit: ((String) -> Void)?

    init(key: String) {
        self.key = key
        view = EmbeddedSession.makeView()
        super.init()
    }

    static func makeView() -> LocalProcessTerminalView {
        let v = MuxTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        applyColors(to: v)
        v.autoresizingMask = [.width, .height]
        return v
    }

    /// Fixed (non-dynamic) colours for the current appearance. Dynamic system colours like
    /// .textBackgroundColor can resolve to the light variant during partial redraws, which shows
    /// as white flashes; these are re-applied when the appearance changes.
    static func applyColors(to v: LocalProcessTerminalView) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bg = dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let fg = dark ? NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        v.nativeBackgroundColor = bg
        v.nativeForegroundColor = fg
        v.wantsLayer = true
        v.layer?.backgroundColor = bg.cgColor
    }

    /// Starts (or restarts, in a fresh pane) the process.
    func start(executable: String, args: [String]) {
        if starts > 0 {
            let old = view
            EmbeddedSession.retire(old, pid: pid)
            view = EmbeddedSession.makeView()
            old.removeFromSuperview()
        }
        starts += 1
        view.processDelegate = self
        view.startProcess(executable: executable, args: args, environment: EmbeddedSession.environment(),
                          execName: nil)
        pid = view.process.shellPid
        EmbeddedSession.holdSlave(of: view)
        state = .running
        Log.info("embedded \(key): started \(executable) \(args.joined(separator: " ")) pid \(pid)")
    }

    /// Our own fd on each pane's pty slave, so the pty can't reach end-of-file before we let it.
    /// SwiftTerm 1.11.2 handles a child's exit twice: its pty-EOF handler (on its read queue) and
    /// its process-exit handler (main queue) both cancel and release the same dispatch source,
    /// without a lock; when they overlapped the app crashed. Holding the slave means only the exit
    /// handler runs; we let go afterwards (or when the pid check finds the process gone), and the
    /// late EOF then finds the process already marked stopped.
    private static var heldSlaves: [ObjectIdentifier: Int32] = [:]

    static func holdSlave(of v: LocalProcessTerminalView) {
        let master = v.process.childfd
        guard master >= 0, let name = ptsname(master) else { return }
        let fd = open(name, O_RDWR | O_NOCTTY)
        if fd >= 0 { heldSlaves[ObjectIdentifier(v)] = fd }
    }

    static func releaseSlave(of v: AnyObject) {
        if let fd = heldSlaves.removeValue(forKey: ObjectIdentifier(v)) { close(fd) }
    }

    /// Fallback for an exit SwiftTerm never reports (it can miss fast exits): reap the child and
    /// free the pty a few seconds later. Normally its exit handler has released the pty by then,
    /// and releasing earlier could overlap with that handler.
    static func releaseLater(_ v: LocalProcessTerminalView, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard heldSlaves[ObjectIdentifier(v)] != nil else { return }
                var status: Int32 = 0
                if pid > 0 { waitpid(pid, &status, WNOHANG) }
                releaseSlave(of: v)
            }
        }
    }

    /// Retired panes are kept for the app's lifetime. SwiftTerm 1.11.2's `terminate()` races its
    /// own DispatchIO read callback, and freeing a view with a read in flight crashes too
    /// (`LocalProcess.childProcessRead` → `_os_object_retain`). A retired pane costs well under 1 MB.
    private static var graveyard: [LocalProcessTerminalView] = []

    /// Ends a pane's child without touching SwiftTerm's IO: the child exiting closes the pty slave,
    /// and SwiftTerm's reader finishes on its own queue.
    private static func retire(_ v: LocalProcessTerminalView, pid: pid_t) {
        end(pid)
        graveyard.append(v)
        releaseLater(v, pid: pid)
    }

    /// Ends a pane's whole process group (the pane process leads its own group): a remote pane is
    /// `ssh` plus any ProxyCommand. A hang-up first, as closing a terminal does; then
    /// SIGTERM half a second later, because a process started with SIGHUP ignored keeps ignoring it
    /// (OpenSSH only installs its handler if it wasn't), and a pane left running stays attached to
    /// its tmux session. `now` (quitting) sends both at once.
    /// Ends a pane's process group (the pane process leads its own group) with a hang-up, as
    /// closing a terminal does; ssh then shuts down cleanly, ProxyCommand included. SIGTERM follows
    /// half a second later: a process started with SIGHUP ignored keeps ignoring it (OpenSSH only
    /// installs its handler if it wasn't), and a remote pane left running stays attached to its
    /// tmux session. `quitting`: there's no later moment, and an immediate SIGTERM would cut ssh's
    /// clean-up short, so only the hang-up.
    static func end(_ pid: pid_t, quitting: Bool = false) {
        guard pid > 0, !isGoneOrZombie(pid) else { return }
        kill(-pid, SIGHUP)
        if quitting { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { kill(-pid, SIGTERM) }
    }

    func stop(quitting: Bool = false) {
        if state == .running { EmbeddedSession.end(pid, quitting: quitting) }
        state = .exited(nil)
    }

    /// The pty may never reach EOF when the child dies (e.g. ssh forked a ControlMaster that keeps
    /// the pty open), so liveness is also checked by pid.
    func checkAlive() {
        guard state == .running, pid > 0 else { return }
        if EmbeddedSession.isGoneOrZombie(pid) {
            state = .exited(nil)
            EmbeddedSession.releaseLater(view, pid: pid)
            Log.info("embedded \(key): process \(pid) gone (pid check)")
            onExit?(key)
        }
    }

    var isRunning: Bool { state == .running }

    /// Non-reaping liveness check (SwiftTerm does the waitpid): gone, or a zombie awaiting reap.
    static func isGoneOrZombie(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, 4, &info, &size, nil, 0) != 0 || size == 0 { return true }
        let SZOMB: Int8 = 5   // <sys/proc.h>
        return info.kp_proc.p_stat == SZOMB
    }

    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = augmentedPATH + ":" + (env["PATH"] ?? "")
        env.removeValue(forKey: "TMUX")
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: LocalProcessTerminalViewDelegate (called on the main queue by SwiftTerm)

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Runs after SwiftTerm's exit handler has finished (it calls us first, then cleans up).
        Task { @MainActor in
            EmbeddedSession.releaseSlave(of: source)
            // Ignore the old pane's exit after a restart.
            guard source === self.view, self.state == .running else { return }
            self.state = .exited(exitCode)
            Log.info("embedded \(self.key): process exited (\(exitCode.map(String.init) ?? "nil"))")
            self.onExit?(self.key)
        }
    }
}

@MainActor
final class EmbeddedTerminals: ObservableObject {
    @Published private(set) var sessions: [String: EmbeddedSession] = [:]
    private var timer: Timer?
    /// A pane's attach ended by itself (connection dropped, or its tmux session is gone).
    var onPaneExit: ((String) -> Void)?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.checkAlive() } }
        }
    }

    func session(_ key: String) -> EmbeddedSession? { sessions[key] }

    enum AttachOutcome { case started, restarted, alreadyRunning }

    /// Ensures a running pane for `key`; restarts it in place if its process ended.
    func ensure(key: String, executable: String, args: [String]) -> AttachOutcome {
        if let s = sessions[key] {
            if s.isRunning { return .alreadyRunning }
            s.start(executable: executable, args: args)
            objectWillChange.send()
            return .restarted
        }
        let s = EmbeddedSession(key: key)
        s.onExit = { [weak self] k in self?.onPaneExit?(k) }
        sessions[key] = s
        s.start(executable: executable, args: args)
        return .started
    }

    func remove(_ key: String) {
        sessions[key]?.stop()
        sessions[key] = nil
    }

    func recolorAll() {
        for s in sessions.values { EmbeddedSession.applyColors(to: s.view); s.view.needsDisplay = true }
    }

    func stopAll(quitting: Bool = false) {
        for s in sessions.values { s.stop(quitting: quitting) }
    }
}

/// Brings Muxbar's main window forward, recreating it if it was closed.
@MainActor
enum MainWindowPresenter {
    /// SwiftUI's openWindow action, captured from the always-present menu-bar label.
    static var openMain: (() -> Void)?

    static func show() {
        activateApp()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if TestEnv.isTest && !TestEnv.isInteractive { if !w.isVisible { w.orderBack(nil) } } else { w.makeKeyAndOrderFront(nil) }
        } else if let open = openMain {
            open()
        } else {
            // Never NSWorkspace.open(ourselves): it blocks the main thread waiting for a reopen
            // event that only the main thread can deliver (deadlock). This variant is async.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
}

/// What a test instance's clicks did (it never opens a browser or keeps anything on the clipboard).
@MainActor enum ClickTestLog {
    static var opened: [String] = []
    static var copied: [String] = []
}

/// Terminal view that lets Muxbar run a step before keystrokes reach the process — used to leave
/// tmux history (copy) mode when you start typing while scrolled up.
final class MuxTerminalView: LocalProcessTerminalView {
    /// Return true if the hook took over and will call `deliver` itself.
    var beforeInput: ((_ deliver: @escaping () -> Void) -> Bool)?
    /// Files (or a dropped image, saved as a PNG) dropped on the pane (F5).
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// A view moving between containers (single view ↔ grid tile) can be handed a zero or tiny
    /// size for a moment. SwiftTerm would pass that to the pty, shrinking the tmux window to a
    /// column or two, and zsh 5.9 crashed (SIGABRT in its resize redraw) on such a resize. Keep
    /// the last real size until a usable one arrives.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= 60, newSize.height >= 40 else { return }
        super.setFrameSize(newSize)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && Self.hasDroppable(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && Self.hasDroppable(sender.draggingPasteboard) ? .copy : []
    }

    static func hasDroppable(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { handleDrop(sender.draggingPasteboard) }

    /// Files, a file promise (the screenshot thumbnail) or raw image data (saved as a PNG first).
    /// SwiftTerm has no drag handling of its own on macOS, so this is the only one.
    func handleDrop(_ pb: NSPasteboard) -> Bool {
        guard let onDrop else { return false }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDrop(urls)
            return true
        }
        // The screenshot thumbnail (and some apps) send a file promise: receive it into a temp folder.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-drops/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var got: [URL] = []
            let group = DispatchGroup()
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, err in
                    if err == nil { got.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !got.isEmpty { onDrop(got) } }
            return true
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
           let url = try? SessionStore.writeTempPNG(data, name: "dropped.png") {
            onDrop([url])
            return true
        }
        return false
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let hook = beforeInput, hook({ [weak self] in self?.deliver(source: source, data: data) }) { return }
        super.send(source: source, data: data)
    }

    private func deliver(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
    }

    // MARK: Clicks: links open, selections copy

    /// After a click in the pane has been handled (selection made or not): a selection is copied,
    /// a plain click on a web link opens it. Called from the app's mouse monitor.
    func clickFinished(clickCount: Int, dragged: Bool, at locationInWindow: NSPoint) {
        // An app that takes the mouse (with "pass mouse to apps" on) got the click itself.
        if allowMouseReporting && getTerminal().mouseMode != .off { return }
        if dragged || clickCount >= 2 {
            copySelectionToClipboard()
        } else if clickCount == 1, let url = link(atWindowPoint: locationInWindow) {
            if TestEnv.isTest { ClickTestLog.opened.append(url.absoluteString) } else { NSWorkspace.shared.open(url) }
        }
    }

    /// Whether SwiftTerm should not see this ⌘-click: its own ⌘-click opens any URL scheme a
    /// program printed; Muxbar opens web links only.
    func takesCommandClick() -> Bool { !(allowMouseReporting && getTerminal().mouseMode != .off) }

    /// Copies the selected text as soon as a selection is made (drag, double- or triple-click).
    /// Leaves the clipboard alone when nothing ended up selected.
    private func copySelectionToClipboard() {
        let pb = NSPasteboard.general
        // Everything on the clipboard (any type), to put back if nothing was selected — or, in a
        // test instance, always: a test must not leave anything on the user's clipboard.
        let saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        copy(self)
        let text = pb.string(forType: .string) ?? ""
        if TestEnv.isTest { ClickTestLog.copied.append(text) }
        if text.isEmpty || TestEnv.isTest {
            pb.clearContents()
            pb.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (t, d) in pairs { item.setData(d, forType: t) }
                return item
            })
        }
    }

    /// The web link under the pointer: one a program marked (OSC 8), else URL text on screen,
    /// including a URL wrapped onto the following rows.
    /// Window point at the middle of a cell (test hook: clicks at a row and column).
    func windowPoint(col: Int, row: Int) -> NSPoint? {
        let t = getTerminal()
        guard t.cols > 0, t.rows > 0 else { return nil }
        let cell = getOptimalFrameSize()
        let w = cell.width / CGFloat(t.cols), h = cell.height / CGFloat(t.rows)
        return convert(NSPoint(x: (CGFloat(col) + 0.5) * w, y: bounds.height - (CGFloat(row) + 0.5) * h), to: nil)
    }

    private func link(atWindowPoint locationInWindow: NSPoint) -> URL? {
        let t = getTerminal()
        guard t.cols > 0, t.rows > 0 else { return nil }
        let cell = getOptimalFrameSize()
        let w = cell.width / CGFloat(t.cols), h = cell.height / CGFloat(t.rows)
        let p = convert(locationInWindow, from: nil)
        let col = Int(p.x / w), row = Int((bounds.height - p.y) / h)
        guard col >= 0, col < t.cols, row >= 0, row < t.rows else { return nil }
        if let payload = t.getCharData(col: col, row: row)?.getPayload() as? String,
           let i = payload.firstIndex(of: ";"), let url = webURL(String(payload[payload.index(after: i)...])) {
            return url
        }
        let rows = (0..<t.rows).map { r in
            String((0..<t.cols).map { c -> Character in
                let ch = t.getCharData(col: c, row: r)?.getCharacter() ?? " "
                return ch == "\u{0}" ? " " : ch
            })
        }
        return LinkFinder.link(atColumn: col, row: row, rows: rows).flatMap(webURL)
    }

    private func webURL(_ s: String) -> URL? {
        guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }

    /// Input Muxbar itself generates (wheel reports, Page Up/Down) straight to the attached tmux
    /// client: not typing, so it skips the typed-input hook.
    func sendGenerated(_ bytes: [UInt8]) {
        super.send(source: self, data: bytes[...])
    }
}
