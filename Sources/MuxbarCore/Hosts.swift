import Foundation

/// Remote host addresses typed by the user (first-launch setup, Settings, CLI).
public enum HostAddress {
    public struct Invalid: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `[user@]host` or a `~/.ssh/config` alias, made of letters, digits, `.`, `_` and `-`. A pasted
    /// `ssh host` is accepted. Anything else is refused: the address becomes an ssh argument, so
    /// `-oProxyCommand=…` would run a command on this Mac.
    public static func normalize(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("ssh ") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty else { throw Invalid(message: "Enter a host name") }
        guard s.count <= 253 else { throw Invalid(message: "That's too long for a host name") }
        guard s.lowercased() != localHost else { throw Invalid(message: "\"local\" is this Mac, which is always listed") }
        let part = "[A-Za-z0-9_][A-Za-z0-9._-]*"
        guard s.range(of: "^(\(part)@)?\(part)$", options: .regularExpression) != nil else {
            throw Invalid(message: "Use just a host name, user@host or a ~/.ssh/config alias (letters, digits, . _ -), with no options")
        }
        return s
    }
}

/// "Can Muxbar use this host?": one ssh round trip, then a plain-words answer.
public enum HostCheck {
    public enum Result: Equatable, Sendable {
        case ok(os: String, tmux: String)
        case noTmux(os: String)
        case auth
        case hostKey
        case dns
        case unreachable
        case refused
        case other(String)

        public var ok: Bool { if case .ok = self { return true }; return false }

        public var kind: String {
            switch self {
            case .ok: return "ok"
            case .noTmux: return "noTmux"
            case .auth: return "auth"
            case .hostKey: return "hostKey"
            case .dns: return "dns"
            case .unreachable: return "unreachable"
            case .refused: return "refused"
            case .other: return "other"
            }
        }

        public func message(host: String) -> String {
            switch self {
            case .ok(let os, let tmux): return "Connected · \(os) · \(tmux)"
            case .noTmux(let os): return "Connected (\(os)), but tmux isn't installed there — install it, e.g. sudo apt install tmux or sudo dnf install tmux"
            case .auth: return "Can't sign in — check your SSH key or credentials (try ssh \(host) in Terminal), then check again"
            case .hostKey: return "Its host key isn't accepted yet — run ssh \(host) once in Terminal and answer yes"
            case .dns: return "Host not found — check the address"
            case .unreachable: return "No answer — is the host running and reachable (VPN)?"
            case .refused: return "Connection refused — SSH isn't answering on that host"
            case .other(let s): return "Couldn't connect: \(s)"
            }
        }
    }

    /// Runs on the host: its OS and tmux, found the way the status probe finds it.
    public static let script = """
        echo "MBX_CHECK os=$(uname -s 2>/dev/null)"
        if command -v tmux >/dev/null 2>&1; then echo "MBX_CHECK tmux=$(tmux -V 2>/dev/null)"; else echo "MBX_CHECK tmux="; fi
        """

    public static func parse(_ r: RunResult) -> Result {
        let lines = r.stdout.split(separator: "\n").map(String.init)
        func value(_ key: String) -> String? {
            lines.last { $0.hasPrefix("MBX_CHECK \(key)=") }.map { String($0.dropFirst("MBX_CHECK \(key)=".count)) }
        }
        if !r.timedOut, let os = value("os") {
            let tmux = value("tmux") ?? ""
            return tmux.isEmpty ? .noTmux(os: os.isEmpty ? "?" : os) : .ok(os: os.isEmpty ? "?" : os, tmux: tmux)
        }
        if r.timedOut { return .unreachable }
        let s = r.stderr.lowercased()
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") { return .hostKey }
        if ["could not resolve hostname", "nodename nor servname", "name or service not known"].contains(where: s.contains) { return .dns }
        if ["permission denied", "authentication failed", "certificate"].contains(where: s.contains) { return .auth }
        if s.contains("connection refused") { return .refused }
        if ["timed out", "no route to host", "network is unreachable", "connection closed"].contains(where: s.contains) {
            return .unreachable
        }
        let first = cleanSSHStderr(r.stderr).split(separator: "\n").first.map(String.init) ?? "exit \(r.exitCode)"
        return .other(String(first.prefix(160)))
    }
}
