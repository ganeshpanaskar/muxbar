import Foundation

/// When a session needs your attention (F2): its agent finished a turn, or started waiting.
public enum Unread {
    public enum Event: String, Sendable { case finished, waiting }

    /// Per-session memory between polls (not persisted).
    public struct Tracker: Equatable, Sendable {
        public var sawWorking = false
        public var idleStreak = 0
        /// Timestamp of the last Stop/Interrupt hook already counted.
        public var lastFinishTS: Int?
        public var seen = false
        public init() {}
    }

    /// One poll's transition for a session.
    /// - With hooks, every new Stop/Interrupt is a finish — even a turn shorter than a poll.
    /// - Screen-only, a finish must be confirmed: a working poll, then two idle polls in a row.
    /// - The first observation (app start) only records state: old finishes aren't news.
    public static func step(_ t: inout Tracker, prev: SessionStatus?, next: SessionStatus, source: StatusSource,
                            hookEvent: String, hookTS: Int?) -> Event? {
        defer { t.seen = true }
        let first = !t.seen
        if next == .waiting {
            t.idleStreak = 0
            return (!first && prev != .waiting) ? .waiting : nil
        }
        if source == .hooks {
            if (hookEvent == "Stop" || hookEvent == "Interrupt"), let ts = hookTS, next == .idle {
                defer { t.lastFinishTS = ts }
                if !first && ts != t.lastFinishTS { t.sawWorking = false; return .finished }
                return nil
            }
            if next == .working { t.sawWorking = true }
            // Interrupted Claude turns end without a hook: the screen fusion turns them idle.
            if next == .idle && prev == .working && !first { t.sawWorking = false; return .finished }
            return nil
        }
        switch next {
        case .working:
            t.sawWorking = true
            t.idleStreak = 0
        case .idle:
            t.idleStreak += 1
            if t.sawWorking && t.idleStreak >= 2 && !first {
                t.sawWorking = false
                return .finished
            }
        case .unknown:
            break
        default:
            t.idleStreak = 0
            t.sawWorking = false
        }
        return nil
    }
}

/// Reading agent transcripts (JSONL) for previews and history (F2, F9).
public enum AgentTranscript {
    /// Claude's project folder name for a working directory: every non-alphanumeric becomes "-".
    public static func claudeProjectDir(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Text of the last assistant message in a transcript tail. Tool calls and results are skipped;
    /// a cut-off first line is ignored.
    public static func lastAssistantText(_ tail: String, agent: AgentKind) -> String? {
        for raw in tail.split(separator: "\n").reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            if let t = assistantText(o, agent: agent), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        }
        return nil
    }

    static func assistantText(_ o: [String: Any], agent: AgentKind) -> String? {
        switch agent {
        case .claude:
            guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any] else { return nil }
            if let s = m["content"] as? String { return s }
            let parts = (m["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .codex:
            let p = o["payload"] as? [String: Any] ?? [:]
            if o["type"] as? String == "event_msg", p["type"] as? String == "agent_message" { return p["message"] as? String }
            guard o["type"] as? String == "response_item", p["type"] as? String == "message",
                  p["role"] as? String == "assistant" else { return nil }
            let parts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// What the user typed in a transcript line (nil for tool results, slash-command echoes,
    /// injected context and the like).
    static func userText(_ o: [String: Any], agent: AgentKind) -> String? {
        var text: String?
        switch agent {
        case .claude:
            guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { return nil }
            if let s = m["content"] as? String { text = s } else {
                let parts = (m["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                text = parts.isEmpty ? nil : parts.joined(separator: " ")
            }
        case .codex:
            let p = o["payload"] as? [String: Any] ?? [:]
            if o["type"] as? String == "event_msg", p["type"] as? String == "user_message" {
                text = p["message"] as? String
            } else if o["type"] as? String == "response_item", p["type"] as? String == "message", p["role"] as? String == "user" {
                let parts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                text = parts.isEmpty ? nil : parts.joined(separator: " ")
            }
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.hasPrefix("<"), !t.hasPrefix("Caveat:") else { return nil }
        return t
    }

    /// The first thing the user asked, from the start of a transcript.
    public static func firstUserText(_ head: String, agent: AgentKind) -> String? {
        for raw in head.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            if let t = userText(o, agent: agent) { return t }
        }
        return nil
    }

    /// The first `bytes` of each transcript, each after a `@@<nonce> F <index>` line.
    public static func headsScript(paths: [String], nonce: String, bytes: Int = 131_072) -> String {
        paths.enumerated().map { i, p in
            "echo \"@@\(nonce) F \(i)\"; F=\(shellQuotePath(p)); [ -f \"$F\" ] && head -c \(bytes) \"$F\"; echo"
        }.joined(separator: "\n") + "\nexit 0\n"
    }

    /// Splits `headsScript` output back into one text per path index.
    public static func parseHeads(_ out: String, nonce: String) -> [Int: String] {
        var res: [Int: String] = [:]
        var cur: Int?
        var buf: [Substring] = []
        func flush() { if let c = cur { res[c] = buf.joined(separator: "\n") }; buf = [] }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@\(nonce) F "), let i = Int(line.dropFirst("@@\(nonce) F ".count)) {
                flush(); cur = i
            } else if cur != nil { buf.append(line) }
        }
        flush()
        return res
    }

    /// One readable line: markdown marks dropped, whitespace collapsed, cut to `limit` with "…".
    public static func oneLine(_ s: String, limit: Int = 140) -> String {
        var t = s.replacingOccurrences(of: "```", with: " ")
        for mark in ["**", "__", "`", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    /// Prints the last `bytes` of a transcript: `path` if it exists, else the newest .jsonl in `dir`.
    public static func tailScript(path: String?, dir: String?, bytes: Int = 262_144) -> String {
        let p = path.map(shellQuotePath) ?? "''"
        let d = dir.map(shellQuotePath) ?? "''"
        return """
        F=\(p)
        if [ ! -f "$F" ] && [ -n \(d) ]; then F=$(ls -t \(d)/*.jsonl 2>/dev/null | head -n 1); fi
        [ -n "$F" ] && [ -f "$F" ] && tail -c \(bytes) "$F"
        exit 0
        """
    }
}
