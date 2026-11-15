import Foundation

/// A TCP port listening on a remote host that a forward from this Mac can reach (F8).
public struct ListeningPort: Equatable, Sendable {
    public var port: Int
    /// As listed: 127.0.0.1, 0.0.0.0, ::, ::1 or *.
    public var address: String
    public var pid: Int?
    public var process: String?
    /// tmux pane of the owning process, when it runs under one.
    public var pane: String?

    public init(port: Int, address: String, pid: Int? = nil, process: String? = nil, pane: String? = nil) {
        self.port = port; self.address = address; self.pid = pid; self.process = process; self.pane = pane
    }

    /// Where the forward connects on the host: the loopback address the server listens on.
    public var target: String { address == "::1" ? "[::1]" : "127.0.0.1" }
}

public enum PortScan {
    /// Loopback and any-address listeners; a server bound to another interface isn't reachable
    /// through a forward to loopback.
    static let reachable: Set<String> = ["127.0.0.1", "0.0.0.0", "::", "::1", "*"]

    /// The probe's PORT section (Linux only; run before the process section, which turns `$LP`'s
    /// pids into `PO pid pane name` lines). `ss` when present, else `/proc/net/tcp{,6}` plus the
    /// socket inodes of your own processes.
    public static func scanSection(_ m: String) -> String {
        """
        LP=""
        if [ "$OS" = Linux ]; then
          if command -v ss >/dev/null 2>&1; then
            PSS=$(ss -ltnpH 2>/dev/null)
            LP=$(printf '%s\\n' "$PSS" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u | tr '\\n' ' ')
            printf '%s\\n' "$PSS" | sed '/^$/d; s/^/\(m) PSS~|~/'
          else
            PT=$(awk 'FNR > 1 && $4 == "0A" { print $2, $8, $10 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
            PF=$( { printf '%s\\n' "$PT" | sed 's/^/T /'
                    ls -l /proc/[0-9]*/fd 2>/dev/null | awk '/^\\/proc\\/[0-9]+\\/fd:$/ { split($0, a, "/"); pid = a[3]; next }
                      /socket:\\[/ { s = $NF; gsub(/[^0-9]/, "", s); print "F", pid, s }'; } |
                  awk '$1 == "T" { li[$4] = 1; next } $1 == "F" && ($3 in li) { print $2, $3 }')
            LP=$(printf '%s\\n' "$PF" | awk 'NF { print $1 }' | sort -u | tr '\\n' ' ')
            printf '%s\\n' "$PT" | awk -v u="$(id -u)" 'NF && $2 == u { print "\(m) PTCP~|~" $1 "~|~" $3 }'
            printf '%s\\n' "$PF" | awk 'NF { print "\(m) PFD~|~" $1 "~|~" $2 }'
          fi
        fi
        """
    }

    /// One `ss -ltnpH` line, if it's a listening socket of yours (others have no `users:` field).
    public static func parseSS(_ line: String) -> ListeningPort? {
        let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let usersTok = toks.first(where: { $0.hasPrefix("users:(") }),
              let local = toks.first(where: { $0.range(of: #"^(\[[0-9a-fA-F:.%a-z]*\]|[0-9.*:%a-zA-Z]*):\d+$"#, options: .regularExpression) != nil })
        else { return nil }
        guard let (addr, port) = splitHostPort(local) else { return nil }
        var name: String?, pid: Int?
        if let r = usersTok.range(of: #"\("([^"]*)",pid=(\d+)"#, options: .regularExpression) {
            let inner = String(usersTok[r])
            name = inner.split(separator: "\"").dropFirst().first.map(String.init)
            pid = inner.range(of: #"pid=(\d+)"#, options: .regularExpression).flatMap { Int(inner[$0].dropFirst(4)) }
        }
        return ListeningPort(port: port, address: addr, pid: pid, process: name)
    }

    /// `127.0.0.1:8080`, `[::1]:631`, `*:22`, `:::80`, `127.0.0.53%lo:53` → (address, port).
    static func splitHostPort(_ s: String) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        var a = String(s[..<colon])
        if a.hasPrefix("[") && a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a == "::ffff:127.0.0.1" { a = "127.0.0.1" }
        if a == "::" || a.isEmpty { a = "::" }
        return (a, port)
    }

    /// A `/proc/net/tcp{,6}` local address (`0100007F:1F90`) → (address, port).
    public static func parseProcAddress(_ hex: String) -> (String, Int)? {
        let parts = hex.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1], radix: 16) else { return nil }
        let h = parts[0].uppercased()
        if h.count == 8, let v = UInt32(h, radix: 16) {
            let b = [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24]
            return (b.map(String.init).joined(separator: "."), port)
        }
        guard h.count == 32 else { return nil }
        switch h {
        case String(repeating: "0", count: 32): return ("::", port)
        case String(repeating: "0", count: 24) + "01000000": return ("::1", port)
        case "0000000000000000FFFF00000100007F": return ("127.0.0.1", port)
        case "0000000000000000FFFF000000000000": return ("0.0.0.0", port)
        default: return ("v6", port)
        }
    }

    /// Reachable, yours, not ssh; one entry per port (an IPv4 listener wins over IPv6 for the same
    /// port, and a known owner over an unknown one).
    public static func merge(_ ports: [ListeningPort]) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        for p in ports where reachable.contains(p.address) && p.port != 22 {
            if let old = byPort[p.port] {
                let better = (old.pid == nil && p.pid != nil) || (old.address.contains(":") && !p.address.contains(":") && (p.pid != nil || old.pid == nil))
                if better { byPort[p.port] = ListeningPort(port: p.port, address: p.address, pid: p.pid ?? old.pid,
                                                           process: p.process ?? old.process, pane: p.pane ?? old.pane) }
            } else {
                byPort[p.port] = p
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// The Mac port for a remote one: the same number (10000 + port below 1024), else the next free.
    public static func localPort(for remote: Int, isFree: (Int) -> Bool) -> Int? {
        var p = remote < 1024 ? 10000 + remote : remote
        for _ in 0..<200 {
            guard p <= 65535 else { return nil }
            if isFree(p) { return p }
            p += 1
        }
        return nil
    }

    /// True if nothing listens on 127.0.0.1:`port`. Binds the way ssh does (SO_REUSEADDR): recent
    /// connections in TIME_WAIT (≈30 s after a curl) don't make a port busy, a listener does.
    public static func isFreeLocal(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    /// `ssh -O forward|cancel` arguments for a loopback-only forward through the existing master.
    public static func controlArguments(_ op: String, host: String, local: Int, target: String, remote: Int,
                                        sshConfigFile: String?) -> [String] {
        var a: [String] = []
        if let f = sshConfigFile { a += ["-F", f] }
        a += ["-o", "ControlPath=\(MuxbarPaths.controlPath)", "-O", op,
              "-L", "127.0.0.1:\(local):\(target):\(remote)", "--", host]
        return a
    }
}
