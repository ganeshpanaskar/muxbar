import Foundation

/// Coding agents Muxbar understands. Every agent-specific fact lives in `AgentAdapter`; features
/// ask the adapter rather than branching on the agent themselves.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public enum AgentAdapter {
    static let versionName = try! NSRegularExpression(pattern: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#)

    /// Which agent a process is, from its argv[0] and full command line (as `ps -o args` shows it).
    /// Native installs report `claude`/`codex` (some Claude builds a bare version string); npm
    /// installs show `node …/claude` or `node …/@openai/codex/…`.
    public static func kind(argv0: String, args: String) -> AgentKind? {
        let base = (argv0.split(separator: "/").last.map(String.init) ?? argv0).trimmingCharacters(in: .whitespaces)
        if base == "claude" || matches(versionName, base) { return .claude }
        if base == "codex" || base.hasPrefix("codex-") { return .codex }
        if base == "node" || base == "bun" {
            if args.range(of: #"/claude(\s|$)|claude-code/cli"#, options: .regularExpression) != nil { return .claude }
            if args.range(of: #"/codex(\s|\.js|$)|@openai/codex"#, options: .regularExpression) != nil { return .codex }
        }
        // An interpreter running a script named claude/codex (wrapper installs; Linux shows the
        // interpreter as argv[0] for `#!` scripts).
        if base.range(of: #"^(python[0-9.]*|sh|bash|zsh|perl|ruby)$"#, options: .regularExpression) != nil {
            let words = args.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2, let script = words[1].split(separator: "/").last.map(String.init) {
                if script == "claude" { return .claude }
                if script == "codex" { return .codex }
            }
        }
        return nil
    }

    /// Command that continues a conversation in its folder, keeping the user's own flags.
    public static func resumeCommand(_ kind: AgentKind, sessionID: String, cwd: String?, flags: [String]) -> String {
        let extra = flags.map(shellQuote).joined(separator: " ")
        switch kind {
        case .claude:
            return (["claude", "--resume", shellQuote(sessionID)] + (extra.isEmpty ? [] : [extra])).joined(separator: " ")
        case .codex:
            // -C pins the folder, so Codex doesn't ask which directory to use.
            var parts = ["codex", "resume", shellQuote(sessionID)]
            if let c = cwd, !c.isEmpty { parts += ["-C", shellQuotePath(c)] }
            if !extra.isEmpty { parts.append(extra) }
            return parts.joined(separator: " ")
        }
    }

    /// Flags worth keeping when an agent is restarted to resume (an allowlist: wrapper-injected
    /// options such as a wrapper's `--settings {…}` and anything unknown are dropped).
    public static func keptFlags(_ kind: AgentKind, argv: [String]) -> [String] {
        let withValue: Set<String>, bare: Set<String>
        switch kind {
        case .claude:
            withValue = ["--model", "--permission-mode", "--add-dir", "--agent", "--fallback-model", "--plugin-dir"]
            bare = ["--dangerously-skip-permissions", "--verbose"]
        case .codex:
            withValue = ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval"]
            bare = ["--yolo", "--dangerously-bypass-approvals-and-sandbox", "--search"]
        }
        var out: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if let eq = a.firstIndex(of: "="), withValue.contains(String(a[..<eq])) {
                out.append(a)
            } else if withValue.contains(a), i + 1 < argv.count {
                out += [a, argv[i + 1]]
                i += 1
            } else if bare.contains(a) {
                out.append(a)
            }
            i += 1
        }
        return out
    }

    /// Keys that quit the agent from an empty prompt (sent with `tmux send-keys`, 300 ms apart).
    public static func exitKeys(_ kind: AgentKind) -> [String] { ["C-c", "C-c"] }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// Where a session's status came from.
public enum StatusSource: String, Codable, Sendable {
    case hooks    // the agent's own hooks (exact)
    case screen   // heuristic: screen text + processes
}

/// One pane's state as last reported by the agent's hooks (`~/.muxbar/state/<server>-<pane>.json`,
/// written by agent-plugin/plugins/muxbar-status/bin/muxbar-hook).
public struct HookState: Equatable, Sendable, Codable {
    public enum State: String, Codable, Sendable { case working, waiting, idle, ended }

    public var agent: AgentKind
    public var pane: String          // tmux pane id, e.g. "%12"
    public var event: String
    public var state: State
    public var reason: String
    public var sessionID: String
    public var transcript: String
    public var cwd: String
    public var reply: String         // start of the last reply (Codex Stop payload), may be empty
    public var ts: Int               // host clock

    public init(agent: AgentKind, pane: String, event: String, state: State, reason: String = "",
                sessionID: String = "", transcript: String = "", cwd: String = "", reply: String = "", ts: Int) {
        self.agent = agent; self.pane = pane; self.event = event; self.state = state; self.reason = reason
        self.sessionID = sessionID; self.transcript = transcript; self.cwd = cwd; self.reply = reply; self.ts = ts
    }

    /// Parses one state-file line. Unknown agents/states and malformed lines give nil.
    public static func parse(_ line: String) -> HookState? {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = (o["agent"] as? String).flatMap(AgentKind.init(rawValue:)),
              let pane = o["pane"] as? String, pane.hasPrefix("%"),
              let st = (o["state"] as? String).flatMap(State.init(rawValue:)),
              let ts = (o["ts"] as? Int) ?? (o["ts"] as? String).flatMap(Int.init) else { return nil }
        func s(_ k: String) -> String { o[k] as? String ?? "" }
        return HookState(agent: a, pane: pane, event: s("event"), state: st, reason: s("reason"),
                         sessionID: s("sid"), transcript: s("transcript"), cwd: s("cwd"), reply: s("reply"), ts: ts)
    }
}

/// Combines the hooks' report with the screen heuristic (F1).
public enum StatusFusion {
    /// After an interrupt (Esc in Claude fires no hook) the hooks still say "working"; once the screen
    /// shows the idle prompt and nothing has been written for this long, it's idle.
    public static let interruptQuietSeconds = 20
    /// Host clocks in the hook file and `ps` can disagree slightly.
    static let clockSlack = 2

    /// - Parameters:
    ///   - agentAlive: the pane has a live process of the hook's agent kind.
    ///   - agentStartedAt: when that process started (host clock); hooks older than it are stale
    ///     (the plugin isn't loaded in this process).
    /// - Parameter interrupted: the screen shows the latest turn was interrupted (Esc fires no
    ///   hook, so the last hook state still says working).
    public static func combine(hook: HookState?, heuristic: SessionStatus, outputAge: Int?, agentAlive: Bool,
                               agentStartedAt: Int?, now: Int, interrupted: Bool = false) -> (SessionStatus, StatusSource) {
        guard let h = hook, agentAlive else { return (heuristic, .screen) }
        if let start = agentStartedAt, h.ts + clockSlack < start { return (heuristic, .screen) }
        switch h.state {
        case .waiting:
            return (.waiting, .hooks)
        case .working:
            if heuristic == .waiting { return (.waiting, .hooks) }
            // Interrupted: idle now. Otherwise an idle screen counts only once output has been
            // quiet a while (a status line or other redraws keep resetting that clock).
            if heuristic == .idle && interrupted { return (.idle, .hooks) }
            if heuristic == .idle, let age = outputAge, age >= interruptQuietSeconds { return (.idle, .hooks) }
            return (.working, .hooks)
        case .idle:
            return (heuristic == .waiting ? .waiting : .idle, .hooks)
        case .ended:
            return (heuristic, .screen)
        }
    }

    /// A session's status from its panes' statuses: waiting > working > idle > the rest.
    public static func sessionStatus(_ panes: [(SessionStatus, StatusSource)]) -> (SessionStatus, StatusSource)? {
        let rank: [SessionStatus: Int] = [.waiting: 5, .working: 4, .idle: 3, .unknown: 1]
        return panes.max { (rank[$0.0] ?? 0, $0.1 == .hooks ? 1 : 0) < (rank[$1.0] ?? 0, $1.1 == .hooks ? 1 : 0) }
    }
}

/// `ps -o etime` ("[[dd-]hh:]mm:ss", macOS) or `etimes` (seconds, Linux) → seconds.
public func parseElapsed(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let n = Int(t) { return n }
    var days = 0
    var rest = Substring(t)
    if let dash = rest.firstIndex(of: "-") {
        guard let d = Int(rest[..<dash]) else { return nil }
        days = d
        rest = rest[rest.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    let p = parts.map { $0! }
    var secs = 0
    for v in p { secs = secs * 60 + v }
    return days * 86400 + secs
}
