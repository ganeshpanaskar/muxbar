import Foundation

/// Host memory monitoring (F3): levels, a trend that predicts running out, alerts with hysteresis,
/// and the on-demand "top processes" listing.
public struct MemorySample: Equatable, Sendable, Codable {
    public var t: Double          // seconds (any clock, consistently)
    public var availableKB: Int
    public init(t: Double, availableKB: Int) { self.t = t; self.availableKB = availableKB }
}

public enum MemoryLevel: String, Sendable { case normal, warn, critical }

public enum MemoryTrend {
    /// Seconds until available memory reaches zero if the recent decline continues (least-squares
    /// line over the last `window` seconds). nil unless there are ≥ `minSamples` samples, the drop
    /// over the window is at least `minDropKB` and the line points down.
    public static func secondsToExhaustion(_ samples: [MemorySample], now: Double, window: Double = 120,
                                           minSamples: Int = 3, minDropKB: Int = 1_048_576) -> Double? {
        let s = samples.filter { now - $0.t <= window }.sorted { $0.t < $1.t }
        guard s.count >= minSamples, let first = s.first, let last = s.last, last.t > first.t else { return nil }
        guard first.availableKB - last.availableKB >= minDropKB else { return nil }
        let n = Double(s.count)
        let mx = s.reduce(0) { $0 + $1.t } / n
        let my = s.reduce(0) { $0 + Double($1.availableKB) } / n
        var num = 0.0, den = 0.0
        for p in s { num += (p.t - mx) * (Double(p.availableKB) - my); den += (p.t - mx) * (p.t - mx) }
        guard den > 0 else { return nil }
        let slope = num / den              // KB per second
        guard slope < 0 else { return nil }
        let predictedNow = my + slope * (now - mx)
        return max(0, predictedNow / -slope)
    }
}

public struct MemoryAlerts: Equatable, Sendable {
    public enum Alert: Equatable, Sendable {
        case critical(usedPercent: Double)
        case runningOut(secondsLeft: Double)
    }

    public var critArmed = true
    public var trendArmed = true
    /// Warn when the trend says memory runs out within this many seconds.
    public static let trendHorizon: Double = 300

    public init() {}

    public static func level(usedPercent: Double, warn: Int, crit: Int) -> MemoryLevel {
        usedPercent >= Double(crit) ? .critical : (usedPercent >= Double(warn) ? .warn : .normal)
    }

    /// One sample's alerts. Each alert fires once, then re-arms only after things clearly improve
    /// (5 points below the critical line; trend no longer predicting exhaustion within 10 minutes).
    public mutating func step(usedPercent: Double, crit: Int, secondsToExhaustion: Double?) -> [Alert] {
        var out: [Alert] = []
        if usedPercent >= Double(crit) {
            if critArmed { critArmed = false; out.append(.critical(usedPercent: usedPercent)) }
        } else if usedPercent < Double(crit) - 5 {
            critArmed = true
        }
        if let s = secondsToExhaustion, s <= Self.trendHorizon {
            if trendArmed && critArmed && out.isEmpty { trendArmed = false; out.append(.runningOut(secondsLeft: s)) }
        } else if secondsToExhaustion == nil || secondsToExhaustion! > 2 * Self.trendHorizon {
            trendArmed = true
        }
        return out
    }
}

/// A process in the host's top-memory list, with the tmux pane it belongs to (if any).
public struct ProcessUsage: Equatable, Sendable {
    public var pid: Int
    public var rssKB: Int
    public var pane: String?
    public var args: String
    public var ppid: Int?

    public init(pid: Int, rssKB: Int, pane: String?, args: String, ppid: Int? = nil) {
        self.pid = pid; self.rssKB = rssKB; self.pane = pane; self.args = args; self.ppid = ppid
    }

    /// A shell (sh, bash, zsh, …): agents run their tool commands in one.
    public var isShell: Bool {
        let first = args.split(separator: " ").first.map(String.init) ?? ""
        let prog = (first as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh"].contains(prog)
    }

    /// Short name for lists: the program (and script, for interpreters) without paths.
    public var shortName: String {
        let words = args.split(separator: " ").map(String.init)
        guard let first = words.first else { return "?" }
        let prog = (first as NSString).lastPathComponent
        // `zsh -c <command line>`: the shell's name says enough.
        if isShell && words.contains("-c") { return prog.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if prog.range(of: #"^(python[0-9.]*|node|bun|ruby|perl|java|sh|bash|zsh)$"#, options: .regularExpression) != nil,
           let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return prog + " " + (script as NSString).lastPathComponent
        }
        return prog
    }
}

public enum MemoryDetail {
    /// Top `limit` processes by memory, each with its pane (process tree; on Linux also the
    /// `TMUX`/`TMUX_PANE` environment of processes that left the tree). Lines:
    /// `T~|~pid~|~rssKB~|~pane~|~args`.
    public static func script(nonce: String, tmux: String = "tmux", socket: String? = nil, limit: Int = 12) -> String {
        let m = "@@\(nonce)"
        return """
        tm() { \(TmuxCommands.invocation(tmux, socket: socket)) "$@"; }
        SP=$(tm display-message -p '#{socket_path}' 2>/dev/null)
        OUT=$( { tm list-panes -a -F 'PANE #{pane_id} #{pane_pid}' 2>/dev/null
                 ps -A -o pid= -o ppid= -o rss= -o args= 2>/dev/null | sed 's/^/PS /'; } | awk -v lim=\(limit) '
          $1 == "PANE" { root[$3] = $2; next }
          $1 == "PS" { p = $2; par[p] = $3; rss[p] = $4; a = $0; sub(/^PS[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]+[0-9]+[ \\t]*/, "", a); args[p] = a; next }
          END {
            n = 0; for (p in par) cand[++n] = p
            for (i = 1; i <= n && i <= lim; i++) { b = i
              for (j = i + 1; j <= n; j++) if (rss[cand[j]] + 0 > rss[cand[b]] + 0) b = j
              t = cand[i]; cand[i] = cand[b]; cand[b] = t
              p = cand[i]; q = p; d = 0; own = ""
              while (d < 64) { if (q in root) { own = root[q]; break }; if (!(q in par)) break; q = par[q]; d++ }
              printf "TOP %s %s %s %s\\n", p, rss[p], (own == "" ? "-" : own), substr(args[p], 1, 200)
            }
          }')
        printf '%s\\n' "$OUT" | while read -r tag pid rss pane rest; do
          [ "$tag" = TOP ] || continue
          if [ "$pane" = - ] && [ -r "/proc/$pid/environ" ] && [ -n "$SP" ]; then
            E=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null)
            S=$(printf '%s\\n' "$E" | sed -n 's/^TMUX=\\([^,]*\\),.*/\\1/p'); P=$(printf '%s\\n' "$E" | sed -n 's/^TMUX_PANE=//p')
            [ "$S" = "$SP" ] && [ -n "$P" ] && pane=$P
          fi
          echo "\(m) T~|~$pid~|~$rss~|~$pane~|~$rest"
        done
        echo "\(m) END"
        """
    }

    public static func parse(_ out: String, nonce: String) -> [ProcessUsage] {
        let m = "@@\(nonce) T" + HostProbe.fieldSep
        return out.split(separator: "\n").compactMap { raw in
            guard raw.hasPrefix(m) else { return nil }
            let f = HostProbe.fields(String(raw.dropFirst(m.count)), 4)
            guard f.count == 4, let pid = Int(f[0]), let rss = Int(f[1]) else { return nil }
            return ProcessUsage(pid: pid, rssKB: rss, pane: f[2] == "-" ? nil : f[2], args: f[3])
        }
    }
}

/// "24.1 GB", "830 MB".
public func formatKB(_ kb: Int) -> String {
    let gb = Double(kb) / 1_048_576
    if gb >= 10 { return String(format: "%.0f GB", gb) }
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return "\(max(0, kb / 1024)) MB"
}
