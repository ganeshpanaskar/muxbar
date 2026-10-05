import Foundation

/// A coding-agent CLI Muxbar can launch, detect and resume. Muxbar never talks to any model API —
/// it runs the CLI in tmux and reads the screen — so any terminal agent works: the built-in
/// presets below, or one the user adds in Settings (Grok, Aider, whatever ships next).
public struct AgentProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Short stable slug ("claude", "grok"). Stored on sessions and conversations.
    public var id: String
    public var name: String
    /// Shell command that starts a new conversation ("grok", "aider --model sonnet").
    public var command: String
    /// Process names that mean this agent is running (default: the command's executable).
    /// Agents that run as `node`/`python` are recognised from their screen instead.
    public var processNames: [String]
    /// Continues a known conversation; `{id}` becomes the shell-quoted session id. nil = unsupported.
    public var resumeTemplate: String?
    /// Continues the newest conversation in the current folder. nil = just start `command`.
    public var continueCommand: String?
    /// Extra on-screen text meaning "waiting for your choice" / "busy" for this agent, on top of
    /// the generic markers every agent shares.
    public var waitingMarkers: [String]
    public var workingMarkers: [String]

    public init(id: String, name: String, command: String, processNames: [String]? = nil,
                resumeTemplate: String? = nil, continueCommand: String? = nil,
                waitingMarkers: [String] = [], workingMarkers: [String] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.processNames = processNames ?? AgentProfile.executable(of: command).map { [$0] } ?? []
        self.resumeTemplate = resumeTemplate
        self.continueCommand = continueCommand
        self.waitingMarkers = waitingMarkers
        self.workingMarkers = workingMarkers
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, processNames, resumeTemplate, continueCommand, waitingMarkers, workingMarkers
    }

    /// Tolerant decoding: hand-edited settings may leave out anything but id and command.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let command = try c.decode(String.self, forKey: .command)
        self.init(id: id,
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? id,
                  command: command,
                  processNames: try c.decodeIfPresent([String].self, forKey: .processNames),
                  resumeTemplate: try c.decodeIfPresent(String.self, forKey: .resumeTemplate),
                  continueCommand: try c.decodeIfPresent(String.self, forKey: .continueCommand),
                  waitingMarkers: try c.decodeIfPresent([String].self, forKey: .waitingMarkers) ?? [],
                  workingMarkers: try c.decodeIfPresent([String].self, forKey: .workingMarkers) ?? [])
    }

    public var canResumeByID: Bool { resumeTemplate?.contains("{id}") == true }

    /// Command that continues conversation `id`, or nil if this agent can't resume by id.
    public func resumeCommand(id: String) -> String? {
        guard let t = resumeTemplate, t.contains("{id}") else { return nil }
        return t.replacingOccurrences(of: "{id}", with: shellQuote(id))
    }

    /// Command that brings an ended session back: the newest conversation, else a fresh start.
    public var continueOrStart: String { continueCommand ?? command }

    // MARK: Built-in presets

    public static let claude = AgentProfile(
        id: "claude", name: "Claude Code", command: "claude",
        resumeTemplate: "claude --resume {id}", continueCommand: "claude --continue")
    public static let codex = AgentProfile(
        id: "codex", name: "Codex", command: "codex",
        resumeTemplate: "codex resume {id}", continueCommand: "codex resume --last")
    public static let gemini = AgentProfile(
        id: "gemini", name: "Gemini CLI", command: "gemini",
        resumeTemplate: "gemini --resume {id}", continueCommand: "gemini --resume latest")

    public static let builtins: [AgentProfile] = [.claude, .codex, .gemini]

    // MARK: Matching

    /// First word of a shell command that isn't `env` or a `VAR=value` assignment, without its path.
    public static func executable(of command: String?) -> String? {
        guard let command else { return nil }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first(where: { $0 != "env" && !$0.contains("=") }) else { return nil }
        return first.split(separator: "/").last.map(String.init) ?? first
    }

    /// The agent a shell command starts (`claude`, `/opt/bin/grok -m x`, `env X=1 codex`).
    public static func matching(command: String?, in agents: [AgentProfile] = builtins) -> AgentProfile? {
        guard let exe = executable(of: command) else { return nil }
        return agents.first { $0.processNames.contains(exe) || executable(of: $0.command) == exe }
    }

    static let versionName = try! NSRegularExpression(pattern: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#)

    /// The agent a process name belongs to. Native Claude installs can report a bare version
    /// string as the process name; some package managers report a full path.
    public static func matching(process name: String, in agents: [AgentProfile] = builtins) -> AgentProfile? {
        let base = (name.split(separator: "/").last.map(String.init) ?? name).trimmingCharacters(in: .whitespaces)
        for a in agents {
            for p in a.processNames where base == p || base.hasPrefix(p + " ") { return a }
        }
        if versionName.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil {
            return agents.first { $0.id == AgentProfile.claude.id } ?? .claude
        }
        return nil
    }

    /// A slug for a user-added agent: lowercase letters, digits and dashes.
    public static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let t = String(s.lowercased().map { allowed.contains($0) ? $0 : "-" })
        return t.split(separator: "-").joined(separator: "-")
    }
}
