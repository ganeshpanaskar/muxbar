import Foundation

/// One `sh` script per host per tick (N2). It lists sessions and active panes and, in status mode,
/// captures each session's visible screen. Output lines are tagged with a per-probe nonce so pane
/// text can't be mistaken for structure.
public enum HostProbe {
    public enum Mode: Sendable { case discover, status }

    public static func script(mode: Mode, nonce: String, tmux: String = "tmux") -> String {
        let m = "@@\(nonce)"
        var s = """
        T=$(printf '\\t')
        command -v \(tmux) >/dev/null 2>&1 || { echo "\(m) NOTMUX"; exit 0; }
        echo "\(m) VER $(\(tmux) -V 2>/dev/null)"
        echo "\(m) NOW $(date +%s)"
        \(tmux) list-sessions -F '\(m) S~|~#{session_id}~|~#{session_created}~|~#{session_activity}~|~#{session_attached}~|~#{session_name}' 2>/dev/null
        \(tmux) list-panes -a -F '\(m) P~|~#{session_id}~|~#{window_active}~|~#{pane_active}~|~#{pane_current_command}~|~#{window_activity}~|~#{pane_current_path}' 2>/dev/null
        PSL=$(ps -A -o pid= -o ppid= -o comm= 2>/dev/null)
        \(tmux) list-panes -a -F '#{session_id} #{window_active}#{pane_active} #{pane_pid}' 2>/dev/null | while read sid act root; do
          [ "$act" = 11 ] || continue
          names=$(printf '%s\\n' "$PSL" | awk -v root="$root" '
            { p = $1; pp = $2; n = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", n); par[p] = pp; nm[p] = n }
            END { for (p in par) { q = p; d = 0
                    while (d < 64) { if (q == root) { print nm[p]; break }
                                     if (!(q in par)) break; q = par[q]; d++ } } }' | sort -u | tr '\\n' '\\037')
          echo "\(m) C${T}$sid${T}$names"
        done
        """
        if mode == .status {
            s += """

            for s in $(\(tmux) list-sessions -F '#{session_id}' 2>/dev/null); do
              echo "\(m) CAP $s"
              \(tmux) capture-pane -p -J -t "$s" 2>/dev/null
            done
            """
        }
        s += "\necho \"\(m) END\"\n"
        return s
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
        var captures: [String: [String]] = [:]
        var currentCap: String?
        var sawEnd = false

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
            } else if body.hasPrefix("S" + fieldSep) {
                let f = fields(body, 6)
                guard f.count == 6 else { continue }
                let s = ProbedSession(id: f[1], name: f[5], created: Int(f[2]) ?? 0,
                                      activity: Int(f[3]) ?? 0, attached: Int(f[4]) ?? 0)
                if sessions[s.id] == nil { order.append(s.id) }
                sessions[s.id] = s
            } else if body.hasPrefix("P" + fieldSep) {
                let f = fields(body, 7)
                guard f.count == 7, f[2] == "1", f[3] == "1", sessions[f[1]] != nil else { continue }
                sessions[f[1]]?.command = f[4]
                sessions[f[1]]?.windowActivity = Int(f[5])
                sessions[f[1]]?.path = f[6]
            } else if body.hasPrefix("C\t") {
                let f = body.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 3, sessions[f[1]] != nil else { continue }
                sessions[f[1]]?.processes = f[2].split(separator: "\u{1F}").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty && $0 != "<defunct>" }
            } else if body.hasPrefix("CAP ") {
                currentCap = String(body.dropFirst(4))
                captures[currentCap!] = []
            } else if body == "END" {
                sawEnd = true
            }
        }
        guard sawEnd else { throw ParseError.truncated }
        for (id, lines) in captures where sessions[id] != nil {
            sessions[id]?.capture = lastNonBlank(lines, count: captureLines)
        }
        return ProbeResult(tmuxVersion: version, tmuxMissing: false,
                           sessions: order.compactMap { sessions[$0] }, hostNow: now)
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
