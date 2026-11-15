import AppKit
import MuxbarCore
import SwiftUI

struct StoreError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

/// Orchestrates polling, persistence, tmux actions and terminal integration. The UI and the
/// `--cli` control socket both drive this one object, so tests exercise the real code paths.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var health: [String: HostHealth] = [:]
    @Published private(set) var live: [String: LiveInfo] = [:]
    @Published var banner: String?
    @Published private(set) var automationDenied = false
    @Published private(set) var pollingActive = true
    @Published private(set) var lastRefresh: [String: Date] = [:]
    @Published private(set) var tmuxVersions: [String: String] = [:]
    /// Host/group to prefill in the New Session window (set by "New Session in Group…").
    @Published var newSessionPrefill: (host: String, group: String?)?
    /// When each waiting session started waiting (for oldest-first ordering).
    @Published private(set) var waitingSince: [String: Date] = [:]
    /// Session shown in the main window's terminal pane.
    @Published private(set) var selectedKey: String?
    /// F10: the grid tile that gets keystrokes.
    @Published var focusedTile: String?
    /// F7: the ⌘K palette is showing (with this query when opened from the CLI).
    @Published var switcherOpen = false
    var switcherQuery = ""
    /// Sessions whose first prompt was already looked up (key + conversation id).
    var firstPromptTried: Set<String> = []
    /// F10: when each visible (not focused) grid tile came on screen while unread; tiles marked
    /// unread by hand while visible stay unread until they leave the screen.
    var tileViewStart: [String: Date] = [:]
    var gridSticky: Set<String> = []
    /// F8: forwardable listening ports per Linux host (from the last probe), and hosts whose
    /// forwards are being set up again.
    @Published var hostPorts: [String: [ListeningPort]] = [:]
    /// F9: a search the History window should run (from the CLI; the window clears it).
    @Published var historyRequest: (query: String, host: String, claudeRoot: String?, codexRoot: String?)?
    var forwardingInFlight: Set<String> = []
    // F2 attention state (not persisted).
    var trackers: [String: Unread.Tracker] = [:]
    var viewStart: [String: Date] = [:]
    var keepUnreadUntilLeft: String?
    /// Test hook: whether Muxbar counts as frontmost (test instances never activate: default yes).
    var viewingOverride: Bool? = TestEnv.isTest ? true : nil
    private var viewTimer: Timer?
    // F3 memory state.
    @Published var hostMemory: [String: HostMemory] = [:]
    @Published var topProcesses: [String: [ProcessUsage]] = [:]
    /// Host whose memory popover is open (also set by clicking a memory alert).
    @Published var memoryPopoverHost: String?
    var memSamples: [String: [MemorySample]] = [:]
    var memAlerts: [String: MemoryAlerts] = [:]
    var memPollers: [String: Task<Void, Never>] = [:]
    var lastPanes: [String: [ProbedPane]] = [:]
    /// Test hook: thresholds that aren't saved (lowered to trigger alerts without filling memory).
    var memThresholdOverride: (warn: Int, crit: Int)?
    // F4: when you last typed in each pane (for auto-sleep), and the auto-sleep timer.
    var lastInput: [String: Date] = [:]
    /// F5: shown while a large drop is being copied to a host.
    @Published var dropProgress: String?
    /// F11: a fresh install that hasn't been through (or skipped) the setup window yet.
    @Published var needsSetup = false
    /// When each session's agent last went idle (screen-based sessions; hooks carry their own time).
    var idleSinceAt: [String: Int] = [:]
    private var autoSleepTask: Task<Void, Never>?
    let embedded = EmbeddedTerminals()
    /// Separate tmux server (`tmux -L`) for test instances; nil = the default server.
    let tmuxSocket = TestEnv.tmuxSocket
    /// Folder of the agents' hook state files on every host (tests use their own).
    let hookDir = TestEnv.value("MUXBAR_HOOK_STATE_DIR").map(shellQuotePath) ?? HostProbe.defaultHookDir
    /// Status-hook installer (F1); only the user's actions call it.
    private(set) lazy var hooks = StatusHooks(runner: { [unowned self] in self.runner() })

    let stateFile: String
    private var pollers: [String: Task<Void, Never>] = [:]
    private var inFlight: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    /// Bumped on settings changes so a refresh never reuses a probe started under old settings.
    private var settingsGeneration = 0
    private var failures: [String: Int] = [:]
    private var openViews = 0
    /// Panes still to reopen from the last launch (cleared per host once restored).
    private var pendingRestore: Set<String> = []
    private var pendingSelection: String?
    private var observers: [NSObjectProtocol] = []

    static let foregroundInterval: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 30

    init(stateFile: String = MuxbarPaths.stateFile) {
        self.stateFile = stateFile
        let (loaded, outcome) = Persistence.load(path: stateFile)
        state = loaded
        if case .recoveredFromCorrupt(let moved) = outcome {
            banner = "Muxbar's saved state was unreadable and has been moved to \(moved). Starting fresh."
        }
        if MuxbarPaths.worstCaseSocketPathLength >= 104 {
            Log.error("ControlPath too long (\(MuxbarPaths.worstCaseSocketPathLength) bytes)")
        }
        for h in state.hosts { health[h] = .unknown }
        pendingRestore = Set(state.openPanes)
        pendingSelection = state.lastSelected
        // Sessions started outside Muxbar stay in "Others" (never in groups).
        var st = state
        if st.forgetTestDirs() > 0 { Log.info("removed test folders from recent folders") }
        if st != state {
            state = st
            try? Persistence.save(st, path: stateFile)
        }
        if st.ejectOutsideFromGroups() > 0 {
            state = st
            try? Persistence.save(st, path: stateFile)
            Log.info("moved sessions started outside Muxbar out of groups into Others")
        }
        // F11: a fresh install gets the setup window; existing installs are just marked as set up.
        if state.settings.setupDone == nil {
            if state.looksFresh { needsSetup = true } else {
                state.settings.setupDone = true
                try? Persistence.save(state, path: stateFile)
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.handleSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.handleWake() }
        })
        startAllPollers()
        viewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.tickViewing() }
        }
        autoSleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SessionStore.autoSleepInterval * 1_000_000_000))
                guard let self, self.pollingActive else { continue }
                await self.autoSleepTick()
            }
        }
    }

    // MARK: Pane history scrolling (tmux copy mode, driven from the scroll bar and wheel)

    @Published private(set) var scrollInfo: [String: TmuxScrollInfo] = [:]
    private var scrollBusy = Set<String>()
    private var scrollQueued: [String: () -> String] = [:]

    private func scrollTarget(_ key: String) -> (SessionRecord, String, String)? {
        guard let rec = state.sessions[key], !rec.ended, let id = rec.tmuxID else { return nil }
        let tmux = rec.host == localHost ? (localTmux.map(shellQuote) ?? "tmux") : "tmux"
        return (rec, id, TmuxCommands.invocation(tmux, socket: tmuxSocket))
    }

    func refreshScrollInfo(_ key: String) async {
        guard let (rec, id, tmux) = scrollTarget(key) else { return }
        let r = await runner().run(host: rec.host, script: TmuxScroll.infoScript(tmux: tmux, id: id), timeout: 10)
        if let info = TmuxScroll.parse(r.stdout) { scrollInfo[key] = info; scrollInfoAt[key] = Date() }
    }

    /// Runs scroll commands one at a time per pane, each followed by the pane's new scroll info
    /// in the same call. Wheel input that arrives meanwhile is added up (`scrollPending`) and sent
    /// as one command when this one returns; of absolute jumps only the latest is kept.
    private func runScroll(_ key: String, _ make: @escaping () -> String) {
        guard let (rec, id, tmux) = scrollTarget(key) else { return }
        if scrollBusy.contains(key) { scrollQueued[key] = make; return }
        scrollBusy.insert(key)
        Task {
            let r = await runner().run(host: rec.host, script: make() + "; " + TmuxScroll.infoScript(tmux: tmux, id: id), timeout: 10)
            if let info = TmuxScroll.parse(r.stdout) { scrollInfo[key] = info }
            scrollBusy.remove(key)
            if let next = scrollQueued.removeValue(forKey: key) { runScroll(key, next) } else { flushScroll(key) }
        }
    }

    /// Wheel lines not sent yet, per pane (positive = up).
    private var scrollPending: [String: Int] = [:]
    /// Wheel lines per Page Up/Down sent to a full-screen app without mouse reporting.
    static let linesPerPage = 8
    /// Wheel lines per wheel event sent to an app with mouse reporting: one, as a terminal sends
    /// them (Claude Code moves 1–2 lines per event, more in quick bursts).
    static let linesPerWheelEvent = 1

    private var wheelRemainder: [String: CGFloat] = [:]

    /// Trackpad points per wheel report sent to an app with mouse reporting. Claude Code moves
    /// about a line per report when they come ≥ 50 ms apart and speeds up when they come faster
    /// (measured: 1.8 lines per report at 16 ms, more over a long swipe): one report per 8 points
    /// gives a steady stream of updates while the distance still follows the finger.
    static let pointsPerWheelReport: CGFloat = 8
    private var reportRemainder: [String: CGFloat] = [:]

    /// One wheel/trackpad event over a pane (`deltaY` > 0 = back in history). An app with mouse
    /// reporting (Claude Code's full-screen view) gets wheel reports straight away, through the
    /// attached client; everything else goes by lines.
    func scrollWheel(_ key: String, deltaY: CGFloat, precise: Bool) {
        guard deltaY != 0 else { return }
        if let info = scrollInfo[key], info.alternate, info.mouse != .off, !scrollBusy.contains(key),
           let v = embedded.session(key)?.view as? MuxTerminalView {
            // A mouse notch is 3 lines, one report per line, as before.
            let acc = (reportRemainder[key] ?? 0) + (precise ? deltaY / Self.pointsPerWheelReport : deltaY * 3)
            let n = Int(acc.rounded(.towardZero))
            reportRemainder[key] = acc - CGFloat(n)
            if n != 0 {
                let t = v.getTerminal()
                v.sendGenerated(TmuxScroll.clientWheelBytes(events: n, col: max(1, t.cols / 2), row: max(1, t.rows / 2)))
            }
            refreshScrollInfoSoon(key)
            return
        }
        // Precise (trackpad) deltas are points; classic wheel deltas are lines.
        let acc = (wheelRemainder[key] ?? 0) + (precise ? deltaY / 16 : deltaY * 3)
        let lines = Int(acc.rounded(.towardZero))
        wheelRemainder[key] = acc - CGFloat(lines)
        if lines != 0 { scrollPane(key, lines: lines) }
    }

    func scrollPane(_ key: String, lines: Int) {
        guard lines != 0, scrollTarget(key) != nil else { return }
        scrollPending[key, default: 0] += lines
        if var i = scrollInfo[key], i.usesTmuxHistory {   // optimistic, so the thumb follows immediately
            i.inMode = true
            i.position = min(i.history, max(0, i.position + lines))
            if i.position == 0 { i.inMode = false }
            scrollInfo[key] = i
        }
        flushScroll(key)
    }

    /// Sends the pending wheel lines the way this pane's app takes them: tmux history (copy mode),
    /// wheel events (mouse reporting), or Page Up / Page Down. Remainders wait for more input.
    private func flushScroll(_ key: String) {
        guard !scrollBusy.contains(key), let pending = scrollPending[key], pending != 0,
              let (_, id, tmux) = scrollTarget(key) else { return }
        guard let info = scrollInfo[key] else {
            // Which kind of pane this is decides what to send: learn it first.
            scrollBusy.insert(key)
            Task { await refreshScrollInfo(key); scrollBusy.remove(key); flushScroll(key) }
            return
        }
        if info.usesTmuxHistory {
            scrollPending[key] = 0
            runScroll(key) { TmuxScroll.scrollScript(tmux: tmux, id: id, lines: pending) }
        } else if info.alternate && info.mouse != .off {
            let events = pending / Self.linesPerWheelEvent
            guard events != 0 else { return }
            scrollPending[key] = pending - events * Self.linesPerWheelEvent
            if let v = embedded.session(key)?.view as? MuxTerminalView {
                // Through the attached client, as a terminal sends it: tmux hands it to the app at
                // once, with no command (or ssh round trip) per step.
                let t = v.getTerminal()
                v.sendGenerated(TmuxScroll.clientWheelBytes(events: events, col: max(1, t.cols / 2), row: max(1, t.rows / 2)))
                refreshScrollInfoSoon(key)
            } else {
                let row = max(1, info.height / 2)
                runScroll(key) { TmuxScroll.wheelScript(tmux: tmux, id: id, events: events, mouse: info.mouse, col: 2, row: row) }
            }
        } else if info.alternate {
            let pages = pending / Self.linesPerPage
            guard pages != 0 else { return }
            scrollPending[key] = pending - pages * Self.linesPerPage
            if let v = embedded.session(key)?.view as? MuxTerminalView {
                v.sendGenerated(TmuxScroll.clientPageBytes(pages: pages))
                refreshScrollInfoSoon(key)
            } else {
                scrollPages(key, pages)
            }
        } else if let t = scrollInfoAt[key], Date().timeIntervalSince(t) < 1 {
            scrollPending[key] = 0   // plain shell with no history (just checked): nothing to scroll
            if Date().timeIntervalSince(scrollNoneLogged[key] ?? .distantPast) > 60 {
                scrollNoneLogged[key] = Date()
                Log.info("scroll: \(state.sessions[key]?.name ?? key) has nothing to scroll (no tmux history, no full-screen app): \(info)")
            }
        } else {
            // What the pane showed may be stale (e.g. Claude switched to its full-screen view after the
            // last look): look again, then send what's pending the right way.
            scrollInfoAt[key] = Date()
            scrollBusy.insert(key)
            Task { await refreshScrollInfo(key); scrollBusy.remove(key); flushScroll(key) }
        }
    }

    private var scrollInfoAt: [String: Date] = [:]
    private var scrollNoneLogged: [String: Date] = [:]
    /// Scrolling sent through the client reads no info back: re-read it now and then, in the
    /// background, so a pane whose app quit or turned the mouse off is noticed.
    private func refreshScrollInfoSoon(_ key: String) {
        if let t = scrollInfoAt[key], Date().timeIntervalSince(t) < 3 { return }
        scrollInfoAt[key] = Date()
        Task { await refreshScrollInfo(key) }
    }

    /// Page Up (positive) / Page Down (negative) to the app in the pane.
    func scrollPages(_ key: String, _ pages: Int) {
        guard pages != 0, let (_, id, tmux) = scrollTarget(key) else { return }
        runScroll(key) { TmuxScroll.pageKeysScript(tmux: tmux, id: id, pages: pages) }
    }

    func scrollPane(_ key: String, toPosition pos: Int) {
        guard let (_, id, tmux) = scrollTarget(key) else { return }
        runScroll(key) { TmuxScroll.gotoScript(tmux: tmux, id: id, position: pos) }
        if var i = scrollInfo[key] { i.position = pos; i.inMode = pos > 0; scrollInfo[key] = i }
    }

    /// Before typed keys reach a scrolled-back pane, return it to live output.
    func leaveHistoryThen(_ key: String, _ deliver: @escaping () -> Void) -> Bool {
        guard let info = scrollInfo[key], info.inMode, !info.atLive, let (rec, id, tmux) = scrollTarget(key) else { return false }
        scrollInfo[key]?.inMode = false
        scrollInfo[key]?.position = 0
        Task {
            _ = await runner().run(host: rec.host, script: TmuxScroll.gotoScript(tmux: tmux, id: id, position: 0), timeout: 10)
            deliver()
        }
        return true
    }

    // MARK: Restore on launch

    /// Reopens last launch's panes for this host once it's reachable, then the selection.
    private func restorePanes(host: String) {
        guard useEmbedded, !pendingRestore.isEmpty else { return }
        let mine = pendingRestore.filter { state.sessions[$0]?.host == host }
        for key in mine {
            pendingRestore.remove(key)
            guard let rec = state.sessions[key], !rec.ended, rec.tmuxID != nil else { continue }
            let (exe, args) = attachProcess(rec)
            _ = embedded.ensure(key: key, executable: exe, args: args)
            wireScrolling(key)
            Log.info("restored pane \(rec.name) on \(host)")
        }
        if let sel = pendingSelection, state.sessions[sel]?.host == host {
            pendingSelection = nil
            if let rec = state.sessions[sel], !rec.ended { select(sel) }
            if state.layout == .grid, gridKeys.contains(sel) { focusedTile = sel }
        }
    }

    // MARK: Resume ended sessions

    /// Brings back a session whose tmux session ended (e.g. after a reboot): same folder, name,
    /// group and section, continuing its agent's conversation — the exact id the hooks recorded,
    /// else (Claude) the newest conversation for that folder, else the agent's "continue last".
    @discardableResult
    func resumeEnded(key: String) async throws -> SessionRecord {
        guard let old = state.sessions[key] else { throw StoreError("Session not found") }
        guard old.ended else { throw StoreError("\(old.name) is still running") }
        let folder = old.managedDir ?? old.path ?? "~"
        let agent = old.agent ?? .claude
        var convID = old.resumeID
        if convID == nil && agent == .claude {
            convID = await newestConversation(host: old.host, folder: folder)
        }
        let cmd: String
        if let id = convID, ClaudeConversations.isValidSessionID(id) {
            cmd = AgentAdapter.resumeCommand(agent, sessionID: id, cwd: agent == .codex ? folder : nil, flags: [])
        } else {
            cmd = agent == .codex ? "codex resume --last" : "claude --continue"
        }
        // Free the name first so the new session gets it back.
        mutate { $0.sessions[key] = nil }
        do {
            let group = (!old.isOutside && old.group.map { state.hasGroup($0, host: old.host) } == true) ? old.group : nil
            try await runOnHost(old.host, Workspace.mkdirScript(folder), what: "recreate session folder")
            var rec = try await newSession(host: old.host, dir: folder, name: old.name, command: cmd, group: group)
            rec.managedDir = old.managedDir   // same workspace folder as before (still follows renames)
            rec.agent = agent
            rec.agentSessionID = convID
            if agent == .claude { rec.claudeSessionID = convID }
            rec.origin = old.isOutside ? .outside : .muxbar   // Others stay in Others
            rec.note = old.note
            rec.tags = old.tags
            let saved = rec
            mutate { $0.sessions[saved.key] = saved }
            Log.info("resumed ended session \(old.name) on \(old.host) with: \(cmd)")
            return saved
        } catch {
            mutate { $0.sessions[key] = old }   // put the ended record back
            throw error
        }
    }

    /// Newest Claude conversation recorded for `folder` on `host` (Claude stores the real path,
    /// e.g. /private/tmp/… for /tmp/…, so both spellings are compared).
    func newestConversation(host: String, folder: String) async -> String? {
        let r = await runner().run(host: host, script: "cd \(shellQuotePath(folder)) 2>/dev/null && pwd -P && pwd", timeout: 15)
        let paths = Set(r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !paths.isEmpty, let list = try? await conversations(host: host, limit: 200) else { return nil }
        return list.first { c in c.cwd.map { paths.contains($0) } ?? false }?.id   // list is newest first
    }

    // MARK: Needs input

    /// Waiting sessions across every host and group, oldest wait first.
    var waitingSessions: [SessionRecord] {
        state.sessions.values.filter { status(of: $0) == .waiting && !$0.archived }
            .sorted { (waitingSince[$0.key] ?? .distantFuture, $0.name) < (waitingSince[$1.key] ?? .distantFuture, $1.name) }
    }

    func location(of rec: SessionRecord) -> String {
        let h = hostLabel(rec.host)
        if let g = rec.group, state.hasGroup(g, host: rec.host) { return "\(h) · \(g)" }
        return h
    }

    func waitingCount(group: String, host: String) -> Int {
        sessions(inGroup: group, host: host).filter { status(of: $0) == .waiting }.count
    }

    /// ⌘J: the next session in the Inbox after the selected one — waiting ones (oldest first), then
    /// finished and unread (newest first) — wrapping round.
    @discardableResult
    func focusNextWaiting() async throws -> SessionRecord? {
        let list = inbox
        guard !list.isEmpty else { return nil }
        let next: SessionRecord
        if let cur = selectedKey, let i = list.firstIndex(where: { $0.key == cur }) {
            next = list[(i + 1) % list.count]
        } else {
            next = list[0]
        }
        _ = try await focus(key: next.key)
        return next
    }

    // MARK: Derived

    var settings: AppSettings { state.settings }

    func sessions(for host: String) -> [SessionRecord] {
        state.sessions.values.filter { $0.host == host && !$0.archived }
            .sorted { ($0.ended ? 1 : 0, $0.name.lowercased()) < ($1.ended ? 1 : 0, $1.name.lowercased()) }
    }

    func status(of rec: SessionRecord) -> SessionStatus {
        if rec.ended { return .ended }
        return live[rec.key]?.status ?? .unknown
    }

    var localTmux: String? { state.settings.disableLocalTmux ? nil : findLocalTmux() }

    /// Test instances poll faster (`MUXBAR_FAST_POLL` seconds) to measure status lag.
    private let fastPoll = TestEnv.value("MUXBAR_FAST_POLL").flatMap(TimeInterval.init)
    var interval: TimeInterval { fastPoll ?? (openViews > 0 ? Self.foregroundInterval : Self.backgroundInterval) }

    // MARK: Persistence

    func mutate(_ f: (inout AppState) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        // A pane outlives selection changes, but not its session record.
        for key in embedded.sessions.keys where s.sessions[key] == nil { embedded.remove(key) }
        do { try Persistence.save(s, path: stateFile) } catch {
            Log.error("saving state failed: \(error)")
            banner = "Couldn't save Muxbar state: \(error.localizedDescription)"
        }
    }

    // MARK: Polling

    func viewAppeared() {
        openViews += 1
        if openViews == 1 { refreshAll() }
    }

    func viewDisappeared() { openViews = max(0, openViews - 1) }

    private func startAllPollers() {
        for h in state.hosts { startPoller(h) }
    }

    private func startPoller(_ host: String) {
        pollers[host]?.cancel()
        pollers[host] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.pollingActive { await self.refresh(host: host, coalesce: true) }
                let delay = self.nextDelay(host)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Backoff while a host is failing: 5s → 15s → 60s (never faster than the normal interval).
    private func nextDelay(_ host: String) -> TimeInterval {
        let f = failures[host] ?? 0
        let backoff: TimeInterval = f == 0 ? 0 : (f == 1 ? 5 : (f == 2 ? 15 : 60))
        return max(interval, backoff)
    }

    func refreshAll() {
        for h in state.hosts { Task { await refresh(host: h) } }
    }

    func handleSleep() {
        pollingActive = false
        Log.info("sleep: polling paused")
    }

    func handleWake() {
        pollingActive = true
        Log.info("wake: polling resumed")
        refreshAll()
    }

    func runner() -> SystemRunner { SystemRunner(sshConfigFile: state.settings.sshConfigFile) }

    /// Refreshes a host; concurrent callers share the in-flight probe instead of skipping it.
    /// - Parameter coalesce: background polls may reuse an in-flight probe. Everyone else (actions,
    ///   explicit refresh) needs results that include changes made *before* the call, so they wait
    ///   for any in-flight probe and then probe again.
    func refresh(host: String, coalesce: Bool = false) async {
        if let running = inFlight[host] {
            await running.task.value
            if coalesce && running.generation == settingsGeneration { return }
            if let again = inFlight[host], again.task != running.task { await again.task.value; if coalesce { return } }
        }
        let gen = settingsGeneration
        let t = Task { await self.performRefresh(host: host) }
        inFlight[host] = (gen, t)
        await t.value
        if inFlight[host]?.generation == gen { inFlight[host] = nil }
    }

    /// The status-probe script for `host` and its nonce (also used by the benchmark test hook).
    func probeScript(host: String, mode: HostProbe.Mode = .status) -> (String, String)? {
        if host == localHost && localTmux == nil { return nil }
        let tmux = host == localHost ? shellQuote(localTmux!) : "tmux"
        let nonce = HostProbe.makeNonce()
        return (HostProbe.script(mode: mode, nonce: nonce, tmux: tmux, socket: tmuxSocket, hookDir: hookDir), nonce)
    }

    private func performRefresh(host: String) async {
        guard state.hosts.contains(host) else { return }

        if host == localHost {
            refreshPlainTabs()
            if localTmux == nil {
                health[host] = .tmuxMissing
                lastRefresh[host] = Date()
                return
            }
        }
        guard let (script, nonce) = probeScript(host: host) else { return }
        let r = await runner().run(host: host, script: script, timeout: 20)
        lastRefresh[host] = Date()
        guard state.hosts.contains(host) else { return }
        if !r.ok {
            failures[host, default: 0] += 1
            let detail = cleanSSHStderr(r.stderr)
            Log.error("probe \(host) failed (exit \(r.exitCode), timedOut \(r.timedOut)): \(detail)")
            switch classifySSHFailure(stderr: r.stderr, exitCode: r.exitCode, timedOut: r.timedOut) {
            case .authExpired: health[host] = .authExpired(detail)
            case .unreachable, .other:
                health[host] = .unreachable(r.timedOut ? "Timed out after 20s" : (detail.isEmpty ? "ssh exit \(r.exitCode)" : detail))
            }
            return
        }
        do {
            let probe = try HostProbe.parse(r.stdout, nonce: nonce)
            failures[host] = 0
            if let v = probe.tmuxVersion { tmuxVersions[host] = v }
            if probe.tmuxMissing { health[host] = .tmuxMissing; return }
            if let v = probe.tmuxVersion, !tmuxVersionSupported(v) { health[host] = .tmuxTooOld(v); return }
            health[host] = .ok
            lastPanes[host] = probe.panes
            if let m = probe.memory { recordMemory(host: host, m) }
            var newLive: [String: LiveInfo] = [:]
            mutate { st in newLive = Reconciler.apply(probe, host: host, to: &st) }
            var l = live.filter { k, _ in state.sessions[k]?.host != host }
            l.merge(newLive) { $1 }
            let before = live
            live = l
            for (k, v) in l where state.sessions[k]?.host == host {
                if v.status == .waiting { if waitingSince[k] == nil { waitingSince[k] = Date() } } else { waitingSince[k] = nil }
            }
            clearSleepIfAgentBack(host: host)
            let events = processAttention(host: host, before: before, after: l)
            Attention.shared.update(store: self, before: before, after: l, events: events)
            restorePanes(host: host)
            if let p = probe.ports, host != localHost { updatePorts(host: host, p) }
            ensureForwards(host: host)
        } catch {
            failures[host, default: 0] += 1
            Log.error("probe \(host) output unparseable: \(error)")
            health[host] = .unreachable("Probe output was cut off")
        }
    }

    /// L1: plain local tabs (no tmux). Liveness = a claude process on the tab's tty.
    private func refreshPlainTabs() {
        let plain = state.sessions.values.filter { $0.host == localHost && $0.isPlainTab }
        guard !plain.isEmpty else { return }
        Task {
            for rec in plain {
                if let e = embedded.session(rec.key) {
                    live[rec.key] = LiveInfo(status: e.isRunning ? .running : .notRunning, attached: 1, command: nil)
                    continue
                }
                guard let tty = rec.tab?.tty else { continue }
                let r = await runProcess("/bin/ps", ["-o", "comm=", "-t", (tty as NSString).lastPathComponent], timeout: 5)
                let running = r.stdout.split(separator: "\n").map(String.init).contains(where: StatusClassifier.isClaudeProcess)
                live[rec.key] = LiveInfo(status: running ? .running : .notRunning, attached: 1, command: nil)
            }
        }
    }

    // MARK: Hosts

    func availableSSHHosts() -> [String] {
        parseSSHHosts(configPath: state.settings.sshConfigFile ?? (NSHomeDirectory() + "/.ssh/config"))
    }

    func addHost(_ host: String) {
        guard !host.isEmpty, !state.hosts.contains(host) else { return }
        mutate { $0.hosts.append(host) }
        health[host] = .unknown
        startPoller(host)
    }

    func removeHost(_ host: String) {
        guard host != localHost else { return }
        dropForwards(host: host)
        hostPorts[host] = nil
        pollers[host]?.cancel()
        pollers[host] = nil
        health[host] = nil
        mutate { st in
            st.hosts.removeAll { $0 == host }
            st.sessions = st.sessions.filter { $0.value.host != host }
            st.groups[host] = nil
        }
    }

    func updateSettings(_ f: (inout AppSettings) -> Void) {
        mutate { f(&$0.settings) }
        settingsGeneration += 1
        applyMousePolicy()
        refreshAll()
    }

    // MARK: Lookup

    /// Resolves a record by key, tmux `$id`, or exact name (live sessions first).
    func resolve(host: String, ref: String) throws -> SessionRecord {
        if let r = state.sessions[ref] { return r }
        let candidates = state.sessions.values.filter { $0.host == host }
        if let r = candidates.first(where: { $0.tmuxID == ref && !$0.ended }) { return r }
        let byName = candidates.filter { $0.name == ref }
        if let r = byName.first(where: { !$0.ended }) ?? byName.first { return r }
        throw StoreError("No session '\(ref)' on \(host)")
    }

    // MARK: Actions

    private func driver() -> TerminalDriver { makeDriver(state.settings.terminal) }
    private var useEmbedded: Bool { state.settings.terminal == .embedded }

    /// Executable + args that attach to a tmux session (run inside the built-in pane).
    private func attachProcess(_ rec: SessionRecord) -> (String, [String]) {
        let id = rec.tmuxID ?? ""
        if rec.host == localHost {
            return (localTmux ?? "/usr/bin/false", (tmuxSocket.map { ["-L", $0] } ?? []) + ["attach-session", "-t", id])
        }
        var args: [String] = []
        if let f = state.settings.sshConfigFile { args += ["-F", f] }
        args += ["-t", rec.host, TmuxCommands.remoteAttach(id: id, socket: tmuxSocket)]
        return ("/usr/bin/ssh", args)
    }

    /// Selects a session in the main window (built-in terminal), attaching if needed.
    /// Persists open panes + selection so the next launch can restore them.
    func rememberPanes() {
        // Include panes still waiting to be restored (their host may not be back yet).
        let open = Set(embedded.sessions.keys).union(pendingRestore).filter { state.sessions[$0] != nil }.sorted()
        let sel = selectedKey.flatMap { state.sessions[$0] != nil ? $0 : nil }
        guard open != state.openPanes || sel != state.lastSelected else { return }
        mutate { $0.openPanes = open; $0.lastSelected = sel }
    }

    @discardableResult
    func select(_ key: String?) -> FocusOutcome? {
        defer { rememberPanes() }
        guard let key, state.sessions[key] != nil else { selectedKey = key; return nil }
        selectedKey = key
        mutate { $0.sessions[key]?.lastViewedAt = Int(Date().timeIntervalSince1970) }
        return attachPane(key)
    }

    /// The sidebar selection without attaching (a grid tile that's already open).
    func setSelection(_ key: String?) { selectedKey = key }

    /// Opens (attaches) a session's built-in pane without changing the selection; grid tiles use it.
    @discardableResult
    func attachPane(_ key: String) -> FocusOutcome? {
        guard let rec = state.sessions[key], !rec.ended else { return nil }
        if rec.isPlainTab {
            if embedded.session(key) == nil, rec.tab == nil {
                let cmd = "cd \(shellQuotePath(rec.path ?? "~")) && exec \"${SHELL:-/bin/zsh}\" -l"
                _ = embedded.ensure(key: key, executable: "/bin/zsh", args: ["-lc", cmd])
                return .openedNew
            }
            return .focused
        }
        let (exe, args) = attachProcess(rec)
        let outcome: FocusOutcome
        switch embedded.ensure(key: key, executable: exe, args: args) {
        case .started: outcome = .openedNew
        case .restarted: outcome = .reattachedInPlace
        case .alreadyRunning: outcome = .focused
        }
        wireScrolling(key)
        return outcome
    }

    /// Mouse policy for every pane: Muxbar keeps the mouse (selection + ⌘C) unless the user lets
    /// apps have it; holding ⌥ always gives selection back.
    func applyMousePolicy(optionDown: Bool = NSEvent.modifierFlags.contains(.option)) {
        let pass = state.settings.passMouseToApps && !optionDown
        for e in embedded.sessions.values { e.view.allowMouseReporting = pass }
    }

    func wireScrolling(_ key: String) {
        embedded.session(key)?.view.allowMouseReporting = state.settings.passMouseToApps && !NSEvent.modifierFlags.contains(.option)
        guard let v = embedded.session(key)?.view as? MuxTerminalView else { return }
        v.beforeInput = { [weak self] deliver in
            self?.lastInput[key] = Date()
            return self?.leaveHistoryThen(key, deliver) ?? false
        }
        v.onDrop = { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                do { try await self.drop(key, files: urls) } catch let e as DropError where e.message.contains("confirm") {
                    if Actions.confirmLargeDrop(e.message) { _ = try? await self.drop(key, files: urls, confirmed: true) }
                } catch { self.banner = error.localizedDescription }
            }
        }
    }

    func runTmux(host: String, _ script: String) async throws -> String {
        let r = await runner().run(host: host, script: script, timeout: 20)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            Log.error("tmux command on \(host) failed (exit \(r.exitCode)): \(msg)")
            throw StoreError(msg.isEmpty ? "Command failed on \(host) (exit \(r.exitCode))" : msg)
        }
        return r.stdout
    }

    /// tmux as shell text for scripts on `host` (quoted local path, plus `-L` on test instances).
    func tmuxPath(_ host: String) throws -> String {
        if host != localHost { return TmuxCommands.invocation("tmux", socket: tmuxSocket) }
        guard let t = localTmux else { throw StoreError("tmux isn't installed locally") }
        return TmuxCommands.invocation(shellQuote(t), socket: tmuxSocket)
    }

    private func attachCommand(_ rec: SessionRecord) -> String {
        if rec.host == localHost { return TmuxCommands.attachLocal(tmux: localTmux ?? "tmux", id: rec.tmuxID ?? "", socket: tmuxSocket) }
        return TmuxCommands.attachRemote(host: rec.host, id: rec.tmuxID ?? "", sshConfigFile: state.settings.sshConfigFile,
                                         socket: tmuxSocket)
    }

    private func terminalCall<T>(_ f: () throws -> T) throws -> T {
        do {
            let v = try f()
            automationDenied = false
            return v
        } catch let e as TerminalError where e.isAutomationDenied {
            automationDenied = true
            banner = "Muxbar isn't allowed to control \(state.settings.terminal.displayName). Enable it in System Settings → Privacy & Security → Automation → Muxbar."
            throw StoreError(banner!)
        }
    }

    @discardableResult
    func newSession(host: String, dir: String, name rawName: String, command: String?, group: String? = nil,
                    attach: Bool = true, createFolder: Bool = false) async throws -> SessionRecord {
        guard state.hosts.contains(host) else { throw StoreError("Unknown host \(host)") }
        if let g = group, !state.hasGroup(g, host: host) {
            throw StoreError("No group '\(g)' on \(hostLabel(host)) — groups belong to one host")
        }
        // A taken name gets -2, -3 … instead of failing with tmux's "duplicate session".
        if host != localHost || localTmux != nil { await refresh(host: host) }
        let base = sanitizeSessionName(rawName)
        let taken = Set(state.sessions.values.filter { $0.host == host && !$0.ended }.map(\.name))
        var name = base, n = 2
        while taken.contains(name) { name = "\(base)-\(n)"; n += 1 }
        // No command = a plain login shell; the user runs whatever they like in it.
        let cmd: String? = (command?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? command : nil
        // No folder given → the session's workspace folder <root>/<group>/<name>, created now.
        let requested = dir
        var managed: String?
        let dir: String
        if requested.trimmingCharacters(in: .whitespaces).isEmpty {
            let p = Workspace.path(root: workspaceRoot(host), group: group, session: name)
            try await runOnHost(host, Workspace.mkdirScript(p), what: "create workspace folder")
            managed = p
            dir = p
        } else {
            dir = requested
            // A folder typed in New Session that doesn't exist yet is made first (shown as
            // "will be created" there).
            if createFolder { try await runOnHost(host, Workspace.mkdirScript(requested), what: "create folder \(requested)") }
        }

        if host == localHost && localTmux == nil {
            // L1: no tmux — a plain pane/window; it won't survive being closed (or Muxbar quitting).
            let key = "\(localHost)|tab|\(UUID().uuidString)"
            var tab: TabRef?
            let run = cmd.map { "env \(TmuxCommands.titleEnv) \($0); " } ?? ""
            if !useEmbedded {
                let line = "cd \(shellQuotePath(dir)) && \(run)exec \"${SHELL:-/bin/zsh}\" -l"
                tab = try terminalCall { try driver().open(command: line, title: name) }
            }
            var rec = SessionRecord(key: key, host: localHost, tmuxID: nil,
                                    created: Int(Date().timeIntervalSince1970), name: name, path: dir, tab: tab)
            rec.lastActivity = rec.created
            rec.group = group
            rec.managedDir = managed
            rec.origin = .muxbar
            mutate { $0.sessions[key] = rec; $0.rememberDir(dir, host: host) }
            if useEmbedded {
                let line = "cd \(shellQuotePath(dir)) && \(run)exec \"${SHELL:-/bin/zsh}\" -l"
                _ = embedded.ensure(key: key, executable: "/bin/zsh", args: ["-lc", line])
                wireScrolling(key)
                selectedKey = key
                MainWindowPresenter.show()
            }
            return rec
        }

        // A test instance's agents report to its own hook folder, never the user's.
        let paneCmd = TestEnv.value("MUXBAR_HOOK_STATE_DIR").map { "env MUXBAR_STATE_DIR=\(shellQuotePath($0)) " + (cmd ?? "\"${SHELL:-/bin/sh}\" -l") } ?? cmd
        let out = try await runTmux(host: host, TmuxCommands.newSession(tmux: try tmuxPath(host), name: name, dir: dir, command: paneCmd))
        guard let id = out.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }), id.hasPrefix("$") else {
            throw StoreError("tmux didn't return a session id")
        }
        mutate { $0.rememberDir(dir, host: host) }
        await refresh(host: host)
        guard var rec = state.sessions.values.first(where: { $0.host == host && $0.tmuxID == id && !$0.ended }) else {
            throw StoreError("Created \(id) on \(host) but it didn't show up in tmux")
        }
        rec.group = group
        rec.managedDir = managed
        rec.origin = .muxbar
        let created = rec
        mutate { $0.sessions[created.key] = created }
        if attach && useEmbedded {
            select(rec.key)
            MainWindowPresenter.show()
        } else if attach {
            let cmdLine = attachCommand(rec)
            rec.tab = try terminalCall { try driver().open(command: cmdLine, title: rec.name) }
            let saved = rec
            mutate { $0.sessions[saved.key] = saved }
        }
        return rec
    }

    func rename(key: String, to rawName: String) async throws -> SessionRecord {
        guard var rec = state.sessions[key], !rec.ended else { throw StoreError("Session not found or ended") }
        let name = sanitizeSessionName(rawName)
        // Workspace folder follows the name. Move first: if the target exists, nothing changes.
        var newDir: String?
        if let old = rec.managedDir {
            let target = Workspace.path(root: ownRoot(rec, old), group: rec.group, session: name)
            try await runOnHost(rec.host, Workspace.moveScript(from: old, to: target), what: "rename workspace folder")
            newDir = target
        }
        if let id = rec.tmuxID {
            do {
                _ = try await runTmux(host: rec.host, TmuxCommands.rename(tmux: try tmuxPath(rec.host), id: id, newName: name))
            } catch {
                if let nd = newDir, let old = rec.managedDir {   // undo the folder move
                    try? await runOnHost(rec.host, Workspace.moveScript(from: nd, to: old), what: "undo folder rename")
                }
                throw error
            }
        }
        if let nd = newDir { rec.managedDir = nd; rec.path = nd }
        rec.name = name
        let saved = rec
        mutate { $0.sessions[saved.key] = saved }
        if let tab = rec.tab, tab.kind == state.settings.terminal {
            do { try terminalCall { try driver().setTitle(tab, name) } } catch {
                Log.error("rename: title update failed: \(error)")
            }
        }
        if rec.tmuxID != nil { await refresh(host: rec.host) }
        return state.sessions[key] ?? rec
    }

    enum FocusOutcome: String { case focused, reattachedInPlace, openedNew }

    func focus(key: String) async throws -> FocusOutcome {
        guard var rec = state.sessions[key] else { throw StoreError("Session not found") }
        if rec.ended { throw StoreError("\(rec.name) has ended") }
        if useEmbedded {
            let outcome = select(key) ?? .focused
            MainWindowPresenter.show()
            // Opening a sleeping session wakes its agent (Settings → Wake when opened).
            if rec.sleep != nil && settings.wakeOnOpen {
                Task { do { try await self.wake(key) } catch { self.banner = error.localizedDescription } }
            }
            return outcome
        }
        let d = driver()

        if rec.isPlainTab {
            guard let tab = rec.tab else { throw StoreError("This window was closed") }
            try terminalCall { try d.bringToFront(tab) }
            return .focused
        }

        let attach = attachCommand(rec)
        let ps = await runProcess("/bin/ps", ["-axo", "command="], timeout: 5).stdout
        let alive = hasLiveAttachClient(psOutput: ps, host: rec.host, tmuxID: rec.tmuxID ?? "", socket: tmuxSocket)
        var outcome = FocusOutcome.openedNew

        if let tab = rec.tab, tab.kind == d.kind, let found = try terminalCall({ try d.locate(tab, title: rec.name) }) {
            if found.safeToReattach {
                // Tab sits at a prompt (e.g. after a VPN drop): reattach right there.
                try terminalCall { try d.run(command: attach, in: found.ref) }
                rec.tab = found.ref
                outcome = .reattachedInPlace
            } else if alive {
                try terminalCall { try d.bringToFront(found.ref) }
                rec.tab = found.ref
                outcome = .focused
            } else {
                // Tab is busy with something else; never type into it.
                rec.tab = try terminalCall { try d.open(command: attach, title: rec.name) }
            }
        } else {
            rec.tab = try terminalCall { try d.open(command: attach, title: rec.name) }
        }
        let saved = rec
        mutate { $0.sessions[saved.key] = saved }
        return outcome
    }

    /// Closes the pane only; the tmux session keeps running and can be reopened from the list.
    func closePane(key: String) {
        embedded.remove(key)
        if selectedKey == key { selectedKey = nil }
        rememberPanes()
    }

    func kill(key: String) async throws {
        guard let rec = state.sessions[key] else { throw StoreError("Session not found") }
        embedded.remove(key)
        if selectedKey == key { selectedKey = nil }
        defer { rememberPanes() }
        if let id = rec.tmuxID, !rec.ended {
            _ = try await runTmux(host: rec.host, TmuxCommands.kill(tmux: try tmuxPath(rec.host), id: id))
            Log.info("killed \(rec.name) (\(id)) on \(rec.host)")
        }
        mutate { $0.sessions[key] = nil }
        live[key] = nil
        if rec.tmuxID != nil { await refresh(host: rec.host) }
    }

    // MARK: Groups (sidebar tree)

    @discardableResult
    func createGroup(host: String, _ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.hosts.contains(host) else { throw StoreError("Unknown host \(host)") }
        guard !name.isEmpty else { throw StoreError("Group name can't be empty") }
        guard !state.hasGroup(name, host: host) else { throw StoreError("Group '\(name)' already exists on \(hostLabel(host))") }
        mutate { $0.groups[host, default: []].append(name) }
        return name
    }

    func renameGroup(host: String, _ old: String, to raw: String) async throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.hasGroup(old, host: host) else { throw StoreError("No group '\(old)' on \(hostLabel(host))") }
        guard !name.isEmpty else { throw StoreError("Group name can't be empty") }
        guard name == old || !state.hasGroup(name, host: host) else { throw StoreError("Group '\(name)' already exists on \(hostLabel(host))") }
        // The group folder follows the name (only where members live in workspace folders). Members
        // made under an earlier root keep it, so there can be one group folder per root.
        let roots = Set(state.sessions.values.compactMap { r -> String? in
            guard r.host == host, r.group == old, let d = r.managedDir else { return nil }
            return Workspace.rootOf(managedDir: d, group: old)
        }).sorted()
        var moved: [(from: String, to: String)] = []
        for root in roots {
            let from = Workspace.groupPath(root: root, group: old), to = Workspace.groupPath(root: root, group: name)
            guard from != to else { continue }
            do {
                try await runOnHost(host, Workspace.moveScript(from: from, to: to), what: "rename group folder")
                moved.append((from, to))
            } catch {
                for m in moved.reversed() {   // all or nothing
                    try? await runOnHost(host, Workspace.moveScript(from: m.to, to: m.from), what: "undo group folder rename")
                }
                throw error
            }
        }
        mutate { st in
            st.groups[host] = st.groups(for: host).map { $0 == old ? name : $0 }
            for k in st.sessions.keys where st.sessions[k]?.host == host && st.sessions[k]?.group == old {
                st.sessions[k]?.group = name
                if let d = st.sessions[k]?.managedDir, let root = Workspace.rootOf(managedDir: d, group: old),
                   let nd = Workspace.rebase(d, from: Workspace.groupPath(root: root, group: old),
                                             to: Workspace.groupPath(root: root, group: name)) {
                    st.sessions[k]?.managedDir = nd
                    st.sessions[k]?.path = nd
                }
            }
        }
    }

    /// Deletes the group only; its sessions stay running under the host, their workspace folders
    /// move back to <root>/<session>, and the group folder is removed only if it's then empty.
    func deleteGroup(host: String, _ name: String) async throws {
        guard state.hasGroup(name, host: host) else { throw StoreError("No group '\(name)' on \(hostLabel(host))") }
        var roots: Set<String> = [workspaceRoot(host)]
        for rec in state.sessions.values where rec.host == host && rec.group == name {
            if let d = rec.managedDir, let r = Workspace.rootOf(managedDir: d, group: name) { roots.insert(r) }
            try await moveWorkspace(rec.key, toGroup: nil)
        }
        for root in roots.sorted() {
            try? await runOnHost(host, Workspace.rmdirIfEmptyScript(Workspace.groupPath(root: root, group: name)),
                                 what: "remove empty group folder")
        }
        mutate { st in
            st.groups[host] = st.groups(for: host).filter { $0 != name }
            if st.groups[host]?.isEmpty == true { st.groups[host] = nil }
            for k in st.sessions.keys where st.sessions[k]?.host == host && st.sessions[k]?.group == name {
                st.sessions[k]?.group = nil
            }
        }
    }

    /// A session can only join a group on its own host; its workspace folder moves with it.
    func setGroup(key: String, group: String?) async throws {
        guard let rec = state.sessions[key] else { throw StoreError("Session not found") }
        if rec.isOutside && group != nil {
            throw StoreError("\(rec.name) was started outside Muxbar, so it stays in Others and can't join a group")
        }
        if let g = group, !state.hasGroup(g, host: rec.host) {
            throw StoreError("No group '\(g)' on \(hostLabel(rec.host)) — groups belong to one host")
        }
        guard rec.group != group else { return }
        try await moveWorkspace(key, toGroup: group)
        mutate { $0.sessions[key]?.group = group }
    }

    private func moveWorkspace(_ key: String, toGroup group: String?) async throws {
        guard let rec = state.sessions[key], let old = rec.managedDir else { return }
        let target = Workspace.path(root: ownRoot(rec, old), group: group, session: rec.name)
        try await runOnHost(rec.host, Workspace.moveScript(from: old, to: target), what: "move workspace folder")
        mutate { $0.sessions[key]?.managedDir = target; $0.sessions[key]?.path = target }
    }

    // MARK: Workspace roots

    /// The root a session's folder was made under. Changing a root only affects new sessions.
    func ownRoot(_ rec: SessionRecord, _ managedDir: String) -> String {
        Workspace.rootOf(managedDir: managedDir, group: rec.group) ?? workspaceRoot(rec.host)
    }

    func workspaceRoot(_ host: String) -> String {
        if let r = state.settings.workspaceRoots[host], !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
        if host == localHost,
           let conf = try? String(contentsOfFile: MuxbarPaths.installConf, encoding: .utf8),
           let r = Workspace.installRoot(conf: conf) { return r }
        return host == localHost ? Workspace.defaultLocalRoot : Workspace.defaultRemoteRoot
    }

    /// Whether `path` is a folder on `host` (nil = couldn't tell, e.g. host unreachable).
    func folderExists(host: String, path: String) async -> Bool? {
        let r = await runner().run(host: host, script: "[ -d \(shellQuotePath(path)) ] && echo MBX_DIR_YES || echo MBX_DIR_NO", timeout: 10)
        if r.stdout.contains("MBX_DIR_YES") { return true }
        if r.stdout.contains("MBX_DIR_NO") { return false }
        return nil
    }

    private func runOnHost(_ host: String, _ script: String, what: String) async throws {
        let r = await runner().run(host: host, script: script, timeout: 20)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            Log.error("\(what) on \(host) failed (exit \(r.exitCode)): \(msg)")
            throw StoreError("Couldn't \(what) on \(hostLabel(host)): \(msg.isEmpty ? "exit \(r.exitCode)" : msg)")
        }
    }

    func sessions(inGroup g: String, host: String) -> [SessionRecord] {
        sessions(for: host).filter { $0.group == g }
    }

    /// Muxbar-created sessions not in a group (shown at the host's top level).
    func ungroupedSessions(for host: String) -> [SessionRecord] {
        sessions(for: host).filter { !$0.isOutside && ($0.group == nil || !state.hasGroup($0.group!, host: host)) }
    }

    /// Sessions started outside Muxbar: the host's fixed "Others" section.
    func otherSessions(for host: String) -> [SessionRecord] {
        sessions(for: host).filter(\.isOutside)
    }

    func hostLabel(_ host: String) -> String { host == localHost ? "This Mac" : host }

    // MARK: Claude conversations started anywhere (incl. outside Muxbar)

    func conversations(host: String, limit: Int = 40) async throws -> [ClaudeConversation] {
        guard state.hosts.contains(host) else { throw StoreError("Unknown host \(host)") }
        let nonce = HostProbe.makeNonce()
        let r = await runner().run(host: host, script: ClaudeConversations.script(nonce: nonce, limit: limit), timeout: 25)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            throw StoreError(msg.isEmpty ? "Couldn't list conversations on \(host)" : msg)
        }
        return ClaudeConversations.parse(r.stdout, nonce: nonce)
    }

    /// Continues a Claude conversation in a new tmux session in its original folder.
    @discardableResult
    func resume(host: String, conversation c: ClaudeConversation, name: String? = nil, group: String? = nil) async throws -> SessionRecord {
        var rec = try await newSession(host: host, dir: c.cwd ?? "~",
                                       name: name ?? ClaudeConversations.sessionName(for: c),
                                       command: ClaudeConversations.resumeCommand(c))
        rec.claudeSessionID = c.id
        if let g = group, state.hasGroup(g, host: host) { rec.group = g }
        let saved = rec
        mutate { $0.sessions[saved.key]?.claudeSessionID = saved.claudeSessionID; $0.sessions[saved.key]?.group = saved.group }
        return state.sessions[rec.key] ?? rec
    }

    func dismissEnded(host: String? = nil) {
        mutate { Reconciler.dismissEnded(host: host, in: &$0) }
    }

    func terminalTabs() throws -> [TabInfo] {
        guard !useEmbedded else { return [] }
        return try terminalCall { try driver().tabs() }
    }
}
