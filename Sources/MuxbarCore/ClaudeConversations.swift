import Foundation

/// A Claude Code conversation found in `~/.claude/projects/<dir>/<sessionId>.jsonl` on a host —
/// including ones started outside Muxbar — that can be continued with `claude --resume <id>`.
public struct ClaudeConversation: Equatable, Sendable, Identifiable {
    public var id: String          // Claude session id (file name)
    public var cwd: String?
    public var firstPrompt: String?
    public var modified: Int       // file mtime (host clock)

    public init(id: String, cwd: String?, firstPrompt: String?, modified: Int) {
        self.id = id
        self.cwd = cwd
        self.firstPrompt = firstPrompt
        self.modified = modified
    }
}

public enum ClaudeConversations {
    /// Lists the newest top-level transcripts with their mtime, cwd and first few user lines.
    /// Lines are cut to keep the reply small; the parser copes with truncated JSON.
    public static func script(nonce: String, limit: Int = 40) -> String {
        let m = "@@\(nonce)"
        return """
        D="$HOME/.claude/projects"
        [ -d "$D" ] || { echo "\(m) END"; exit 0; }
        ls -t "$D"/*/*.jsonl 2>/dev/null | head -n \(limit) | while IFS= read -r f; do
          id=$(basename "$f" .jsonl)
          mt=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
          echo "\(m) F $id $mt"
          grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -n 1
          grep -m6 '"type":"user"' "$f" 2>/dev/null | cut -c1-4000
        done
        echo "\(m) END"
        """
    }

    public static func parse(_ output: String, nonce: String) -> [ClaudeConversation] {
        let m = "@@\(nonce) "
        var out: [ClaudeConversation] = []
        var cur: ClaudeConversation?
        func flush() { if let c = cur { out.append(c) }; cur = nil }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(m) {
                let body = line.dropFirst(m.count)
                if body.hasPrefix("F ") {
                    flush()
                    let f = body.split(separator: " ")
                    guard f.count >= 3 else { continue }
                    cur = ClaudeConversation(id: String(f[1]), cwd: nil, firstPrompt: nil, modified: Int(f[2]) ?? 0)
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
        return out
    }

    /// The user's typed text from a transcript line, skipping tool results and slash-command noise.
    static func promptText(_ line: String) -> String? {
        if line.contains("\"isMeta\":true") || line.contains("\"tool_result\"") { return nil }
        let text = jsonStringValue(line, key: "content") ?? jsonStringValue(line, key: "text")
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") { return nil }   // <command-name>, <local-command-…>
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

    /// Claude session ids are UUIDs; accept any `[A-Za-z0-9_-]{8,64}` so pasted ids work but
    /// nothing shell-like gets through (the id is also shell-quoted).
    public static func isValidSessionID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^[A-Za-z0-9_-]{8,64}$"#, options: .regularExpression) != nil
    }

    /// Default tmux session name for a resumed conversation: the project folder's name.
    public static func sessionName(for conv: ClaudeConversation) -> String {
        let base = conv.cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        return sanitizeSessionName(base.isEmpty ? "claude" : base)
    }

    /// Command for bringing back an ended session: its known conversation, else the newest one in
    /// that folder (`claude --continue`).
    public static func resumeEndedCommand(claudeSessionID: String?) -> String {
        if let id = claudeSessionID, isValidSessionID(id) { return "claude --resume " + shellQuote(id) }
        return "claude --continue"
    }

    /// Command that continues the conversation inside the new session.
    public static func resumeCommand(_ conv: ClaudeConversation) -> String {
        "claude --resume " + shellQuote(conv.id)
    }
}
