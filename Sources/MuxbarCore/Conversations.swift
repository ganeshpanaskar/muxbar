import Foundation

/// An agent conversation recorded on a host — including ones started outside Muxbar — that can be
/// continued with the agent's resume command. Discovery needs each tool's transcript format, so
/// it covers the built-in agents; user-added agents can still be resumed by pasting an id.
/// - Claude Code: `~/.claude/projects/<dir>/<sessionId>.jsonl` → `claude --resume <id>`
/// - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl` → `codex resume <id>`
/// - Gemini CLI: `~/.gemini/tmp/<project>/chats/session-….json` → `gemini --resume <id>`
public struct Conversation: Equatable, Sendable, Identifiable {
    public var agent: String       // AgentProfile.id
    public var id: String          // the agent's session id
    public var cwd: String?
    public var firstPrompt: String?
    public var modified: Int       // file mtime (host clock)

    public init(agent: String = AgentProfile.claude.id, id: String, cwd: String?, firstPrompt: String?, modified: Int) {
        self.agent = agent
        self.id = id
        self.cwd = cwd
        self.firstPrompt = firstPrompt
        self.modified = modified
    }
}

public enum Conversations {
    /// Lists each agent's newest transcripts with their mtime, cwd and first few user lines.
    /// Lines are cut to keep the reply small; the parser copes with truncated JSON. An agent
    /// that isn't installed on the host simply contributes nothing.
    public static func script(nonce: String, limit: Int = 40) -> String {
        let m = "@@\(nonce)"
        return """
        mtime() { date -r "$1" +%s 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
        D="$HOME/.claude/projects"
        [ -d "$D" ] && ls -t "$D"/*/*.jsonl 2>/dev/null | head -n \(limit) | while IFS= read -r f; do
          echo "\(m) F claude $(basename "$f" .jsonl) $(mtime "$f")"
          grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -n 1
          grep -m6 '"type":"user"' "$f" 2>/dev/null | cut -c1-4000
        done
        D="$HOME/.codex/sessions"
        [ -d "$D" ] && find "$D" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r | head -n \(limit) | while IFS= read -r f; do
          id=$(head -n 1 "$f" 2>/dev/null | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
          [ -n "$id" ] || id=$(basename "$f" .jsonl | sed -E 's/.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$/\\1/')
          echo "\(m) F codex $id $(mtime "$f")"
          grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -n 1
          grep -m8 -e '"user_message"' -e '"role":"user"' "$f" 2>/dev/null | cut -c1-4000
        done
        D="$HOME/.gemini/tmp"
        [ -d "$D" ] && ls -t "$D"/*/chats/session-*.json 2>/dev/null | head -n \(limit) | while IFS= read -r f; do
          flat=$(head -c 400000 "$f" 2>/dev/null | tr '\\n\\r\\t' '   ' | sed -E 's/"[[:space:]]*:[[:space:]]*/":/g; s/,[[:space:]]+/,/g')
          id=$(printf '%s' "$flat" | grep -o '"sessionId":"[^"]*"' | head -n 1 | cut -d'"' -f4)
          [ -n "$id" ] || id=$(basename "$f" .json)
          echo "\(m) F gemini $id $(mtime "$f")"
          R="$(dirname "$(dirname "$f")")/.project_root"
          [ -f "$R" ] && printf '"cwd":"%s"\\n' "$(head -n 1 "$R")"
          printf '%s' "$flat" | grep -o -E '"type":"user","content":(\\[\\{"text":)?"[^"]*"' | head -n 6
        done
        echo "\(m) END"
        """
    }

    /// Parses `script` output, newest first across agents. Accepts `F <id> <mtime>` (Claude, from
    /// older builds) and `F <agent> <id> <mtime>`.
    public static func parse(_ output: String, nonce: String, limit: Int? = nil) -> [Conversation] {
        let m = "@@\(nonce) "
        var out: [Conversation] = []
        var cur: Conversation?
        func flush() { if let c = cur { out.append(c) }; cur = nil }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(m) {
                let body = line.dropFirst(m.count)
                if body.hasPrefix("F ") {
                    flush()
                    let f = body.split(separator: " ").map(String.init)
                    if f.count >= 4 {
                        cur = Conversation(agent: f[1], id: f[2], cwd: nil, firstPrompt: nil, modified: Int(f[3]) ?? 0)
                    } else if f.count >= 3 {
                        cur = Conversation(agent: AgentProfile.claude.id, id: f[1], cwd: nil, firstPrompt: nil, modified: Int(f[2]) ?? 0)
                    }
                } else if body == "END" {
                    flush()
                }
                continue
            }
            guard cur != nil else { continue }
            if line.hasPrefix("\"cwd\":\"") {
                cur?.cwd = jsonStringValue(line, key: "cwd")
            } else if cur?.firstPrompt == nil, let p = promptText(line) {
                cur?.firstPrompt = p
            }
        }
        flush()
        // Each agent's list is already newest first: merge them, keeping every agent's own order.
        var queues = Dictionary(grouping: out, by: \.agent).values.map { ArraySlice($0) }
        var merged: [Conversation] = []
        while let i = queues.indices.filter({ !queues[$0].isEmpty }).max(by: { queues[$0].first!.modified < queues[$1].first!.modified }) {
            merged.append(queues[i].removeFirst())
        }
        return limit.map { Array(merged.prefix($0)) } ?? merged
    }

    /// The user's typed text from a transcript line, skipping tool results, injected context and
    /// slash-command noise.
    static func promptText(_ line: String) -> String? {
        if line.contains("\"isMeta\":true") || line.contains("\"tool_result\"") { return nil }
        let text = jsonStringValue(line, key: "content") ?? jsonStringValue(line, key: "text")
            ?? jsonStringValue(line, key: "message")
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // <command-name>, <local-command-…>, <environment_context>, <user_instructions>
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("# AGENTS.md") { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        return t.count > 160 ? String(t.prefix(157)) + "…" : t
    }

    /// Extracts the first `"key":"…"` JSON string value, unescaping it. Works on truncated lines.
    static func jsonStringValue(_ line: String, key: String) -> String? {
        guard let r = line.range(of: "\"\(key)\":\"") else { return nil }
        var out = ""
        var i = r.upperBound
        var escaped = false
        var n = 0
        while i < line.endIndex, n < 600 {
            let c = line[i]
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"", "\\", "/": out.append(c)
                case "u":
                    let hex = line[line.index(after: i)...].prefix(4)
                    if hex.count == 4, let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) {
                        out.unicodeScalars.append(s)
                        i = line.index(i, offsetBy: 4)
                    }
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return out
            } else {
                out.append(c)
            }
            i = line.index(after: i)
            n += 1
        }
        return out.isEmpty ? nil : out
    }

    /// Session ids are UUIDs; accept any `[A-Za-z0-9_-]{8,64}` so pasted ids work but nothing
    /// shell-like gets through (the id is also shell-quoted).
    public static func isValidSessionID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Za-z0-9_-]{8,64}$"#, options: .regularExpression) != nil
    }

    /// Default tmux session name for a resumed conversation: the project folder's name.
    public static func sessionName(for conv: Conversation) -> String {
        let base = conv.cwd.map { ($0 as NSString).lastPathComponent } ?? conv.agent
        return sanitizeSessionName(base.isEmpty ? conv.agent : base)
    }

    /// Command for bringing back an ended session: its known conversation, else the newest one in
    /// that folder (e.g. `claude --continue`), else a fresh start of the agent.
    public static func resumeEndedCommand(agent: AgentProfile = .claude, sessionID: String?) -> String {
        if let id = sessionID, isValidSessionID(id), let cmd = agent.resumeCommand(id: id) { return cmd }
        return agent.continueOrStart
    }

    /// Command that continues the conversation inside the new session (nil: its agent is unknown
    /// or can't resume by id).
    public static func resumeCommand(_ conv: Conversation, agents: [AgentProfile] = AgentProfile.builtins) -> String? {
        agents.first { $0.id == conv.agent }?.resumeCommand(id: conv.id)
    }
}
