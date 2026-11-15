import Foundation

/// Classifies a pane from its processes and last screen lines (F8).
/// Heuristic by design: when no rule matches confidently it answers `.unknown`.
/// Patterns are pinned by fixtures in Tests/MuxbarCoreTests/Fixtures/status.
public enum StatusClassifier {
    /// Text that only appears while Claude Code waits for a choice (permission, trust, menus).
    static let waitingMarkers = ["Do you want to", "Enter to confirm", "Esc to cancel", "Would you like to"]

    /// Claude Code's busy line: a spinner glyph, a gerund, then an ellipsis
    /// ("✽ Considering… (6s · thinking)"). Older versions print "esc to interrupt".
    static let workingRegex = try! NSRegularExpression(pattern: #"^\s*[·✢✳✶✻✽*]\s+\S[^\n]*…"#)
    /// A finished turn: "✻ Sautéed for 25s · done 7:03 AM", "✻ Baked for 1m 2s".
    static let completionRegex = try! NSRegularExpression(
        pattern: #"^\s*[·✢✳✶✻✽*]\s+\S+ for (\d+h\s*)?(\d+m\s*)?\d+s\b"#)
    static let numberedChoice = try! NSRegularExpression(pattern: #"^\s*❯\s+\d+\.\s"#)
    /// The user's submitted prompt echoed in the transcript: "❯ some text" (not the empty input box).
    static let promptEcho = try! NSRegularExpression(pattern: #"^❯ +\S"#)
    static let versionName = try! NSRegularExpression(pattern: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#)
    /// An interrupted turn (Esc): "⎿  Interrupted · What should Claude do instead?". Claude fires no
    /// hook for it, so the screen is the only signal that the turn is over.
    static let interrupted = try! NSRegularExpression(pattern: #"^\s*⎿\s+Interrupted\b"#)

    /// True if any process on the pane's tty is Claude Code. Native installs can report a bare
    /// version string as the process name; some package managers report a full path.
    public static func isClaudeProcess(_ name: String) -> Bool {
        let base = (name.split(separator: "/").last.map(String.init) ?? name).trimmingCharacters(in: .whitespaces)
        if base == "claude" || base.hasPrefix("claude ") { return true }
        return versionName.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil
    }

    /// Output newer than this (seconds) means the screen is being written to right now.
    public static let streamingAge = 2

    /// Other terminal agents recognised by process name. Muxbar has no deep integration with them
    /// (hooks, history, sleep), but their screens are read with generic rules. Settings → New
    /// sessions → Other command adds its own executable to this list.
    public static let knownOtherAgents = ["gemini", "grok", "aider", "opencode", "goose", "amp", "qwen",
                                          "crush", "cursor-agent", "copilot", "kimi", "droid"]

    /// - Parameter outputAge: seconds since the pane last produced output (tmux `window_activity`).
    /// - Parameter otherAgents: process names of other agent CLIs (see `knownOtherAgents`).
    public static func classify(processes: [String]?, lines: [String]?, outputAge: Int? = nil,
                                otherAgents: [String] = knownOtherAgents) -> SessionStatus {
        let lines = lines ?? []
        let claudeByProcess = processes?.contains(where: isClaudeProcess)
        if claudeByProcess != true, processes?.contains(where: { AgentAdapter.kind(argv0: $0, args: $0) == .codex }) == true {
            return classifyCodex(lines)
        }
        if claudeByProcess != true, processes?.contains(where: { isOtherAgentProcess($0, otherAgents) }) == true {
            return classifyGeneric(lines, outputAge: outputAge)
        }
        let looksLikeClaude = lines.contains { $0.contains("⏵⏵") || $0.contains("⏸") || $0.contains("? for shortcuts") }
            || hasInputBox(lines)

        if let byProcess = claudeByProcess {
            if !byProcess {
                // `node` alone isn't proof (other Node apps), but a Claude screen plus node is.
                let node = processes?.contains { ($0.split(separator: "/").last ?? "") == "node" } ?? false
                if !(node && looksLikeClaude) { return .notClaude }
            }
        } else if lines.isEmpty {
            return .unknown
        }

        if lines.isEmpty { return .unknown }
        if lines.contains(where: { l in waitingMarkers.contains(where: l.contains) || matches(numberedChoice, l) }) {
            return .waiting
        }
        if lines.contains(where: { $0.contains("esc to interrupt") || matches(workingRegex, $0) }) {
            return .working
        }
        guard hasInputBox(lines) else { return .unknown }
        // While a reply streams, this Claude Code version shows no spinner, only the input box.
        // A finished turn leaves a completion line; a fresh session shows only the banner.
        if lines.contains(where: { matches(completionRegex, $0) }) { return .idle }
        // Interrupted after the last prompt you sent: the turn is over.
        if let i = lines.lastIndex(where: { matches(interrupted, $0) }),
           i > (lines.lastIndex(where: { matches(promptEcho, $0) }) ?? -1) { return .idle }
        let conversation = lines.contains { $0.hasPrefix("⏺") || matches(promptEcho, $0) }
        if let age = outputAge, age <= streamingAge {
            return conversation ? .working : .unknown
        }
        if !conversation { return .idle }
        // Conversation on screen, no completion line, output stopped (e.g. just after
        // `claude --resume`): probably idle, but not certain enough to say so.
        return .unknown
    }

    /// Codex's menus (hook trust, approvals): "› 1. Yes, proceed", with a confirm hint below.
    static let codexChoice = try! NSRegularExpression(pattern: #"^\s*›\s+\d+\.\s"#)
    /// Codex's busy line: "• Working (18s • esc to interrupt)".
    static let codexWorking = try! NSRegularExpression(pattern: #"^\s*•\s+Working\b"#)

    /// Codex's screen (used when its hooks aren't installed or trusted yet). A turn always shows
    /// the Working line; otherwise the input line and its "? for shortcuts" footer mean idle.
    static func classifyCodex(_ lines: [String]) -> SessionStatus {
        if lines.isEmpty { return .unknown }
        if lines.contains(where: { matches(codexChoice, $0) }),
           lines.contains(where: { $0.contains("confirm") || $0.contains("Would you like to") }) { return .waiting }
        if lines.contains(where: { matches(codexWorking, $0) || $0.contains("esc to interrupt") }) { return .working }
        if lines.contains(where: { $0.contains("? for shortcuts") }) || lines.last(where: { $0.hasPrefix("› ") }) != nil {
            return .idle
        }
        return .unknown
    }

    /// A process (name or `ps` args) is one of `names`, by its executable's base name.
    public static func isOtherAgentProcess(_ process: String, _ names: [String]) -> Bool {
        let first = process.split(separator: " ").first.map(String.init) ?? process
        let base = first.split(separator: "/").last.map(String.init) ?? first
        if names.contains(base) { return true }
        // npm installs run as `node …/bin/gemini`.
        guard base == "node" || base == "bun" || base.lowercased().hasPrefix("python") else { return false }
        let words = process.split(separator: " ").dropFirst().prefix(2)
        return words.contains { w in names.contains(w.split(separator: "/").last.map(String.init) ?? String(w)) }
    }

    /// Text other agent CLIs show while waiting for a decision.
    static let genericWaitingMarkers = ["Do you want to", "Would you like to", "Allow execution", "Allow once",
                                        "Yes, allow", "Apply this change?", "Waiting for user confirmation",
                                        "(y/n)", "[y/N]", "[Y/n]"]
    /// A menu choice under the cursor: "❯ 1. Yes", "› 1. Yes", "● 1. Yes".
    static let genericChoice = try! NSRegularExpression(pattern: #"^\s*[│ ]*[❯›●▶]\s+\d+\.\s"#)
    /// Busy lines: "(esc to cancel, 12s)", "esc to interrupt", "Esc to stop".
    static let genericWorking = try! NSRegularExpression(pattern: #"(?i)\(?esc to (cancel|interrupt|stop)\b"#)

    /// Any other agent CLI's screen (Gemini CLI, Grok, Aider…): menus and confirmations are
    /// waiting, a busy line is working, a screen that stopped changing is idle.
    static func classifyGeneric(_ lines: [String], outputAge: Int?) -> SessionStatus {
        if lines.isEmpty { return .unknown }
        let tail = Array(lines.suffix(15))
        // A question above the newest input prompt was already answered (the input box shows
        // again); a busy line shows together with the input box, so that one counts anywhere.
        let prompt = tail.lastIndex(where: { matches(genericPrompt, $0) && !matches(genericChoice, $0) }) ?? -1
        if tail.suffix(from: prompt + 1).contains(where: { l in genericWaitingMarkers.contains(where: l.contains) || matches(genericChoice, l) }) {
            return .waiting
        }
        // A busy line redraws its timer every second; one left on a screen that stopped changing
        // is stale.
        if tail.contains(where: { matches(genericWorking, $0) }), (outputAge ?? 0) <= 5 { return .working }
        guard let age = outputAge else { return .unknown }
        return age > 5 ? .idle : .unknown
    }

    /// An input line: "> ", "❯ ", "› " at the start (or inside a box border).
    static let genericPrompt = try! NSRegularExpression(pattern: #"^\s*[│|]?\s*[>❯›]( |$)"#)

    /// The latest turn was interrupted (Esc): the "Interrupted" line comes after the last prompt
    /// you sent. Claude fires no hook for this, so it's how a stale "working" hook state ends.
    public static func interruptedLatestTurn(_ lines: [String]?) -> Bool {
        guard let lines, let i = lines.lastIndex(where: { matches(interrupted, $0) }) else { return false }
        return i > (lines.lastIndex(where: { matches(promptEcho, $0) }) ?? -1)
    }

    /// The prompt box: a `❯` line directly framed by horizontal rules.
    static func hasInputBox(_ lines: [String]) -> Bool {
        for (i, l) in lines.enumerated() where l.trimmingCharacters(in: .whitespaces).hasPrefix("❯") {
            let above = i > 0 ? lines[i - 1] : ""
            let below = i + 1 < lines.count ? lines[i + 1] : ""
            if above.contains("──") && below.contains("──") { return true }
            if above.contains("──") || l.contains("? for shortcuts") { return true }
        }
        return false
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
