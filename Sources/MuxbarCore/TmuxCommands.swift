import Foundation

/// POSIX single-quote a string so any shell treats it as one literal word.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Quote a path but keep a leading `~` meaningful (expanded to `$HOME` on the target host).
public func shellQuotePath(_ path: String) -> String {
    if path == "~" { return "\"$HOME\"" }
    if path.hasPrefix("~/") { return "\"$HOME\"/" + shellQuote(String(path.dropFirst(2))) }
    return shellQuote(path)
}

/// Names Muxbar creates are restricted to `[A-Za-z0-9_-]`; everything else becomes `-`.
public func sanitizeSessionName(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    var out = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).map { allowed.contains($0) ? $0 : "-" })
    while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return out.isEmpty ? "session" : String(out.prefix(60))
}

/// Parses `tmux -V` output ("tmux 3.2a", "tmux next-3.4", "tmux master") into (major, minor).
public func parseTmuxVersion(_ s: String) -> (Int, Int)? {
    guard let range = s.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
    let parts = s[range].split(separator: ".").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

public func tmuxVersionSupported(_ s: String) -> Bool {
    if s.contains("master") { return true }
    guard let (major, minor) = parseTmuxVersion(s) else { return false }
    return major > 2 || (major == 2 && minor >= 6)
}

/// Builders for the remote `sh` scripts Muxbar runs. Every target is a tmux `$id`
/// (exact, survives renames) — never a bare name, which tmux prefix-matches.
public enum TmuxCommands {
    /// Environment that stops Claude Code from overwriting the tab title (T2).
    public static let titleEnv = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1"

    /// Shell command the new pane runs. No command = just the user's login shell (they type what
    /// they want). With a command: run it, then a login shell so the session survives it exiting.
    public static func paneCommand(_ command: String?) -> String {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "env \(titleEnv) \"${SHELL:-/bin/sh}\" -l"
        }
        let inner = command + "; exec \"${SHELL:-/bin/sh}\" -l"
        return "env \(titleEnv) \"${SHELL:-/bin/sh}\" -lc " + shellQuote(inner)
    }

    /// Script that creates a detached session and prints its `$id` on stdout.
    public static func newSession(tmux: String = "tmux", name: String, dir: String, command: String?) -> String {
        let d = shellQuotePath(dir)
        return """
        D=\(d)
        [ -d "$D" ] || { echo "directory not found: $D" >&2; exit 3; }
        ID=$(\(tmux) new-session -d -P -F '#{session_id}' -s \(shellQuote(name)) -c "$D" \(shellQuote(paneCommand(command)))) || exit 4
        \(tmux) set-option -t "$ID" set-titles on >/dev/null 2>&1
        \(tmux) set-option -t "$ID" set-titles-string '#S' >/dev/null 2>&1
        echo "$ID"
        """
    }

    public static func rename(tmux: String = "tmux", id: String, newName: String) -> String {
        "\(tmux) rename-session -t \(shellQuote(id)) \(shellQuote(newName))"
    }

    public static func kill(tmux: String = "tmux", id: String) -> String {
        "\(tmux) kill-session -t \(shellQuote(id))"
    }

    /// Interactive attach, run by the user's terminal (not BatchMode, so auth prompts work).
    public static func attachRemote(host: String, id: String, sshConfigFile: String?) -> String {
        let remote = "tmux attach-session -t " + shellQuote(id)
        var ssh = "ssh"
        if let f = sshConfigFile { ssh += " -F " + shellQuote(f) }
        return "\(ssh) -t \(shellQuote(host)) \(shellQuote(remote))"
    }

    public static func attachLocal(tmux: String, id: String) -> String {
        "\(shellQuote(tmux)) attach-session -t \(shellQuote(id))"
    }
}
