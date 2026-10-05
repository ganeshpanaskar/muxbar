import Foundation

public struct LiveInfo: Equatable, Sendable {
    public var status: SessionStatus
    public var attached: Int
    public var command: String?

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
            state.sessions[key] = rec
            let status = (s.capture == nil && s.processes == nil)
                ? .unknown
                : StatusClassifier.classify(processes: s.processes, lines: s.capture,
                                            outputAge: probe.hostNow.flatMap { now in s.windowActivity.map { now - $0 } },
                                            agents: state.settings.agents)
            live[key] = LiveInfo(status: status, attached: s.attached, command: s.command)
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
