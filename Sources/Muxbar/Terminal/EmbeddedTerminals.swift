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

    init(key: String) {
        self.key = key
        view = EmbeddedSession.makeView()
        super.init()
    }

    static func makeView() -> LocalProcessTerminalView {
        let v = MuxTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        v.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        v.nativeForegroundColor = .textColor
        v.nativeBackgroundColor = .textBackgroundColor
        v.autoresizingMask = [.width, .height]
        return v
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
        state = .running
        Log.info("embedded \(key): started \(executable) \(args.joined(separator: " ")) pid \(pid)")
    }

    /// Retired panes are kept for the app's lifetime. SwiftTerm 1.11.2's `terminate()` races its
    /// own DispatchIO read callback, and freeing a view with a read in flight crashes too
    /// (`LocalProcess.childProcessRead` → `_os_object_retain`). A retired pane costs well under 1 MB.
    private static var graveyard: [LocalProcessTerminalView] = []

    /// Ends a pane's child without touching SwiftTerm's IO: the child exiting closes the pty slave,
    /// and SwiftTerm's reader finishes on its own queue.
    private static func retire(_ v: LocalProcessTerminalView, pid: pid_t) {
        if pid > 0 && !isGoneOrZombie(pid) { kill(pid, SIGHUP) }
        graveyard.append(v)
    }

    func stop() {
        if state == .running, pid > 0, !EmbeddedSession.isGoneOrZombie(pid) { kill(pid, SIGHUP) }
        state = .exited(nil)
    }

    /// The pty may never reach EOF when the child dies (e.g. ssh forked a ControlMaster that keeps
    /// the pty open), so liveness is also checked by pid.
    func checkAlive() {
        guard state == .running, pid > 0 else { return }
        if EmbeddedSession.isGoneOrZombie(pid) {
            state = .exited(nil)
            Log.info("embedded \(key): process \(pid) gone (pid check)")
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
        Task { @MainActor in
            // Ignore the old pane's exit after a restart.
            guard source === self.view else { return }
            self.state = .exited(exitCode)
            Log.info("embedded \(self.key): process exited (\(exitCode.map(String.init) ?? "nil"))")
        }
    }
}

@MainActor
final class EmbeddedTerminals: ObservableObject {
    @Published private(set) var sessions: [String: EmbeddedSession] = [:]
    private var timer: Timer?

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
        sessions[key] = s
        s.start(executable: executable, args: args)
        return .started
    }

    func remove(_ key: String) {
        sessions[key]?.stop()
        sessions[key] = nil
    }

    func stopAll() {
        for s in sessions.values { s.stop() }
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
            w.makeKeyAndOrderFront(nil)
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

/// Terminal view that lets Muxbar run a step before keystrokes reach the process — used to leave
/// tmux history (copy) mode when you start typing while scrolled up.
final class MuxTerminalView: LocalProcessTerminalView {
    /// Return true if the hook took over and will call `deliver` itself.
    var beforeInput: ((_ deliver: @escaping () -> Void) -> Bool)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let hook = beforeInput, hook({ [weak self] in self?.deliver(source: source, data: data) }) { return }
        super.send(source: source, data: data)
    }

    private func deliver(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
    }
}
