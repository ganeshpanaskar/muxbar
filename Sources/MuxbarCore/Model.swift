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
            // ssh through a proxy often reports only "Connection closed", so always give next steps.
            let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Can't connect\(d.isEmpty ? "" : " (\(d))"). Check the network or VPN, your SSH credentials, and that the host is running."
        case .authExpired: return "SSH authentication failed — check your key or credentials (try `ssh <host>` in a terminal)."
        case .tmuxMissing: return "Install tmux: `brew install tmux` on a Mac, `sudo apt install tmux` or `sudo dnf install tmux` on Linux."
        case .tmuxTooOld: return "Muxbar needs tmux ≥ 2.6. Upgrade tmux on the host."
        }
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case working
    case waiting
    case idle
    case notClaude
    case unknown
    case ended
    case running      // plain local tab (L1): claude process present, no pane text
    case notRunning   // plain local tab (L1): no claude process

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for input"
        case .idle: return "Idle"
        case .notClaude: return "No agent running"
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
    public var paneIDs: [String] = []   // every pane of the session ("%3", …)
    public var activePane: String?
    public var memoryKB = 0             // RSS of all its panes' processes (F3)

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
    public var panes: [ProbedPane]
    public var memory: HostMemory?
    /// tmux server's socket name (prefix of its hook state files).
    public var serverHash: String?
    /// F8: forwardable listening ports (Linux hosts; nil = not scanned).
    public var ports: [ListeningPort]?

    public init(tmuxVersion: String?, tmuxMissing: Bool, sessions: [ProbedSession], hostNow: Int?,
                panes: [ProbedPane] = [], memory: HostMemory? = nil, serverHash: String? = nil,
                ports: [ListeningPort]? = nil) {
        self.ports = ports
        self.tmuxVersion = tmuxVersion
        self.tmuxMissing = tmuxMissing
        self.sessions = sessions
        self.hostNow = hostNow
        self.panes = panes
        self.memory = memory
        self.serverHash = serverHash
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
    public var claudeSessionID: String?
    public var archived: Bool
    /// User-created sidebar group this session belongs to (nil = listed under its host).
    public var group: String?
    /// Workspace folder Muxbar created for this session (follows renames/moves). nil = user-chosen folder.
    public var managedDir: String?
    /// Who created the session. nil (older records): Muxbar if it has a workspace folder, else outside.
    public var origin: SessionOrigin?
    /// Last agent seen running in the session, and its conversation id (kept after it exits, for resume).
    public var agent: AgentKind?
    public var agentSessionID: String?
    /// Finished or started waiting while you weren't looking (F2).
    public var unread = false
    public var lastViewedAt: Int?
    public var finishedAt: Int?
    /// Start of the agent's last reply (≤ 140 chars), shown in the Inbox.
    public var lastReply: String?
    /// Set while the agent is asleep (F4): what to resume and how much memory it freed.
    public var sleep: SleepInfo?
    public var neverSleep = false
    /// F7: the conversation's first prompt (for ⌘K matching) and the conversation it belongs to.
    public var firstPrompt: String?
    public var firstPromptID: String?

    /// Sessions started outside Muxbar live in the host's "Others" section and can't join groups.
    public var isOutside: Bool { (origin ?? (managedDir != nil ? .muxbar : .outside)) == .outside }

    public var id: String { key }
    public var isPlainTab: Bool { tmuxID == nil }

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
        self.claudeSessionID = nil
        self.archived = false
    }

    /// The conversation to resume: the agent's id, else (older records) the Claude id.
    public var resumeID: String? { agentSessionID ?? claudeSessionID }

    enum CodingKeys: String, CodingKey {
        case key, host, tmuxID, created, name, path, lastActivity, ended, tab, tags, note, claudeSessionID, archived
        case group, managedDir, origin, agent, agentSessionID, unread, lastViewedAt, finishedAt, lastReply, sleep, neverSleep
        case firstPrompt, firstPromptID
    }

    /// Tolerant decoding: records written by older versions lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        host = try c.decode(String.self, forKey: .host)
        tmuxID = try c.decodeIfPresent(String.self, forKey: .tmuxID)
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        name = try c.decode(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        lastActivity = try c.decodeIfPresent(Int.self, forKey: .lastActivity)
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        tab = try? c.decodeIfPresent(TabRef.self, forKey: .tab)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group)
        managedDir = try c.decodeIfPresent(String.self, forKey: .managedDir)
        origin = try? c.decodeIfPresent(SessionOrigin.self, forKey: .origin)
        agent = try? c.decodeIfPresent(AgentKind.self, forKey: .agent)
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)
        if agentSessionID == nil, agent == nil || agent == .claude { agentSessionID = claudeSessionID }
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        lastViewedAt = try c.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        finishedAt = try c.decodeIfPresent(Int.self, forKey: .finishedAt)
        lastReply = try c.decodeIfPresent(String.self, forKey: .lastReply)
        sleep = try? c.decodeIfPresent(SleepInfo.self, forKey: .sleep)
        neverSleep = try c.decodeIfPresent(Bool.self, forKey: .neverSleep) ?? false
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        firstPromptID = try c.decodeIfPresent(String.self, forKey: .firstPromptID)
    }
}

/// A sleeping agent (F4): exited to free memory; woken by typing its resume command.
public struct SleepInfo: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var sessionID: String
    public var cwd: String?
    public var flags: [String]
    public var sleptAt: Int
    public var freedKB: Int

    public init(agent: AgentKind, sessionID: String, cwd: String?, flags: [String], sleptAt: Int, freedKB: Int) {
        self.agent = agent; self.sessionID = sessionID; self.cwd = cwd; self.flags = flags
        self.sleptAt = sleptAt; self.freedKB = freedKB
    }

    public var resumeCommand: String {
        AgentAdapter.resumeCommand(agent, sessionID: sessionID, cwd: cwd, flags: flags)
    }
}

/// A remote port forwarded to the Mac over the host's ssh connection (F8).
public struct PortForward: Codable, Equatable, Sendable {
    public var remote: Int
    public var local: Int
    public var createdAt: Int
    /// Where it connects on the host (127.0.0.1, or [::1] for an IPv6-only server).
    public var target: String?

    public init(remote: Int, local: Int, createdAt: Int, target: String? = nil) {
        self.remote = remote; self.local = local; self.createdAt = createdAt; self.target = target
    }
}

/// Main-window layout (F10): one session, or a grid of live sessions.
public enum PaneLayout: String, Codable, Sendable { case single, grid }

public enum DockBadgeMode: String, Codable, Sendable, CaseIterable {
    case needsInput
    case needsInputAndFinished
}

public enum SessionOrigin: String, Codable, Sendable {
    case muxbar    // created by Muxbar (New Session, Continue Claude Session…)
    case outside   // discovered: started with tmux outside Muxbar
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var terminal: TerminalKind = .embedded
    public var defaultCommand: String = "claude"
    /// Extra ssh config file (`ssh -F`). nil = the user's normal config.
    public var sshConfigFile: String?
    /// Test/diagnostic switch: behave as if tmux were not installed locally (L1 path).
    public var disableLocalTmux: Bool = false
    /// Workspace root per host (`<root>/<group>/<session>`). Missing = default for that host.
    public var workspaceRoots: [String: String] = [:]
    /// Pass mouse clicks/drags to apps that ask for them (Claude Code, vim…). Off by default, so
    /// drag-to-select and ⌘C always work; when on, hold ⌥ while dragging to select text.
    public var passMouseToApps: Bool = false
    /// F2: notify when an agent finishes a turn; what the Dock badge counts.
    public var notifyOnFinish: Bool = true
    public var dockBadgeMode: DockBadgeMode = .needsInputAndFinished
    /// F3: host memory thresholds (% used) and alerts.
    public var memWarnPct: Int = 80
    public var memCritPct: Int = 90
    public var memAlerts: Bool = true
    /// F4: sleep idle agents after this many minutes (nil = off); wake a sleeping one when opened.
    public var autoSleepMinutes: Int?
    public var wakeOnOpen: Bool = true
    /// F8: forward new ports opened by your sessions automatically.
    public var autoForward: Bool = false
    /// F11: the first-launch setup was completed or skipped (nil = never decided; existing installs
    /// are marked done on load).
    public var setupDone: Bool?
    /// What New Session starts in the pane: "shell" (a login shell), "claude", "codex" or "other"
    /// (`otherCommand`); the last choice is kept for next time.
    public var newSessionStart: String = "claude"
    /// Any other agent CLI to start ("gemini", "grok", "aider --model x"…).
    public var otherCommand: String = ""
    /// Check GitHub for new releases on launch and daily; same-major ones install themselves.
    public var checkForUpdates: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case terminal, defaultCommand, sshConfigFile, disableLocalTmux, workspaceRoots, passMouseToApps
        case notifyOnFinish, dockBadgeMode, memWarnPct, memCritPct, memAlerts, autoSleepMinutes, wakeOnOpen, autoForward
        case setupDone, newSessionStart, otherCommand, checkForUpdates
    }

    /// Tolerant decoding: settings written by older versions lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = (try? c.decodeIfPresent(TerminalKind.self, forKey: .terminal)) ?? .embedded
        defaultCommand = try c.decodeIfPresent(String.self, forKey: .defaultCommand) ?? "claude"
        sshConfigFile = try c.decodeIfPresent(String.self, forKey: .sshConfigFile)
        disableLocalTmux = try c.decodeIfPresent(Bool.self, forKey: .disableLocalTmux) ?? false
        workspaceRoots = try c.decodeIfPresent([String: String].self, forKey: .workspaceRoots) ?? [:]
        passMouseToApps = try c.decodeIfPresent(Bool.self, forKey: .passMouseToApps) ?? false
        notifyOnFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? true
        dockBadgeMode = (try? c.decodeIfPresent(DockBadgeMode.self, forKey: .dockBadgeMode)) ?? .needsInputAndFinished
        memWarnPct = try c.decodeIfPresent(Int.self, forKey: .memWarnPct) ?? 80
        memCritPct = try c.decodeIfPresent(Int.self, forKey: .memCritPct) ?? 90
        memAlerts = try c.decodeIfPresent(Bool.self, forKey: .memAlerts) ?? true
        autoSleepMinutes = try c.decodeIfPresent(Int.self, forKey: .autoSleepMinutes)
        wakeOnOpen = try c.decodeIfPresent(Bool.self, forKey: .wakeOnOpen) ?? true
        autoForward = try c.decodeIfPresent(Bool.self, forKey: .autoForward) ?? false
        setupDone = try c.decodeIfPresent(Bool.self, forKey: .setupDone)
        newSessionStart = try c.decodeIfPresent(String.self, forKey: .newSessionStart) ?? "claude"
        otherCommand = try c.decodeIfPresent(String.self, forKey: .otherCommand) ?? ""
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
    }
}

extension AppSettings {
    /// The command New Session runs for a start choice (nil = a plain login shell).
    public func startCommand(_ start: String) -> String? {
        switch start {
        case "claude", "codex": return start
        case "other":
            let c = otherCommand.trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        default: return nil
        }
    }

    /// Process names whose screens are read as another agent's (see StatusClassifier).
    public var otherAgentNames: [String] {
        var names = StatusClassifier.knownOtherAgents
        let words = otherCommand.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let exe = words.first(where: { $0 != "env" && !$0.contains("=") }),
           let base = exe.split(separator: "/").last.map(String.init),
           !["claude", "codex"].contains(base), !names.contains(base) { names.append(base) }
        return names
    }
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
    /// one host — the Mac or a remote host — and only holds that host's sessions.
    public var groups: [String: [String]] = [:]
    /// F10: grid tiles (session keys, in order) and which layout the main window shows.
    public var grid: [String] = []
    public var layout: PaneLayout = .single
    /// F8: forwarded ports per host, re-established after reconnects and restarts.
    public var forwards: [String: [PortForward]] = [:]

    public func groups(for host: String) -> [String] { groups[host] ?? [] }
    public func hasGroup(_ name: String, host: String) -> Bool { groups(for: host).contains(name) }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, hosts, sessions, recentDirs, settings, groups, openPanes, lastSelected, grid, layout, forwards
    }

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
        grid = try c.decodeIfPresent([String].self, forKey: .grid) ?? []
        layout = (try? c.decodeIfPresent(PaneLayout.self, forKey: .layout)) ?? .single
        forwards = (try? c.decodeIfPresent([String: [PortForward]].self, forKey: .forwards)) ?? [:]
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

    /// Folders Muxbar's own tests use; never offered as "recent" to the user.
    public static func isTestPath(_ dir: String) -> Bool {
        dir.contains("/muxbar-e2e") || dir.contains("/muxbar-unit") || dir.contains("muxbar-test-root")
    }

    /// Removes test folders from the recent lists (they leaked in from E2E runs). Returns count.
    @discardableResult
    public mutating func forgetTestDirs() -> Int {
        var n = 0
        for (h, dirs) in recentDirs {
            let kept = dirs.filter { !AppState.isTestPath($0) }
            n += dirs.count - kept.count
            recentDirs[h] = kept.isEmpty ? nil : kept
        }
        return n
    }

    public mutating func rememberDir(_ dir: String, host: String) {
        guard !AppState.isTestPath(dir) else { return }
        var dirs = recentDirs[host] ?? []
        dirs.removeAll { $0 == dir }
        dirs.insert(dir, at: 0)
        recentDirs[host] = Array(dirs.prefix(10))
    }
}

extension AppState {
    /// Nothing configured yet (a fresh install): no sessions, groups, remote hosts or roots.
    public var looksFresh: Bool {
        sessions.isEmpty && groups.isEmpty && hosts.allSatisfy { $0 == localHost } && settings.workspaceRoots.isEmpty
    }
}
