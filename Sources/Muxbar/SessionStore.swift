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
    /// When each waiting session started waiting (for oldest-first ordering).
    @Published private(set) var waitingSince: [String: Date] = [:]
    /// Session shown in the main window's terminal pane.
    @Published private(set) var selectedKey: String?
    let embedded = EmbeddedTerminals()

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
        if st.ejectOutsideFromGroups() > 0 {
            state = st
            try? Persistence.save(st, path: stateFile)
            Log.info("moved sessions started outside Muxbar out of groups into Others")
        }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.handleSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.handleWake() }
        })
        startAllPollers()
    }

    // MARK: Pane history scrolling (tmux copy mode, driven from the scroll bar and wheel)

    @Published private(set) var scrollInfo: [String: TmuxScrollInfo] = [:]
    private var scrollBusy = Set<String>()
    private var scrollQueued: [String: () -> String] = [:]

    private func scrollTarget(_ key: String) -> (SessionRecord, String, String)? {
        guard let rec = state.sessions[key], !rec.ended, let id = rec.tmuxID else { return nil }
        let tmux = rec.host == localHost ? (localTmux.map(shellQuote) ?? "tmux") : "tmux"
        return (rec, id, tmux)
    }

    func refreshScrollInfo(_ key: String) async {
        guard let (rec, id, tmux) = scrollTarget(key) else { return }
        let r = await runner().run(host: rec.host, script: TmuxScroll.infoScript(tmux: tmux, id: id), timeout: 10)
        if let info = TmuxScroll.parse(r.stdout) { scrollInfo[key] = info }
    }

    /// Runs scroll commands one at a time per pane; while one is in flight only the latest
    /// request is kept (drag and wheel produce many).
    private func runScroll(_ key: String, _ make: @escaping () -> String) {
        guard let (rec, _, _) = scrollTarget(key) else { return }
        if scrollBusy.contains(key) { scrollQueued[key] = make; return }
        scrollBusy.insert(key)
        Task {
            _ = await runner().run(host: rec.host, script: make() + "; " + TmuxScroll.infoScript(tmux: scrollTarget(key)?.2 ?? "tmux", id: rec.tmuxID ?? ""), timeout: 10)
            await refreshScrollInfo(key)
            scrollBusy.remove(key)
            if let next = scrollQueued.removeValue(forKey: key) { runScroll(key, next) }
        }
    }

    func scrollPane(_ key: String, lines: Int) {
        guard lines != 0, let (_, id, tmux) = scrollTarget(key) else { return }
        runScroll(key) { TmuxScroll.scrollScript(tmux: tmux, id: id, lines: lines) }
        if var i = scrollInfo[key] {   // optimistic, so the thumb follows immediately
            i.inMode = true
            i.position = min(i.history, max(0, i.position + lines))
            if i.position == 0 { i.inMode = false }
            scrollInfo[key] = i
        }
    }

    func scrollPane(_ key: String, toPosition pos: Int) {
        guard let (_, id, tmux) = scrollTarget(key) else { return }
        runScroll(key) { TmuxScroll.gotoScript(tmux: tmux, id: id, position: pos) }
        if var i = scrollInfo[key] { i.position = pos; i.inMode = pos > 0; scrollInfo[key] = i }
    }

    /// Before typed keys reach a scrolled-back pane, return it to live output.
    func leaveHistoryThen(_ key: String, _ deliver: @escaping () -> Void) -> Bool {
        guard let info = scrollInfo[key], !info.atLive, let (rec, id, tmux) = scrollTarget(key) else { return false }
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
        }
    }

    // MARK: Resume ended sessions

    /// Brings back a session whose tmux session ended (e.g. after a reboot): same folder, name,
    /// group and section, running its agent's resume command for the known conversation (e.g.
    /// `claude --resume <id>`), else its continue command (`claude --continue`).
    @discardableResult
    func resumeEnded(key: String) async throws -> SessionRecord {
        guard let old = state.sessions[key] else { throw StoreError("Session not found") }
        guard old.ended else { throw StoreError("\(old.name) is still running") }
        let folder = old.managedDir ?? old.path ?? "~"
        // Known conversation id, else the newest conversation whose folder matches (by real path).
        var agent = state.settings.agent(id: old.agent)
        var convID = old.conversationID
        if convID == nil, let found = await newestConversation(host: old.host, folder: folder, agent: agent?.id) {
            convID = found.id
            agent = agent ?? state.settings.agent(id: found.agent)
        }
        // Unknown agent (e.g. the session was a plain shell): fall back to the default command's agent.
        agent = agent ?? state.settings.defaultAgent
        let cmd: String? = agent.map { Conversations.resumeEndedCommand(agent: $0, sessionID: convID) }
            ?? (state.settings.defaultCommand.isEmpty ? nil : state.settings.defaultCommand)
        // Free the name first so the new session gets it back.
        mutate { $0.sessions[key] = nil }
        do {
            let group = (!old.isOutside && old.group.map { state.hasGroup($0, host: old.host) } == true) ? old.group : nil
            try await runOnHost(old.host, Workspace.mkdirScript(folder), what: "recreate session folder")
            var rec = try await newSession(host: old.host, dir: folder, name: old.name, command: cmd, group: group)
            rec.managedDir = old.managedDir   // same workspace folder as before (still follows renames)
            rec.conversationID = convID
            rec.agent = agent?.id
            rec.origin = old.isOutside ? .outside : .muxbar   // Others stay in Others
            rec.note = old.note
            rec.tags = old.tags
            let saved = rec
            mutate { $0.sessions[saved.key] = saved }
            Log.info("resumed ended session \(old.name) on \(old.host) with: \(cmd ?? "a shell")")
            return saved
        } catch {
            mutate { $0.sessions[key] = old }   // put the ended record back
            throw error
        }
    }

    /// Newest conversation recorded for `folder` on `host`, of `agent` if given (agents store the
    /// real path, e.g. /private/tmp/… for /tmp/…, so both spellings are compared).
    private func newestConversation(host: String, folder: String, agent: String?) async -> Conversation? {
        let r = await runner().run(host: host, script: "cd \(shellQuotePath(folder)) 2>/dev/null && pwd -P && pwd", timeout: 15)
        let paths = Set(r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !paths.isEmpty, let list = try? await conversations(host: host, limit: 200) else { return nil }
        return list.first { c in (agent == nil || c.agent == agent) && (c.cwd.map { paths.contains($0) } ?? false) }   // newest first
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

    /// ⌘J: the next waiting session after the selected one (oldest first, wrapping round).
    @discardableResult
    func focusNextWaiting() async throws -> SessionRecord? {
        let list = waitingSessions
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

    var interval: TimeInterval { openViews > 0 ? Self.foregroundInterval : Self.backgroundInterval }

    // MARK: Persistence

    private func mutate(_ f: (inout AppState) -> Void) {
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
        let tmux = host == localHost ? shellQuote(localTmux!) : "tmux"
        let nonce = HostProbe.makeNonce()
        let r = await runner().run(host: host, script: HostProbe.script(mode: .status, nonce: nonce, tmux: tmux),
                                   timeout: 20)
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
            var newLive: [String: LiveInfo] = [:]
            mutate { st in newLive = Reconciler.apply(probe, host: host, to: &st) }
            var l = live.filter { k, _ in state.sessions[k]?.host != host }
            l.merge(newLive) { $1 }
            let before = live
            live = l
            for (k, v) in l where state.sessions[k]?.host == host {
                if v.status == .waiting { if waitingSince[k] == nil { waitingSince[k] = Date() } } else { waitingSince[k] = nil }
            }
            Attention.shared.update(store: self, before: before, after: l)
            restorePanes(host: host)
        } catch {
            failures[host, default: 0] += 1
            Log.error("probe \(host) output unparseable: \(error)")
            health[host] = .unreachable("Probe output was cut off")
        }
    }

    /// L1: plain local tabs (no tmux). Liveness = an agent process on the tab's tty.
    private func refreshPlainTabs() {
        let plain = state.sessions.values.filter { $0.host == localHost && $0.isPlainTab }
        guard !plain.isEmpty else { return }
        let agents = state.settings.agents
        Task {
            for rec in plain {
                if let e = embedded.session(rec.key) {
                    live[rec.key] = LiveInfo(status: e.isRunning ? .running : .notRunning, attached: 1, command: nil)
                    continue
                }
                guard let tty = rec.tab?.tty else { continue }
                let r = await runProcess("/bin/ps", ["-o", "comm=", "-t", (tty as NSString).lastPathComponent], timeout: 5)
                let running = r.stdout.split(separator: "\n").map(String.init).contains { StatusClassifier.isAgentProcess($0, agents: agents) }
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
        if rec.host == localHost { return (localTmux ?? "/usr/bin/false", ["attach-session", "-t", id]) }
        var args: [String] = []
        if let f = state.settings.sshConfigFile { args += ["-F", f] }
        args += ["-t", rec.host, "tmux attach-session -t " + shellQuote(id)]
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
        guard let key, let rec = state.sessions[key] else { selectedKey = key; return nil }
        selectedKey = key
        guard !rec.ended else { return nil }
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

    func wireScrolling(_ key: String) {
        guard let v = embedded.session(key)?.view as? MuxTerminalView else { return }
        v.beforeInput = { [weak self] deliver in self?.leaveHistoryThen(key, deliver) ?? false }
    }

    private func runTmux(host: String, _ script: String) async throws -> String {
        let r = await runner().run(host: host, script: script, timeout: 20)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            Log.error("tmux command on \(host) failed (exit \(r.exitCode)): \(msg)")
            throw StoreError(msg.isEmpty ? "Command failed on \(host) (exit \(r.exitCode))" : msg)
        }
        return r.stdout
    }

    private func tmuxPath(_ host: String) throws -> String {
        if host != localHost { return "tmux" }
        guard let t = localTmux else { throw StoreError("tmux isn't installed locally") }
        return shellQuote(t)
    }

    private func attachCommand(_ rec: SessionRecord) -> String {
        if rec.host == localHost { return TmuxCommands.attachLocal(tmux: localTmux ?? "tmux", id: rec.tmuxID ?? "") }
        return TmuxCommands.attachRemote(host: rec.host, id: rec.tmuxID ?? "", sshConfigFile: state.settings.sshConfigFile)
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
                    attach: Bool = true) async throws -> SessionRecord {
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
        let agent = AgentProfile.matching(command: cmd, in: state.settings.agents)?.id
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
            rec.agent = agent
            mutate { $0.sessions[key] = rec; $0.rememberDir(dir, host: host) }
            if useEmbedded {
                let line = "cd \(shellQuotePath(dir)) && \(run)exec \"${SHELL:-/bin/zsh}\" -l"
                _ = embedded.ensure(key: key, executable: "/bin/zsh", args: ["-lc", line])
                selectedKey = key
                MainWindowPresenter.show()
            }
            return rec
        }

        let out = try await runTmux(host: host, TmuxCommands.newSession(tmux: try tmuxPath(host), name: name, dir: dir, command: cmd))
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
        rec.agent = agent
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
            let target = Workspace.path(root: workspaceRoot(rec.host), group: rec.group, session: name)
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
        let alive = hasLiveAttachClient(psOutput: ps, host: rec.host, tmuxID: rec.tmuxID ?? "")
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

    func kill(key: String) async throws {
        guard let rec = state.sessions[key] else { throw StoreError("Session not found") }
        embedded.remove(key)
        if selectedKey == key { selectedKey = nil }
        defer { rememberPanes() }
        if let id = rec.tmuxID, !rec.ended {
            _ = try await runTmux(host: rec.host, TmuxCommands.kill(tmux: try tmuxPath(rec.host), id: id))
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
        // The group folder follows the name (only if any member lives in a workspace folder).
        let root = workspaceRoot(host)
        let oldPath = Workspace.groupPath(root: root, group: old), newPath = Workspace.groupPath(root: root, group: name)
        let managedMembers = state.sessions.values.contains { $0.host == host && $0.group == old && $0.managedDir != nil }
        if managedMembers && oldPath != newPath {
            try await runOnHost(host, Workspace.moveScript(from: oldPath, to: newPath), what: "rename group folder")
        }
        mutate { st in
            st.groups[host] = st.groups(for: host).map { $0 == old ? name : $0 }
            for k in st.sessions.keys where st.sessions[k]?.host == host && st.sessions[k]?.group == old {
                st.sessions[k]?.group = name
                if let d = st.sessions[k]?.managedDir, let nd = Workspace.rebase(d, from: oldPath, to: newPath) {
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
        for rec in state.sessions.values where rec.host == host && rec.group == name {
            try await moveWorkspace(rec.key, toGroup: nil)
        }
        try? await runOnHost(host, Workspace.rmdirIfEmptyScript(Workspace.groupPath(root: workspaceRoot(host), group: name)),
                             what: "remove empty group folder")
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
        let target = Workspace.path(root: workspaceRoot(rec.host), group: group, session: rec.name)
        try await runOnHost(rec.host, Workspace.moveScript(from: old, to: target), what: "move workspace folder")
        mutate { $0.sessions[key]?.managedDir = target; $0.sessions[key]?.path = target }
    }

    // MARK: Workspace roots

    func workspaceRoot(_ host: String) -> String {
        if let r = state.settings.workspaceRoots[host], !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
        if host == localHost,
           let conf = try? String(contentsOfFile: NSHomeDirectory() + "/.muxbar/install.conf", encoding: .utf8),
           let r = Workspace.installRoot(conf: conf) { return r }
        return host == localHost ? Workspace.defaultLocalRoot : Workspace.defaultRemoteRoot
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

    // MARK: Agent conversations started anywhere (incl. outside Muxbar)

    func conversations(host: String, limit: Int = 40) async throws -> [Conversation] {
        guard state.hosts.contains(host) else { throw StoreError("Unknown host \(host)") }
        let nonce = HostProbe.makeNonce()
        let r = await runner().run(host: host, script: Conversations.script(nonce: nonce, limit: limit), timeout: 25)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            throw StoreError(msg.isEmpty ? "Couldn't list conversations on \(host)" : msg)
        }
        return Conversations.parse(r.stdout, nonce: nonce, limit: limit)
    }

    /// Continues an agent conversation in a new tmux session in its original folder.
    @discardableResult
    func resume(host: String, conversation c: Conversation, name: String? = nil, group: String? = nil) async throws -> SessionRecord {
        guard let cmd = Conversations.resumeCommand(c, agents: state.settings.agents) else {
            throw StoreError("\(state.settings.agent(id: c.agent)?.name ?? c.agent) can't resume a conversation by id")
        }
        var rec = try await newSession(host: host, dir: c.cwd ?? "~",
                                       name: name ?? Conversations.sessionName(for: c), command: cmd)
        rec.conversationID = c.id
        rec.agent = c.agent
        if let g = group, state.hasGroup(g, host: host) { rec.group = g }
        let saved = rec
        mutate { $0.sessions[saved.key]?.conversationID = saved.conversationID; $0.sessions[saved.key]?.agent = saved.agent; $0.sessions[saved.key]?.group = saved.group }
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
