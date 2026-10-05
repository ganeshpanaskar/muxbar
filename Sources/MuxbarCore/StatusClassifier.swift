import Foundation

/// Classifies a pane from its processes and last screen lines (F8).
/// Heuristic by design: when no rule matches confidently it answers `.unknown`.
/// Agent-neutral: the markers below cover the built-in agents' screens plus generic conventions,
/// and each `AgentProfile` can add its own (user-added CLIs such as Grok).
/// Patterns are pinned by fixtures in Tests/MuxbarCoreTests/Fixtures/status.
public enum StatusClassifier {
    /// Text that only appears while an agent waits for a choice (permission, trust, menus).
    /// Claude Code: "Do you want to…", "Esc to cancel". Codex: "Would you like to run…",
    /// "Yes, proceed". Gemini CLI: "Allow execution of…", "Apply this change?", "Yes, allow once".
    static let waitingMarkers = ["Do you want to", "Enter to confirm", "Esc to cancel", "Would you like to",
                                 "Yes, proceed", "Allow execution", "Apply this change?", "Yes, allow once"]

    /// Claude Code's busy line: a spinner glyph, a gerund, then an ellipsis
    /// ("✽ Considering… (6s · thinking)"). Older versions print "esc to interrupt".
    static let workingRegex = try! NSRegularExpression(pattern: #"^\s*[·✢✳✶✻✽*]\s+\S[^\n]*…"#)
    /// Gemini CLI's busy line: "⠋ Thinking about it (esc to cancel, 12s)".
    static let geminiWorkingRegex = try! NSRegularExpression(pattern: #"\(esc to cancel, \d+"#)
    /// A finished turn: "✻ Sautéed for 25s · done 7:03 AM", "✻ Baked for 1m 2s".
    static let completionRegex = try! NSRegularExpression(
        pattern: #"^\s*[·✢✳✶✻✽*]\s+\S+ for (\d+h\s*)?(\d+m\s*)?\d+s\b"#)
    /// A highlighted menu option: "❯ 1. Yes" (Claude), "› 1. Yes" / "▌ 1. Yes" (Codex), "● 1. Yes" (Gemini).
    static let numberedChoice = try! NSRegularExpression(pattern: #"^[\s│]*[❯›▌●]\s+\d+\.\s"#)
    /// The user's submitted prompt echoed in the transcript: "❯ some text" (not the empty input box).
    static let promptEcho = try! NSRegularExpression(pattern: #"^❯ +\S"#)

    /// True if the process is one of `agents`. See `AgentProfile.matching(process:in:)`.
    public static func isAgentProcess(_ name: String, agents: [AgentProfile] = AgentProfile.builtins) -> Bool {
        AgentProfile.matching(process: name, in: agents) != nil
    }

    /// Output newer than this (seconds) means the screen is being written to right now.
    public static let streamingAge = 2

    /// - Parameter outputAge: seconds since the pane last produced output (tmux `window_activity`).
    /// - Parameter agents: the agents to recognise (built-ins plus the user's own).
    public static func classify(processes: [String]?, lines: [String]?, outputAge: Int? = nil,
                                agents: [AgentProfile] = AgentProfile.builtins) -> SessionStatus {
        let lines = lines ?? []
        let agentByProcess = processes?.contains { isAgentProcess($0, agents: agents) }
        let waiting = waitingMarkers + agents.flatMap(\.waitingMarkers).filter { !$0.isEmpty }
        let working = ["esc to interrupt"] + agents.flatMap(\.workingMarkers).filter { !$0.isEmpty }

        if let byProcess = agentByProcess {
            if !byProcess {
                // A runtime alone isn't proof (other Node/Python apps), but an agent screen plus
                // one is — that's how Gemini CLI and npm/pip-installed agents show up.
                let runtimes: Set<Substring> = ["node", "bun", "deno", "python", "python3"]
                let runtime = processes?.contains { runtimes.contains($0.split(separator: "/").last ?? "") } ?? false
                if !(runtime && looksLikeAgent(lines, agents: agents)) { return .notAgent }
            }
        } else if lines.isEmpty {
            return .unknown
        }

        if lines.isEmpty { return .unknown }
        if lines.contains(where: { l in waiting.contains(where: l.contains) || matches(numberedChoice, l) }) {
            return .waiting
        }
        if lines.contains(where: { l in working.contains(where: l.contains) || matches(workingRegex, l) || matches(geminiWorkingRegex, l) }) {
            return .working
        }
        guard hasInputBox(lines) else { return .unknown }
        // While a reply streams, this Claude Code version shows no spinner, only the input box.
        // A finished turn leaves a completion line; a fresh session shows only the banner.
        if lines.contains(where: { matches(completionRegex, $0) }) { return .idle }
        let conversation = lines.contains { $0.hasPrefix("⏺") || matches(promptEcho, $0) }
        if let age = outputAge, age <= streamingAge {
            return conversation ? .working : .unknown
        }
        if !conversation { return .idle }
        // Conversation on screen, no completion line, output stopped (e.g. just after
        // `claude --resume`): probably idle, but not certain enough to say so.
        return .unknown
    }

    /// Screen furniture that only agent CLIs draw (status bars, shortcut hints, input boxes).
    static func looksLikeAgent(_ lines: [String], agents: [AgentProfile] = []) -> Bool {
        let markers = ["⏵⏵", "⏸", "? for shortcuts", "context left", "Type your message", "⏎ send"]
            + agents.flatMap { $0.waitingMarkers + $0.workingMarkers }.filter { !$0.isEmpty }
        return lines.contains { l in markers.contains(where: l.contains) } || hasInputBox(lines)
    }

    /// The prompt box: a prompt glyph line directly framed by horizontal rules — `❯` (Claude),
    /// `›` (Codex) or `>` inside a `╭──╮` box (Gemini).
    static func hasInputBox(_ lines: [String]) -> Bool {
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: CharacterSet(charactersIn: " │\t"))
            guard t.hasPrefix("❯") || t.hasPrefix("›") || (t.hasPrefix(">") && l.contains("│")) else { continue }
            let above = i > 0 ? lines[i - 1] : ""
            let below = i + 1 < lines.count ? lines[i + 1] : ""
            if above.contains("──") && below.contains("──") { return true }
            if above.contains("──") || l.contains("? for shortcuts") { return true }
            if below.contains("? for shortcuts") || below.contains("context left") { return true }
        }
        return false
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
