import Foundation

/// Name used for the Mac itself in host lists.
public let localHost = "local"

public enum HostHealth: Equatable, Codable, Sendable {
    case unknown
    case ok
    case unreachable(String)
    case authExpired(String)
    case tmuxMissing
    case tmuxTooOld(String)

    public var isUsable: Bool { self == .ok }

    public var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .ok: return "OK"
        case .unreachable: return "Unreachable"
        case .authExpired: return "Auth expired"
        case .tmuxMissing: return "tmux missing"
        case .tmuxTooOld(let v): return "tmux too old (\(v))"
        }
    }

    /// Actionable hint shown to the user (F15 states; P0 keeps the text short).
    public var hint: String? {
        switch self {
        case .unknown, .ok: return nil
        case .unreachable(let detail):
            // Proxied ssh often reports only "Connection closed" without a tty, so always give next steps.
            let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Can't connect\(d.isEmpty ? "" : " (\(d))"). Check your network/VPN, your SSH credentials, and that the host is running."
        case .authExpired: return "SSH authentication failed — refresh your SSH key or certificate, then retry."
        case .tmuxMissing: return "Install tmux: `brew install tmux` on a Mac, `sudo apt install tmux` or `sudo dnf install tmux` on Linux."
        case .tmuxTooOld: return "Muxbar needs tmux ≥ 2.6. Upgrade tmux on the host."
        }
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case working
    case waiting
    case idle
    case notAgent = "notClaude"   // raw value kept so older state/CLI output stays readable
    case unknown
    case ended
    case running      // plain local tab (L1): agent process present, no pane text
    case notRunning   // plain local tab (L1): no agent process

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for input"
        case .idle: return "Idle"
        case .notAgent: return "No agent running"
        case .unknown: return "Unknown"
        case .ended: return "Ended"
        case .running: return "Running"
        case .notRunning: return "Not running"
        }
    }
}

/// Which terminal app a tab belongs to.
public enum TerminalKind: String, Codable, Sendable, CaseIterable {
    /// Terminal pane inside Muxbar's own window (default).
    case embedded
    case terminal
    case iterm

    public var displayName: String {
        switch self {
        case .embedded: return "Muxbar"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        }
    }

    public var isExternal: Bool { self != .embedded }
}

/// Reference to a terminal window/tab Muxbar opened.
public struct TabRef: Codable, Equatable, Sendable {
    public var kind: TerminalKind
    public var windowID: Int?
    public var tty: String?
    public var itermSessionID: String?

    public init(kind: TerminalKind, windowID: Int? = nil, tty: String? = nil, itermSessionID: String? = nil) {
        self.kind = kind
        self.windowID = windowID
        self.tty = tty
        self.itermSessionID = itermSessionID
    }
}

/// A tmux session as reported by a host probe.
public struct ProbedSession: Equatable, Sendable {
    public var id: String          // tmux session_id, e.g. "$3"
    public var name: String
    public var created: Int
    public var activity: Int
    public var attached: Int
    public var command: String?    // active pane's current command
    public var path: String?       // active pane's current path
    public var capture: [String]?  // last lines of the active pane (status probes only)
    public var processes: [String]? // process names in the active pane's process tree (any pty)
    public var windowActivity: Int?  // last output time of the active window (host clock)

    public init(id: String, name: String, created: Int, activity: Int, attached: Int,
                command: String? = nil, path: String? = nil, capture: [String]? = nil,
                processes: [String]? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.activity = activity
        self.attached = attached
        self.command = command
        self.path = path
        self.capture = capture
        self.processes = processes
    }
}

public struct ProbeResult: Equatable, Sendable {
    public var tmuxVersion: String?
    public var tmuxMissing: Bool
    public var sessions: [ProbedSession]
    public var hostNow: Int?       // host clock, for activity age

    public init(tmuxVersion: String?, tmuxMissing: Bool, sessions: [ProbedSession], hostNow: Int?) {
        self.tmuxVersion = tmuxVersion
        self.tmuxMissing = tmuxMissing
        self.sessions = sessions
        self.hostNow = hostNow
    }
}

/// Stable identity: tmux reuses `$N` after a server restart, so `created` is part of the key.
public func sessionKey(host: String, tmuxID: String, created: Int) -> String {
    "\(host)|\(tmuxID)|\(created)"
}

/// Metadata Muxbar keeps about a session. tmux stays the source of truth for name and liveness.
public struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var host: String
    public var tmuxID: String?        // nil for plain local tabs (L1)
    public var created: Int
    public var name: String
    public var path: String?
    public var lastActivity: Int?
    public var ended: Bool
    public var tab: TabRef?
    // Reserved for P1 (F7, F10, F11, F13b).
    public var tags: [String]
    public var note: String?
    /// The agent's conversation id (Claude/Codex/Gemini session id), for resuming.
    public var conversationID: String?
    /// `AgentProfile.id` of the agent this session runs, when Muxbar knows it.
    public var agent: String?
    public var archived: Bool
    /// User-created sidebar group this session belongs to (nil = listed under its host).
    public var group: String?
    /// Workspace folder Muxbar created for this session (follows renames/moves). nil = user-chosen folder.
    public var managedDir: String?
    /// Who created the session. nil (older records): Muxbar if it has a workspace folder, else outside.
    public var origin: SessionOrigin?

    /// Sessions started outside Muxbar live in the host's "Others" section and can't join groups.
    public var isOutside: Bool { (origin ?? (managedDir != nil ? .muxbar : .outside)) == .outside }

    public var id: String { key }
    public var isPlainTab: Bool { tmuxID == nil }

    enum CodingKeys: String, CodingKey {
        case key, host, tmuxID, created, name, path, lastActivity, ended, tab, tags, note, archived, group,
             managedDir, origin, agent
        case conversationID = "claudeSessionID"   // name from when only Claude was supported
    }

    public init(key: String, host: String, tmuxID: String?, created: Int, name: String,
                path: String? = nil, lastActivity: Int? = nil, ended: Bool = false, tab: TabRef? = nil) {
        self.key = key
        self.host = host
        self.tmuxID = tmuxID
        self.created = created
        self.name = name
        self.path = path
        self.lastActivity = lastActivity
        self.ended = ended
        self.tab = tab
        self.tags = []
        self.note = nil
        self.conversationID = nil
        self.agent = nil
        self.archived = false
    }
}

public enum SessionOrigin: String, Codable, Sendable {
    case muxbar    // created by Muxbar (New Session, Continue Session, resume…)
    case outside   // discovered: started with tmux outside Muxbar
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var terminal: TerminalKind = .embedded
    /// Runs when a new session's terminal opens. Empty = just a login shell.
    public var defaultCommand: String = "claude"
    /// Extra agent CLIs beyond the built-in presets (same id overrides a preset). Lets any tool get
    /// resume-by-id and its own status markers; see `AgentProfile`.
    public var customAgents: [AgentProfile] = []
    /// Extra ssh config file (`ssh -F`). nil = the user's normal config.
    public var sshConfigFile: String?
    /// Test/diagnostic switch: behave as if tmux were not installed locally (L1 path).
    public var disableLocalTmux: Bool = false
    /// Workspace root per host (`<root>/<group>/<session>`). Missing = default for that host.
    public var workspaceRoots: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case terminal, defaultCommand, customAgents, sshConfigFile, disableLocalTmux, workspaceRoots }

    /// Tolerant decoding: settings written by older versions lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = (try? c.decodeIfPresent(TerminalKind.self, forKey: .terminal)) ?? .embedded
        defaultCommand = try c.decodeIfPresent(String.self, forKey: .defaultCommand) ?? "claude"
        customAgents = (try? c.decodeIfPresent([AgentProfile].self, forKey: .customAgents)) ?? []
        sshConfigFile = try c.decodeIfPresent(String.self, forKey: .sshConfigFile)
        disableLocalTmux = try c.decodeIfPresent(Bool.self, forKey: .disableLocalTmux) ?? false
        workspaceRoots = try c.decodeIfPresent([String: String].self, forKey: .workspaceRoots) ?? [:]
    }

    /// Every agent Muxbar recognises: the user's own, the built-in presets, and — when the default
    /// command is some other CLI (e.g. `grok`) — a profile derived from it, so its status shows.
    public var agents: [AgentProfile] {
        var all = customAgents
        for b in AgentProfile.builtins where !all.contains(where: { $0.id == b.id }) { all.append(b) }
        if AgentProfile.matching(command: defaultCommand, in: all) == nil,
           let exe = AgentProfile.executable(of: defaultCommand), !AgentProfile.slug(exe).isEmpty {
            all.append(AgentProfile(id: AgentProfile.slug(exe), name: exe, command: defaultCommand))
        }
        return all
    }

    /// The agent the default command starts (nil: a plain shell or not an agent).
    public var defaultAgent: AgentProfile? { AgentProfile.matching(command: defaultCommand, in: agents) }

    public func agent(id: String?) -> AgentProfile? { id.flatMap { i in agents.first { $0.id == i } } }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int = AppState.currentSchema
    public var hosts: [String] = [localHost]
    public var sessions: [String: SessionRecord] = [:]
    public var recentDirs: [String: [String]] = [:]
    public var settings = AppSettings()
    /// Built-in panes that were open, and the selected session — restored on the next launch.
    public var openPanes: [String] = []
    public var lastSelected: String?
    /// User-created sidebar groups per host (host → names in display order). A group lives under
    /// one host — the Mac or a remote SSH host — and only holds that host's sessions.
    public var groups: [String: [String]] = [:]

    public func groups(for host: String) -> [String] { groups[host] ?? [] }
    public func hasGroup(_ name: String, host: String) -> Bool { groups(for: host).contains(name) }

    public init() {}

    enum CodingKeys: String, CodingKey { case schemaVersion, hosts, sessions, recentDirs, settings, groups, openPanes, lastSelected }

    /// Missing keys take defaults, so state files from older versions load (adding a field must
    /// never make an existing state.json look corrupt).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AppState.currentSchema
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? [localHost]
        sessions = try c.decodeIfPresent([String: SessionRecord].self, forKey: .sessions) ?? [:]
        recentDirs = try c.decodeIfPresent([String: [String]].self, forKey: .recentDirs) ?? [:]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        openPanes = try c.decodeIfPresent([String].self, forKey: .openPanes) ?? []
        lastSelected = try c.decodeIfPresent(String.self, forKey: .lastSelected)
        if let g = try? c.decodeIfPresent([String: [String]].self, forKey: .groups) {
            groups = g
        } else if let flat = try? c.decodeIfPresent([String].self, forKey: .groups) {
            // Earlier builds had host-less groups: place each under the host of its sessions
            // (a group spanning hosts is split per host); empty ones are dropped.
            groups = [:]
            for name in flat {
                let hosts = Set(sessions.values.filter { $0.group == name }.map(\.host))
                for h in hosts.sorted() { groups[h, default: []].append(name) }
            }
        } else {
            groups = [:]
        }
    }

    /// Policy: outside sessions stay in Others — take them out of any group. Returns how many moved.
    @discardableResult
    public mutating func ejectOutsideFromGroups() -> Int {
        var n = 0
        for (k, r) in sessions where r.isOutside && r.group != nil { sessions[k]?.group = nil; n += 1 }
        return n
    }

    public mutating func rememberDir(_ dir: String, host: String) {
        var dirs = recentDirs[host] ?? []
        dirs.removeAll { $0 == dir }
        dirs.insert(dir, at: 0)
        recentDirs[host] = Array(dirs.prefix(10))
    }
}
