import Foundation

/// One `sh` script per host per tick (N2). It lists sessions, panes and agent processes, the
/// agents' hook states, host memory and, in status mode, each session's visible screen. Output lines
/// are tagged with a per-probe nonce so pane text can't be mistaken for structure. The process walk
/// runs on the host (awk), so only a short summary per pane comes back.
public enum HostProbe {
    public enum Mode: Sendable {
        case discover
        case status
        /// Host memory only (fast polling while a host is under memory pressure, F3).
        case memory
    }

    /// Default folder of the agents' hook state files on every host.
    public static let defaultHookDir = "\"$HOME/.muxbar/state\""

    /// - Parameters:
    ///   - socket: `tmux -L` server name (test instances); nil = the default server.
    ///   - hookDir: shell expression for the hook state folder on the host.
    public static func script(mode: Mode, nonce: String, tmux: String = "tmux", socket: String? = nil,
                              hookDir: String = defaultHookDir) -> String {
        let m = "@@\(nonce)"
        if mode == .memory { return memorySection(m) + "\necho \"\(m) END\"\n" }
        var s = """
        T=$(printf '\\t')
        command -v \(tmux) >/dev/null 2>&1 || { echo "\(m) NOTMUX"; exit 0; }
        tm() { \(TmuxCommands.invocation(tmux, socket: socket)) "$@"; }
        OS=$(uname -s)
        echo "\(m) VER $(tm -V 2>/dev/null)"
        echo "\(m) NOW $(date +%s)"
        tm list-sessions -F '\(m) S~|~#{session_id}~|~#{session_created}~|~#{session_activity}~|~#{session_attached}~|~#{session_name}' 2>/dev/null
        tm list-panes -a -F '\(m) P~|~#{session_id}~|~#{window_active}~|~#{pane_active}~|~#{pane_current_command}~|~#{window_activity}~|~#{pane_id}~|~#{pane_pid}~|~#{pane_current_path}' 2>/dev/null
        SP=$(tm display-message -p '#{socket_path}' 2>/dev/null)
        SH=${SP##*/}
        echo "\(m) SOCK $SH"
        \(PortScan.scanSection(m))
        [ "$OS" = Linux ] && echo "\(m) PORTS"
        \(processSection(m))
        \(hookSection(m, hookDir: hookDir))
        \(DropNaming.cleanupScript)
        \(memorySection(m))
        """
        if mode == .status {
            s += """

            for s in $(tm list-sessions -F '#{session_id}' 2>/dev/null); do
              echo "\(m) CAP $s"
              tm capture-pane -p -J -t "$s" 2>/dev/null
            done
            """
        }
        s += "\necho \"\(m) END\"\n"
        return s
    }

    /// One `ps` for everything; awk walks each process up to its tmux pane and prints, per pane,
    /// total memory, process count and names (C2), plus every agent process (AG). On Linux, large
    /// processes that left the tree (re-parented after `nohup … &`) are matched to a pane by the
    /// `TMUX`/`TMUX_PANE` in their environment (XA).
    /// For interpreters (`node …/bin/gemini`) the script's name is listed too, so other agent CLIs
    /// are recognised by name.
    static func processSection(_ m: String) -> String {
        """
        if [ "$OS" = Linux ]; then ET=etimes; else ET=etime; fi
        PW=$( { tm list-panes -a -F 'PANE #{pane_id} #{session_id} #{pane_pid}' 2>/dev/null
                ps -A -o pid= -o ppid= -o rss= -o $ET= -o args= 2>/dev/null | sed 's/^/PS /'; } | awk -v m="\(m)" -v lp="${LP:-}" '
          function base(s,  n, a) { n = split(s, a, "/"); return a[n] }
          function kind(a0, args,   b, n, t, b2) {
            b = base(a0)
            if (b == "claude" || b ~ /^[0-9]+\\.[0-9]+(\\.[0-9]+)?$/) return "claude"
            if (b == "codex" || b ~ /^codex-/) return "codex"
            if (b == "node" || b == "bun") {
              if (args ~ /\\/claude([ \\t]|$)|claude-code\\/cli/) return "claude"
              if (args ~ /\\/codex([ .\\t]|$)|@openai\\/codex/) return "codex"
            }
            if (b ~ /^(python[0-9.]*|sh|bash|zsh|perl|ruby)$/) {
              n = split(args, t, /[ \\t]+/)
              if (n >= 2) { b2 = base(t[2]); if (b2 == "claude") return "claude"; if (b2 == "codex") return "codex" }
            }
            return ""
          }
          $1 == "PANE" { root[$4] = $2; sess[$2] = $3; next }
          $1 == "PS" { p = $2; par[p] = $3; rss[p] = $4; et[p] = $5; a = $0
                       sub(/^PS[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]+[^ \\t]+[ \\t]*/, "", a); args[p] = a; next }
          END {
            for (p in par) { q = p; d = 0
              while (d < 64) { if (q in root) { own[p] = root[q]; break }; if (!(q in par)) break; q = par[q]; d++ } }
            for (p in own) { pn = own[p]; tot[pn] += rss[p]; cnt[pn]++
              split(args[p], w, /[ \\t]+/); k = kind(w[1], args[p])
              names[pn] = names[pn] (k != "" ? k : base(w[1])) "\\037"
              if (k == "" && tolower(base(w[1])) ~ /^(node|bun|deno|python[0-9.]*|sh|bash|zsh|perl|ruby)$/ && w[2] != "" && w[2] !~ /^-/)
                names[pn] = names[pn] base(w[2]) "\\037"
              if (k != "") printf "%s AG~|~%s~|~%s~|~%s~|~%s~|~%s~|~%s\\n", m, pn, p, k, et[p], rss[p], substr(args[p], 1, 300)
            }
            for (pn in sess) printf "%s C2~|~%s~|~%s~|~%d~|~%d~|~%s\\n", m, pn, sess[pn], tot[pn], cnt[pn], names[pn]
            nl = split(lp, L, " ")
            for (i = 1; i <= nl; i++) { p = L[i]; if (!(p in par)) continue; split(args[p], w, /[ \\t]+/)
              printf "%s PO~|~%s~|~%s~|~%s\\n", m, p, (p in own ? own[p] : "-"), base(w[1]) }
            n = 0
            for (p in par) if (!(p in own) && rss[p] > 51200) { cand[++n] = p }
            for (i = 1; i <= n && i <= 30; i++) { best = i
              for (j = i + 1; j <= n; j++) if (rss[cand[j]] > rss[cand[best]]) best = j
              t = cand[i]; cand[i] = cand[best]; cand[best] = t
              printf "CAND %s %s\\n", cand[i], rss[cand[i]] }
          }')
        printf '%s\\n' "$PW" | grep -v '^CAND ' | grep -v '^$'
        if [ "$OS" = Linux ] && [ -n "$SP" ]; then
          CF=$(printf '%s\\n' "$PW" | sed -n 's/^CAND \\([0-9]*\\) .*/\\/proc\\/\\1\\/environ/p' | tr '\\n' ' ')
          if [ -n "$CF" ]; then
            grep -a -z -H -E '^TMUX(_PANE)?=' $CF 2>/dev/null | tr '\\0' '\\n' | awk -v sp="$SP" -v m="\(m)" -F: '
              { f = $1; v = substr($0, length(f) + 2); split(f, q, "/"); pid = q[3]
                if (v ~ /^TMUX=/) { s = substr(v, 6); sub(/,.*/, "", s); srv[pid] = s }
                else if (v ~ /^TMUX_PANE=/) { pane[pid] = substr(v, 11) } }
              END { for (p in pane) if (srv[p] == sp) printf "%s XA~|~%s~|~%s\\n", m, pane[p], p }'
            printf '%s\\n' "$PW" | sed -n 's/^CAND \\([0-9]*\\) \\([0-9]*\\)$/\(m) XR~|~\\1~|~\\2/p'
          fi
        fi
        """
    }

    /// Hook state files of this tmux server (`<socket name>@<pane>.json`, one JSON line each). Files of
    /// panes that no longer exist, and anything older than 7 days, are removed — only inside the
    /// state folder.
    static func hookSection(_ m: String, hookDir: String) -> String {
        """
        HD=\(hookDir)
        if [ -d "$HD" ] && [ -n "$SH" ]; then
          PIDS=" $(tm list-panes -a -F '#{pane_id}' 2>/dev/null | tr -d '%' | tr '\\n' ' ') "
          for f in "$HD/$SH"@*.json; do
            [ -f "$f" ] || continue
            n=${f##*@}; n=${n%.json}
            case "$PIDS" in *" $n "*) printf '%s H~|~%s\\n' "\(m)" "$(head -c 4096 "$f" | tr -d '\\n')" ;; *) rm -f "$f" ;; esac
          done
          find "$HD" -name '*.json' -mtime +7 -exec rm -f {} + 2>/dev/null
        fi
        """
    }

    /// `MEM~|~os~|~totalKB~|~availableKB~|~swapTotalKB~|~swapFreeKB~|~load1 load5 load15~|~cpus`.
    static func memorySection(_ m: String) -> String {
        """
        if [ -r /proc/meminfo ]; then
          # One process: execs are slow on remote hosts (security agents), and this runs every 5 s
          # under memory pressure.
          awk -v m="\(m)" '
            FILENAME == "/proc/meminfo" { if ($1 == "MemTotal:") t = $2; else if ($1 == "MemAvailable:") a = $2
                                          else if ($1 == "SwapTotal:") st = $2; else if ($1 == "SwapFree:") sf = $2; next }
            FILENAME == "/proc/loadavg" { la = $1 " " $2 " " $3; next }
            $1 == "processor" { nc++ }
            END { printf "%s MEM~|~Linux~|~%d~|~%d~|~%d~|~%d~|~%s~|~%d\\n", m, t, a, st, sf, la, nc }' /proc/meminfo /proc/loadavg /proc/cpuinfo 2>/dev/null
        else
          TB=$(sysctl -n hw.memsize 2>/dev/null); NC=$(sysctl -n hw.ncpu 2>/dev/null)
          LA=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1, $2, $3}')
          SW=$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub(/M/, ""); print int($3 * 1024) "~|~" int($9 * 1024)}')
          MI=$(vm_stat 2>/dev/null | awk -v tb="$TB" '
            NR == 1 { if (match($0, /page size of [0-9]+/)) ps = substr($0, RSTART + 13, RLENGTH - 13) }
            /^Pages free:/ { f = $3 } /^Pages inactive:/ { i = $3 } /^Pages speculative:/ { s = $3 } /^Pages purgeable:/ { p = $3 }
            END { gsub(/\\./, "", f); gsub(/\\./, "", i); gsub(/\\./, "", s); gsub(/\\./, "", p)
                  printf "%d~|~%d", tb / 1024, (f + i + s + p) * ps / 1024 }')
          echo "\(m) MEM~|~Darwin~|~$MI~|~${SW:-0~|~0}~|~$LA~|~$NC"
        fi
        """
    }

    public static func makeNonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// Field separator inside tmux `-F` output. tmux replaces control characters (e.g. tab) with
    /// `_` when the remote locale isn't UTF-8 — as in non-interactive ssh to many Linux hosts — so it's ASCII.
    public static let fieldSep = "~|~"

    public enum ParseError: Error, Equatable { case truncated }

    /// Parses probe output. Session names are the last field, so names containing tabs survive.
    public static func parse(_ output: String, nonce: String, captureLines: Int = 60) throws -> ProbeResult {
        let m = "@@\(nonce) "
        var version: String?
        var now: Int?
        var sessions: [String: ProbedSession] = [:]
        var order: [String] = []
        var panes: [String: ProbedPane] = [:]
        var paneOrder: [String] = []
        var captures: [String: [String]] = [:]
        var currentCap: String?
        var sawEnd = false
        var memory: HostMemory?
        var serverHash: String?
        var escaped: [String: (pane: String, rss: Int?)] = [:]   // pid → pane (XA) / rss (XR)
        var scannedPorts = false
        var rawPorts: [ListeningPort] = []
        var procTCP: [(addr: String, port: Int, inode: String)] = []
        var inodePID: [String: Int] = [:]
        var portOwner: [Int: (pane: String?, name: String)] = [:]   // pid → pane, process name

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.hasPrefix(m) else {
                if let c = currentCap { captures[c, default: []].append(line) }
                continue
            }
            let body = String(line.dropFirst(m.count))
            currentCap = nil
            if body == "NOTMUX" {
                return ProbeResult(tmuxVersion: nil, tmuxMissing: true, sessions: [], hostNow: now)
            } else if body.hasPrefix("VER ") {
                version = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("NOW ") {
                now = Int(body.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if body.hasPrefix("SOCK ") {
                serverHash = String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("S" + fieldSep) {
                let f = fields(body, 6)
                guard f.count == 6 else { continue }
                let s = ProbedSession(id: f[1], name: f[5], created: Int(f[2]) ?? 0,
                                      activity: Int(f[3]) ?? 0, attached: Int(f[4]) ?? 0)
                if sessions[s.id] == nil { order.append(s.id) }
                sessions[s.id] = s
            } else if body.hasPrefix("P" + fieldSep) {
                let f = fields(body, 9)
                guard f.count == 9, sessions[f[1]] != nil else { continue }
                let active = f[2] == "1" && f[3] == "1"
                var p = panes[f[6]] ?? ProbedPane(id: f[6], sessionID: f[1])
                p.active = active
                p.command = f[4]
                p.windowActivity = Int(f[5])
                p.pid = Int(f[7])
                p.path = f[8]
                if panes[f[6]] == nil { paneOrder.append(f[6]) }
                panes[f[6]] = p
                sessions[f[1]]?.paneIDs.append(f[6])
                if active {
                    sessions[f[1]]?.command = f[4]
                    sessions[f[1]]?.windowActivity = Int(f[5])
                    sessions[f[1]]?.path = f[8]
                    sessions[f[1]]?.activePane = f[6]
                }
            } else if body.hasPrefix("C2" + fieldSep) {
                let f = fields(body, 6)
                guard f.count == 6 else { continue }
                var p = panes[f[1]] ?? ProbedPane(id: f[1], sessionID: f[2])
                p.memoryKB = Int(f[3]) ?? 0
                p.processCount = Int(f[4]) ?? 0
                p.processes = f[5].split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != "<defunct>" }
                if panes[f[1]] == nil { paneOrder.append(f[1]) }
                panes[f[1]] = p
            } else if body.hasPrefix("AG" + fieldSep) {
                let f = fields(body, 7)
                guard f.count == 7, let pid = Int(f[2]), let kind = AgentKind(rawValue: f[3]) else { continue }
                let a = AgentProcess(kind: kind, pid: pid, ageSeconds: parseElapsed(f[4]), rssKB: Int(f[5]) ?? 0, args: f[6])
                panes[f[1], default: ProbedPane(id: f[1], sessionID: "")].agents.append(a)
            } else if body.hasPrefix("XA" + fieldSep) {
                let f = fields(body, 3)
                guard f.count == 3 else { continue }
                escaped[f[2], default: (f[1], nil)].pane = f[1]
            } else if body.hasPrefix("XR" + fieldSep) {
                let f = fields(body, 3)
                guard f.count == 3 else { continue }
                escaped[f[1], default: ("", nil)].rss = Int(f[2])
            } else if body.hasPrefix("H" + fieldSep) {
                if let h = HookState.parse(String(body.dropFirst(1 + fieldSep.count))) {
                    panes[h.pane, default: ProbedPane(id: h.pane, sessionID: "")].hook = h
                }
            } else if body == "PORTS" {
                scannedPorts = true
            } else if body.hasPrefix("PSS" + fieldSep) {
                if let p = PortScan.parseSS(String(body.dropFirst(3 + fieldSep.count))) { rawPorts.append(p) }
            } else if body.hasPrefix("PTCP" + fieldSep) {
                let f = fields(body, 3)
                if f.count == 3, let (a, port) = PortScan.parseProcAddress(f[1]) { procTCP.append((a, port, f[2])) }
            } else if body.hasPrefix("PFD" + fieldSep) {
                let f = fields(body, 3)
                if f.count == 3, let pid = Int(f[1]) { inodePID[f[2]] = pid }
            } else if body.hasPrefix("PO" + fieldSep) {
                let f = fields(body, 4)
                if f.count == 4, let pid = Int(f[1]) { portOwner[pid] = (f[2] == "-" ? nil : f[2], f[3]) }
            } else if body.hasPrefix("MEM" + fieldSep) {
                memory = HostMemory.parse(String(body.dropFirst(3 + fieldSep.count)))
            } else if body.hasPrefix("CAP ") {
                currentCap = String(body.dropFirst(4))
                captures[currentCap!] = []
            } else if body == "END" {
                sawEnd = true
            }
        }
        guard sawEnd else { throw ParseError.truncated }
        for (_, e) in escaped where !e.pane.isEmpty {
            guard let rss = e.rss, panes[e.pane] != nil else { continue }
            panes[e.pane]?.memoryKB += rss
            panes[e.pane]?.escapedKB += rss
        }
        var ports: [ListeningPort]?
        if scannedPorts {
            // /proc fallback: only sockets owned by a process of yours count (like ss's users:).
            for t in procTCP { if let pid = inodePID[t.inode] { rawPorts.append(ListeningPort(port: t.port, address: t.addr, pid: pid)) } }
            ports = PortScan.merge(rawPorts.map { p in
                var q = p
                if let pid = p.pid, let o = portOwner[pid] {
                    q.pane = o.pane
                    if q.process == nil { q.process = o.name }
                }
                // A pane this probe doesn't know isn't ours (another tmux server).
                if let pn = q.pane, panes[pn] == nil { q.pane = nil }
                return q
            })
        }
        for (id, lines) in captures where sessions[id] != nil {
            sessions[id]?.capture = lastNonBlank(lines, count: captureLines)
        }
        // Session-level summaries from their panes.
        for id in order {
            guard var s = sessions[id] else { continue }
            let mine = s.paneIDs.compactMap { panes[$0] }
            if !mine.isEmpty || panes.values.contains(where: { $0.sessionID == id }) {
                s.memoryKB = mine.reduce(0) { $0 + $1.memoryKB }
                if let ap = s.activePane, let p = panes[ap], !p.processes.isEmpty || p.processCount > 0 {
                    s.processes = p.processes
                } else if let ap = s.activePane, panes[ap] != nil {
                    s.processes = []
                }
            }
            sessions[id] = s
        }
        return ProbeResult(tmuxVersion: version, tmuxMissing: false,
                           sessions: order.compactMap { sessions[$0] }, hostNow: now,
                           panes: paneOrder.compactMap { panes[$0] }.filter { !$0.sessionID.isEmpty },
                           memory: memory, serverHash: serverHash, ports: ports)
    }

    /// Splits on `fieldSep` into at most `count` fields; the last field keeps any separators.
    static func fields(_ s: String, _ count: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while out.count < count - 1, let r = rest.range(of: fieldSep) {
            out.append(String(rest[..<r.lowerBound]))
            rest = rest[r.upperBound...]
        }
        out.append(String(rest))
        return out
    }

    /// Drops trailing blank lines, then keeps the last `count` lines.
    public static func lastNonBlank(_ lines: [String], count: Int) -> [String] {
        var l = lines
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        return Array(l.suffix(count))
    }
}

/// One tmux pane on a host, as the probe saw it.
public struct ProbedPane: Equatable, Sendable {
    public var id: String              // "%12"
    public var sessionID: String       // "$3"
    public var active = false          // active pane of the active window
    public var pid: Int?
    public var command: String?
    public var path: String?
    public var windowActivity: Int?
    /// Memory (RSS, KB) of the pane's process tree, plus processes that left it (Linux).
    public var memoryKB = 0
    public var escapedKB = 0
    public var processCount = 0
    public var processes: [String] = []
    public var agents: [AgentProcess] = []
    public var hook: HookState?

    public init(id: String, sessionID: String) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// An agent process (claude/codex) in a pane's tree.
public struct AgentProcess: Equatable, Sendable {
    public var kind: AgentKind
    public var pid: Int
    public var ageSeconds: Int?
    public var rssKB: Int
    public var args: String

    public init(kind: AgentKind, pid: Int, ageSeconds: Int?, rssKB: Int, args: String) {
        self.kind = kind; self.pid = pid; self.ageSeconds = ageSeconds; self.rssKB = rssKB; self.args = args
    }
}

/// Host memory and load (F3).
public struct HostMemory: Equatable, Sendable, Codable {
    public var os: String
    public var totalKB: Int
    public var availableKB: Int
    public var swapTotalKB: Int
    public var swapFreeKB: Int
    public var load: [Double]
    public var cpus: Int

    public init(os: String, totalKB: Int, availableKB: Int, swapTotalKB: Int = 0, swapFreeKB: Int = 0,
                load: [Double] = [], cpus: Int = 0) {
        self.os = os; self.totalKB = totalKB; self.availableKB = availableKB
        self.swapTotalKB = swapTotalKB; self.swapFreeKB = swapFreeKB; self.load = load; self.cpus = cpus
    }

    public var usedKB: Int { max(0, totalKB - availableKB) }
    /// 0…100.
    public var usedPercent: Double { totalKB > 0 ? Double(usedKB) * 100 / Double(totalKB) : 0 }

    /// `os~|~total~|~avail~|~swapTotal~|~swapFree~|~load1 load5 load15~|~cpus`
    public static func parse(_ s: String) -> HostMemory? {
        let f = HostProbe.fields(s, 7)
        guard f.count == 7, let total = Int(f[1]), let avail = Int(f[2]), total > 0 else { return nil }
        let load = f[5].split(separator: " ").compactMap { Double($0) }
        return HostMemory(os: f[0], totalKB: total, availableKB: min(avail, total), swapTotalKB: Int(f[3]) ?? 0,
                          swapFreeKB: Int(f[4]) ?? 0, load: load, cpus: Int(f[6].trimmingCharacters(in: .whitespaces)) ?? 0)
    }
}
