import AppKit
import MuxbarCore

/// F4: exit an idle agent to free memory (the tmux session and its shell stay), then resume the
/// same conversation when you come back.
extension SessionStore {
    /// How often auto-sleep looks for idle agents (faster on test instances).
    static var autoSleepInterval: TimeInterval { TestEnv.isTest ? 10 : 60 }

    /// The pane the session's agent runs in (from the last probe), else the active pane.
    func agentPane(_ rec: SessionRecord) -> (pane: String, agent: AgentProcess?)? {
        guard let sid = rec.tmuxID else { return nil }
        let panes = (lastPanes[rec.host] ?? []).filter { $0.sessionID == sid }
        if let p = panes.first(where: { $0.active && !$0.agents.isEmpty }) ?? panes.first(where: { !$0.agents.isEmpty }) {
            return (p.id, p.agents.first)
        }
        return panes.first(where: \.active).map { ($0.id, nil) }
    }

    /// When the agent went idle: the hook's Stop/Interrupt time, else when the screen first showed it
    /// idle. Never tmux activity: your own keystrokes move that.
    func idleSince(_ rec: SessionRecord) -> Int? {
        if let li = live[rec.key], li.source == .hooks, ["Stop", "Interrupt", "SessionStart"].contains(li.hookEvent),
           let ts = li.hookTS { return ts }
        return idleSinceAt[rec.key]
    }

    /// Everything the policy needs, from one script on the host.
    func sleepInputs(_ key: String, auto: Bool) async -> (SleepPolicy.Inputs, SleepPolicy.Check?, String?) {
        let rec = state.sessions[key]
        let li = live[key]
        let ap = rec.flatMap(agentPane)
        let agent = ap?.agent?.kind ?? li?.agent
        var conv = rec?.resumeID
        var check: SleepPolicy.Check?
        var promptEmpty: Bool?
        if let rec, let ap, let pid = ap.agent?.pid, let tmux = try? tmuxPath(rec.host) {
            let nonce = HostProbe.makeNonce()
            let r = await runner().run(host: rec.host, script: SleepPolicy.checkScript(nonce: nonce, agentPID: pid, tmux: tmux, pane: ap.pane),
                                       timeout: 20)
            let c = SleepPolicy.parseCheck(r.stdout, nonce: nonce)
            check = c
            promptEmpty = agent.flatMap { SleepPolicy.promptEmpty(c.screen, agent: $0) }
            if conv == nil, agent == .claude { conv = await newestConversation(host: rec.host, folder: rec.path ?? "~") }
        }
        let since = rec.flatMap(idleSince)
        let now = Int(Date().timeIntervalSince1970)
        let typed = (lastInput[key].map { Int($0.timeIntervalSince1970) } ?? 0) > (since ?? now)
        let inputs = SleepPolicy.Inputs(
            status: li?.status ?? .unknown, agent: agent, agentPID: ap?.agent?.pid, conversationID: conv,
            promptEmpty: promptEmpty, descendants: check?.descendants ?? [], attachedClients: li?.attached ?? 0,
            muxbarClients: embedded.session(key)?.isRunning == true ? 1 : 0,
            viewing: isViewing(key) || (state.layout == .grid && state.grid.contains(key) && appFrontmost),
            inputSinceIdle: typed, neverSleep: rec?.neverSleep ?? false,
            idleMinutes: since.map { (now - $0) / 60 }, sleeping: rec?.sleep != nil)
        return (inputs, check, ap?.pane)
    }

    @discardableResult
    func sleep(_ key: String, auto: Bool = false) async throws -> SleepInfo {
        guard let rec = state.sessions[key], !rec.ended else { throw StoreError("Session not found or ended") }
        await refresh(host: rec.host)
        let (inputs, check, pane) = await sleepInputs(key, auto: auto)
        let reasons = SleepPolicy.check(inputs, auto: auto, autoMinutes: settings.autoSleepMinutes ?? 30)
        guard reasons.isEmpty, let agent = inputs.agent, let pid = inputs.agentPID, let pane, let conv = inputs.conversationID,
              let check else {
            throw StoreError("Can't sleep \(rec.name): " + reasons.map(\.description).joined(separator: "; "))
        }
        let tmux = try tmuxPath(rec.host)
        // Quit from the empty prompt the way you would: the agent's exit keys, 300 ms apart.
        let keys = AgentAdapter.exitKeys(agent).map { "\(tmux) send-keys -t \(shellQuote(pane)) \($0)" }.joined(separator: "; sleep 0.3; ")
        _ = try await runTmux(host: rec.host, keys)
        var gone = false
        let top = check.topPID ?? pid
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let r = await runner().run(host: rec.host, script: "kill -0 \(top) 2>/dev/null && echo alive || echo gone", timeout: 10)
            if r.stdout.contains("gone") { gone = true; break }
        }
        guard gone else { throw StoreError("\(agent.displayName) in \(rec.name) didn't exit within 8 s; left it running") }
        let info = SleepInfo(agent: agent, sessionID: conv, cwd: rec.path, flags: AgentAdapter.keptFlags(agent, argv: check.argv),
                             sleptAt: Int(Date().timeIntervalSince1970), freedKB: check.freedKB)
        mutate { st in
            st.sessions[key]?.sleep = info
            st.sessions[key]?.agent = agent
            st.sessions[key]?.agentSessionID = conv
            st.sessions[key]?.unread = false
        }
        Log.info("slept \(agent.rawValue) in \(rec.name) on \(rec.host) (freed \(formatKB(info.freedKB)), resume: \(info.resumeCommand))\(auto ? " [auto]" : "")")
        await refresh(host: rec.host)
        return info
    }

    func wake(_ key: String) async throws {
        guard let rec = state.sessions[key], let info = rec.sleep else { throw StoreError("It isn't asleep") }
        guard !rec.ended else { throw StoreError("\(rec.name) has ended — use Resume Session") }
        await refresh(host: rec.host)
        if let ap = agentPane(rec), ap.agent != nil {
            // The agent is already back (started by hand): nothing to type.
            mutate { $0.sessions[key]?.sleep = nil }
            return
        }
        guard let pane = agentPane(rec)?.pane else { throw StoreError("Can't find \(rec.name)'s pane") }
        let tmux = try tmuxPath(rec.host)
        // Typed at the shell prompt, like a person would, in the same folder (Codex: -C pins it).
        _ = try await runTmux(host: rec.host, "\(tmux) send-keys -t \(shellQuote(pane)) -l \(shellQuote(info.resumeCommand)); "
                                + "\(tmux) send-keys -t \(shellQuote(pane)) Enter")
        mutate { $0.sessions[key]?.sleep = nil }
        Log.info("woke \(rec.name) on \(rec.host): \(info.resumeCommand)")
        await refresh(host: rec.host)
    }

    /// Sleeps every idle agent on `host` that may sleep (skipping the one on screen).
    func sleepIdle(host: String, dryRun: Bool = false) async -> [(name: String, result: String, freedKB: Int)] {
        var out: [(String, String, Int)] = []
        for rec in sessions(for: host) where !rec.ended && rec.sleep == nil && live[rec.key]?.agent != nil {
            if isViewing(rec.key) { out.append((rec.name, "skipped: on screen", 0)); continue }
            let (inputs, check, _) = await sleepInputs(rec.key, auto: false)
            let reasons = SleepPolicy.check(inputs, auto: false)
            if !reasons.isEmpty { out.append((rec.name, "skipped: " + reasons.map(\.description).joined(separator: "; "), 0)); continue }
            if dryRun { out.append((rec.name, "would sleep", check?.freedKB ?? 0)); continue }
            do {
                let info = try await sleep(rec.key)
                out.append((rec.name, "slept", info.freedKB))
            } catch {
                out.append((rec.name, "failed: \(error.localizedDescription)", 0))
            }
        }
        return out
    }

    /// Idle agents that could be slept now, and roughly how much memory that frees (for the
    /// memory popover; cheap: from the last probe only).
    func sleepCandidates(host: String) -> (count: Int, kb: Int) {
        let recs = sessions(for: host).filter {
            !$0.ended && $0.sleep == nil && live[$0.key]?.status == .idle && live[$0.key]?.agent != nil && !isViewing($0.key)
        }
        return (recs.count, recs.reduce(0) { $0 + (live[$1.key]?.memoryKB ?? 0) })
    }

    /// Auto-sleep (Settings, off by default): idle agents that meet every condition go to sleep.
    func autoSleepTick() async {
        guard let mins = settings.autoSleepMinutes, mins > 0 else { return }
        let now = Int(Date().timeIntervalSince1970)
        for rec in state.sessions.values where !rec.ended && rec.sleep == nil && !rec.neverSleep {
            guard let li = live[rec.key], li.status == .idle, li.agent != nil, !isViewing(rec.key),
                  let since = idleSince(rec), now - since >= mins * 60 else { continue }
            let (inputs, _, _) = await sleepInputs(rec.key, auto: true)
            guard SleepPolicy.check(inputs, auto: true, autoMinutes: mins).isEmpty else { continue }
            do { try await sleep(rec.key, auto: true) } catch { Log.error("auto-sleep \(rec.name): \(error)") }
        }
    }

    /// An agent started by hand in a sleeping session wakes it in Muxbar's eyes too.
    func clearSleepIfAgentBack(host: String) {
        let back = state.sessions.values.filter { $0.host == host && $0.sleep != nil && live[$0.key]?.agent != nil }
        guard !back.isEmpty else { return }
        mutate { st in for r in back { st.sessions[r.key]?.sleep = nil } }
    }
}
