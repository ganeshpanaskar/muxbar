import Foundation

/// Putting an idle agent to sleep (F4): exit it to free memory, keep the tmux session and its
/// shell, and resume the same conversation later.
public enum SleepPolicy {
    public enum Reason: Equatable, Sendable, CustomStringConvertible {
        case noAgent
        case notIdle(SessionStatus)
        case noConversationID
        case typedInput
        case backgroundJob(String)
        case otherClientAttached
        case beingViewed
        case recentInput
        case neverSleep
        case idleTooShort(minutes: Int)
        case alreadySleeping

        public var description: String {
            switch self {
            case .noAgent: return "No agent is running in it"
            case .notIdle(let s): return "The agent is \(s.label.lowercased())"
            case .noConversationID: return "Muxbar doesn't know which conversation to resume (install the status hooks in Settings)"
            case .typedInput: return "You've typed text in the agent's prompt"
            case .backgroundJob(let what): return "A background job is running (\(what))"
            case .otherClientAttached: return "Another terminal is attached to it"
            case .beingViewed: return "It's on screen"
            case .recentInput: return "You typed in it since it finished"
            case .neverSleep: return "It's marked Never Sleep"
            case .idleTooShort(let m): return "Idle for less than \(m) min"
            case .alreadySleeping: return "It's already asleep"
            }
        }
    }

    public struct Inputs: Sendable {
        public var status: SessionStatus
        public var agent: AgentKind?
        public var agentPID: Int?
        public var conversationID: String?
        public var promptEmpty: Bool?            // nil = not checked
        public var descendants: [ProcessUsage]   // the agent's descendants
        public var attachedClients: Int          // tmux clients attached to the session
        public var muxbarClients: Int            // of which Muxbar's own pane(s)
        public var viewing: Bool
        public var inputSinceIdle: Bool
        public var neverSleep: Bool
        public var idleMinutes: Int?
        public var sleeping: Bool

        public init(status: SessionStatus, agent: AgentKind?, agentPID: Int?, conversationID: String?, promptEmpty: Bool?,
                    descendants: [ProcessUsage], attachedClients: Int, muxbarClients: Int, viewing: Bool,
                    inputSinceIdle: Bool, neverSleep: Bool, idleMinutes: Int?, sleeping: Bool) {
            self.status = status; self.agent = agent; self.agentPID = agentPID; self.conversationID = conversationID
            self.promptEmpty = promptEmpty; self.descendants = descendants; self.attachedClients = attachedClients
            self.muxbarClients = muxbarClients; self.viewing = viewing; self.inputSinceIdle = inputSinceIdle
            self.neverSleep = neverSleep; self.idleMinutes = idleMinutes; self.sleeping = sleeping
        }
    }

    /// Why the session can't sleep (empty = it can). `auto` adds the auto-sleep conditions: not on
    /// screen, no input since it finished, no other terminal attached, idle for `autoMinutes`.
    public static func check(_ i: Inputs, auto: Bool, autoMinutes: Int = 30) -> [Reason] {
        var r: [Reason] = []
        if i.sleeping { return [.alreadySleeping] }
        guard i.agent != nil, i.agentPID != nil else { return [.noAgent] }
        if i.status != .idle { r.append(.notIdle(i.status)) }
        if i.conversationID == nil { r.append(.noConversationID) }
        if i.promptEmpty == false { r.append(.typedInput) }
        if let job = backgroundJobs(i.descendants, agentPID: i.agentPID ?? 0).first {
            r.append(.backgroundJob(job.shortName))
        }
        if auto {
            if i.neverSleep { r.append(.neverSleep) }
            if i.viewing { r.append(.beingViewed) }
            if i.inputSinceIdle { r.append(.recentInput) }
            if i.attachedClients > i.muxbarClients { r.append(.otherClientAttached) }
            if (i.idleMinutes ?? 0) < autoMinutes { r.append(.idleTooShort(minutes: autoMinutes)) }
        }
        return r
    }

    /// What would die with the agent that you started: its tool commands. Agents run those in a
    /// shell (Claude: `/bin/zsh -c source ~/.claude/shell-snapshots/…`), while MCP servers and
    /// telemetry are started directly. So: any shell under the agent and everything beneath it —
    /// except zombies (exited, not reaped) and shell-launched MCP servers. The job itself (not its
    /// shell) comes first.
    public static func backgroundJobs(_ descendants: [ProcessUsage], agentPID: Int) -> [ProcessUsage] {
        let byPID = Dictionary(descendants.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func underShell(_ p: ProcessUsage) -> Bool {
            var cur: ProcessUsage? = p
            var hops = 0
            while let c = cur, c.pid != agentPID, hops < 64 {
                if c.isShell { return true }
                cur = c.ppid.flatMap { byPID[$0] }
                hops += 1
            }
            return false
        }
        let jobs = descendants.filter { d in
            !d.args.contains("<defunct>") && !d.args.lowercased().contains("mcp") && underShell(d)
        }
        return jobs.filter { !$0.isShell } + jobs.filter(\.isShell)
    }

    /// Helpers that exit with the agent (MCP servers, telemetry): not background jobs.
    public static func isHelper(_ args: String) -> Bool {
        let a = args.lowercased()
        return a.contains("mcp") || a.contains("otelcol")
    }

    /// The agent's prompt is empty: the input line is "❯"/"›" with nothing but spaces after it.
    /// nil if no input line is visible.
    public static func promptEmpty(_ lines: [String], agent: AgentKind) -> Bool? {
        let marks: [Character] = agent == .claude ? ["❯"] : ["›", "❯"]
        for raw in lines.reversed() {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard let first = l.first, marks.contains(first) else { continue }
            let rest = l.dropFirst().unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) && $0 != "\u{00A0}" }
            return rest.isEmpty
        }
        return nil
    }

    /// For a sleep decision about the agent process `agentPID` (any of its processes: wrapper
    /// installs run several nested `claude` processes; the topmost one counts): whether it's alive
    /// (`TOP`), its descendants (`D~|~pid~|~ppid~|~rssKB~|~args`), its exact argv (`A~|~arg\x1farg…`,
    /// from the innermost agent process, which has the real flags) and the pane's screen.
    public static func checkScript(nonce: String, agentPID: Int, tmux: String, pane: String) -> String {
        let m = "@@\(nonce)"
        return """
        P=\(agentPID)
        PSL=$(ps -A -o pid= -o ppid= -o rss= -o args= 2>/dev/null)
        TOP=$(printf '%s\\n' "$PSL" | awk -v p="$P" '
          function base(s,  n, a) { n = split(s, a, "/"); return a[n] }
          function agent(s,  w, b) { split(s, w, /[ \\t]+/); b = base(w[1]); return b == "claude" || b == "codex" || b ~ /^codex-/ || b ~ /^[0-9]+\\.[0-9]+(\\.[0-9]+)?$/ }
          { pp[$1] = $2; a = $0; sub(/^[ \\t]*[0-9]+[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]*/, "", a); ar[$1] = a }
          END { t = p; while ((pp[t] in ar) && agent(ar[pp[t]])) t = pp[t]; print t }')
        [ -n "$TOP" ] || TOP=$P
        echo "\(m) TOP~|~$TOP"
        kill -0 "$TOP" 2>/dev/null && echo "\(m) ALIVE" || echo "\(m) GONE"
        printf '%s\\n' "$PSL" | awk -v root="$TOP" -v m="\(m)" '
          { p = $1; par[p] = $2; rss[p] = $3; a = $0; sub(/^[ \\t]*[0-9]+[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]*/, "", a); args[p] = a }
          END { for (p in par) { if (p == root) continue; q = par[p]; d = 0
                  while (d < 64 && (q in par)) { if (q == root) { printf "%s D~|~%s~|~%s~|~%s~|~%s\\n", m, p, par[p], rss[p], substr(args[p], 1, 200); break }; q = par[q]; d++ } }
                printf "%s R~|~%s\\n", m, rss[root] }'
        if [ -r "/proc/$P/cmdline" ]; then printf '%s A~|~' "\(m)"; tr '\\0' '\\037' < "/proc/$P/cmdline"; echo
        else printf '%s B~|~%s\\n' "\(m)" "$(ps -o args= -p "$P" 2>/dev/null)"; fi
        echo "\(m) CAP"
        \(tmux) capture-pane -p -J -t \(shellQuote(pane)) 2>/dev/null | tail -n 40
        echo "\(m) END"
        """
    }

    public struct Check: Equatable, Sendable {
        /// The topmost agent process (what has to exit).
        public var topPID: Int?
        public var alive: Bool
        public var descendants: [ProcessUsage]
        public var agentRSSKB: Int
        public var argv: [String]
        public var screen: [String]
        /// Memory freed by exiting the agent (it and everything under it).
        public var freedKB: Int { agentRSSKB + descendants.reduce(0) { $0 + $1.rssKB } }
    }

    public static func parseCheck(_ out: String, nonce: String) -> Check {
        let m = "@@\(nonce) "
        var c = Check(topPID: nil, alive: false, descendants: [], agentRSSKB: 0, argv: [], screen: [])
        var inCap = false
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(m) {
                let body = line.dropFirst(m.count)
                inCap = false
                if body == "ALIVE" { c.alive = true }
                else if body.hasPrefix("TOP~|~") { c.topPID = Int(body.dropFirst(6)) }
                else if body.hasPrefix("D~|~") {
                    let f = HostProbe.fields(String(body.dropFirst(4)), 4)
                    if f.count == 4, let pid = Int(f[0]) {
                        c.descendants.append(ProcessUsage(pid: pid, rssKB: Int(f[2]) ?? 0, pane: nil, args: f[3], ppid: Int(f[1])))
                    }
                } else if body.hasPrefix("R~|~") { c.agentRSSKB = Int(body.dropFirst(4)) ?? 0 }
                else if body.hasPrefix("A~|~") {
                    c.argv = body.dropFirst(4).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
                } else if body.hasPrefix("B~|~") {
                    c.argv = body.dropFirst(4).split(separator: " ").map(String.init)
                } else if body == "CAP" { inCap = true }
                continue
            }
            if inCap { c.screen.append(line) }
        }
        c.screen = HostProbe.lastNonBlank(c.screen, count: 40)
        return c
    }
}
