import Foundation

public struct LiveInfo: Equatable, Sendable {
    public var status: SessionStatus
    public var attached: Int
    public var command: String?
    /// Where `status` came from: the agent's hooks (exact) or the screen heuristic.
    public var source: StatusSource = .screen
    /// Agent running in the session right now (nil = none seen).
    public var agent: AgentKind?
    public var agentPID: Int?
    /// Hook detail: why it waits ("permission", "question"), last event, and the reply's start.
    public var reason: String = ""
    public var hookEvent: String = ""
    public var hookTS: Int?
    public var reply: String = ""
    public var transcript: String = ""
    /// RSS of all the session's processes (KB), including ones that left its tree (Linux).
    public var memoryKB: Int = 0
    public var outputAge: Int?

    public init(status: SessionStatus, attached: Int, command: String?) {
        self.status = status
        self.attached = attached
        self.command = command
    }
}

public enum Reconciler {
    /// Merges one host's probe into stored records.
    /// - Probed sessions create/update records (tmux wins for name, path, activity).
    /// - Stored tmux records missing from a *successful* probe become `ended` (kept for P1 resume).
    /// - A recycled `$id` with a different `created` is a different session (different key).
    /// Returns live info keyed by record key.
    @discardableResult
    public static func apply(_ probe: ProbeResult, host: String, to state: inout AppState) -> [String: LiveInfo] {
        var live: [String: LiveInfo] = [:]
        var seen = Set<String>()
        let now = probe.hostNow ?? Int(Date().timeIntervalSince1970)
        for s in probe.sessions {
            let key = sessionKey(host: host, tmuxID: s.id, created: s.created)
            seen.insert(key)
            var rec = state.sessions[key] ?? {
                // First seen in a probe = started outside Muxbar (newSession re-marks its own).
                var r = SessionRecord(key: key, host: host, tmuxID: s.id, created: s.created, name: s.name)
                r.origin = .outside
                return r
            }()
            rec.name = s.name
            if let p = s.path, !p.isEmpty { rec.path = p }
            // session_activity only moves on client input; output (window_activity) counts too.
            rec.lastActivity = max(s.activity, s.windowActivity ?? 0)
            rec.ended = false

            let outputAge = probe.hostNow.flatMap { now in s.windowActivity.map { now - $0 } }
            let panes = probe.panes.filter { $0.sessionID == s.id }
            let activeAgents = panes.first(where: { $0.active })?.agents ?? []
            let anyAgent = activeAgents.first ?? panes.lazy.flatMap(\.agents).first
            var heuristic: SessionStatus = (s.capture == nil && s.processes == nil)
                ? .unknown
                : StatusClassifier.classify(processes: s.processes, lines: s.capture, outputAge: outputAge,
                                           otherAgents: state.settings.otherAgentNames)
            // The screen heuristic reads Claude's screen only; another agent's screen is unknown to it.
            if heuristic == .notClaude, activeAgents.contains(where: { $0.kind != .claude }) { heuristic = .unknown }
            let interrupted = StatusClassifier.interruptedLatestTurn(s.capture)

            // Each pane with a hook state: fuse it with the screen (only the active pane's is known).
            var candidates: [(SessionStatus, StatusSource, ProbedPane?)] = []
            for p in panes {
                guard let h = p.hook else { continue }
                let proc = p.agents.first { $0.kind == h.agent }
                let started = proc?.ageSeconds.map { now - $0 }
                let paneAge = probe.hostNow.flatMap { now in p.windowActivity.map { now - $0 } }
                let (st, src) = StatusFusion.combine(hook: h, heuristic: p.active ? heuristic : .unknown,
                                                     outputAge: p.active ? outputAge : paneAge,
                                                     agentAlive: proc != nil, agentStartedAt: started, now: now,
                                                     interrupted: p.active && interrupted)
                candidates.append((st, src, p))
            }
            let activeHasLiveHook = candidates.contains { $0.2?.active == true && $0.1 == .hooks }
            if !activeHasLiveHook { candidates.append((heuristic, .screen, nil)) }
            let ranked = StatusFusion.sessionStatus(candidates.map { ($0.0, $0.1) }) ?? (heuristic, .screen)
            let chosen = candidates.first { $0.0 == ranked.0 && $0.1 == ranked.1 }

            var info = LiveInfo(status: ranked.0, attached: s.attached, command: s.command)
            info.source = ranked.1
            info.agent = (chosen?.2?.hook.flatMap { h in chosen?.2?.agents.first { $0.kind == h.agent }?.kind }) ?? anyAgent?.kind
            info.agentPID = (chosen?.2?.agents.first ?? anyAgent)?.pid
            info.memoryKB = s.memoryKB
            info.outputAge = outputAge
            if let h = chosen?.2?.hook, ranked.1 == .hooks {
                info.reason = h.reason
                info.hookEvent = h.event
                info.hookTS = h.ts
                info.reply = h.reply
                info.transcript = h.transcript
            }
            // Remember the agent and its conversation (kept after it exits, for resume).
            if let k = info.agent { rec.agent = k }
            // Only from a hook report the fusion accepted (.hooks): a report older than the agent now
            // in the pane (left by an earlier agent there, or by a pane with the same id before tmux
            // restarted, e.g. after a reboot) names some other conversation.
            if ranked.1 == .hooks, let p = chosen?.2, let h = p.hook, !h.sessionID.isEmpty,
               p.agents.contains(where: { $0.kind == h.agent }) {
                rec.agent = h.agent
                rec.agentSessionID = h.sessionID
                if h.agent == .claude { rec.claudeSessionID = h.sessionID }
            }
            state.sessions[key] = rec
            live[key] = info
        }
        for (key, rec) in state.sessions where rec.host == host && !rec.isPlainTab && !seen.contains(key) {
            state.sessions[key]?.ended = true
        }
        return live
    }

    /// Records whose sessions ended can be dismissed by the user.
    public static func dismissEnded(host: String?, in state: inout AppState) {
        state.sessions = state.sessions.filter { !($0.value.ended && (host == nil || $0.value.host == host)) }
    }
}
