import Foundation

// MARK: - Error classification

public enum SSHErrorKind: Equatable, Sendable {
    case authExpired
    case unreachable
    case other
}

/// Maps ssh stderr + exit status to a host health state. Order matters: auth beats network.
public func classifySSHFailure(stderr: String, exitCode: Int32, timedOut: Bool) -> SSHErrorKind {
    if timedOut { return .unreachable }
    let s = stderr.lowercased()
    let auth = ["permission denied", "authentication failed",
                "certificate", "too many authentication failures", "host key verification failed"]
    if auth.contains(where: s.contains) { return .authExpired }
    let net = ["could not resolve", "connection timed out", "timed out",
               "connection refused", "no route to host", "network is unreachable",
               "connection closed", "operation timed out",
               "name or service not known", "nodename nor servname"]
    if net.contains(where: s.contains) { return .unreachable }
    return exitCode == 255 ? .unreachable : .other
}

/// Strips ssh noise (OpenSSH post-quantum warnings, ANSI colours) for display.
public func cleanSSHStderr(_ stderr: String) -> String {
    let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
    let noAnsi = ansi.stringByReplacingMatches(in: stderr, range: NSRange(stderr.startIndex..., in: stderr),
                                               withTemplate: "")
    let skip = ["store now, decrypt later", "may need to be upgraded", "post-quantum", "openssh.com/pq",
                ]
    return noAnsi.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in !line.isEmpty && !skip.contains(where: line.lowercased().contains) }
        .joined(separator: "\n")
}

// MARK: - ~/.ssh/config (read-only)

/// Lists concrete `Host` aliases (no wildcards / negations), following `Include`.
public func parseSSHHosts(configPath: String, depth: Int = 0) -> [String] {
    guard depth < 5, let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
    var hosts: [String] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.isEmpty { continue }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
        guard let keyword = parts.first?.lowercased(), parts.count > 1 else { continue }
        if keyword == "host" {
            for h in parts.dropFirst() where !h.contains("*") && !h.contains("?") && !h.hasPrefix("!") {
                if !hosts.contains(h) { hosts.append(h) }
            }
        } else if keyword == "include" {
            for pattern in parts.dropFirst() {
                var p = (pattern as NSString).expandingTildeInPath
                if !p.hasPrefix("/") { p = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + p) }
                for file in globFiles(p) {
                    for h in parseSSHHosts(configPath: file, depth: depth + 1) where !hosts.contains(h) {
                        hosts.append(h)
                    }
                }
            }
        }
    }
    return hosts
}

private func globFiles(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
}

// MARK: - Paths

public enum MuxbarPaths {
    /// Test isolation: `MUXBAR_HOME` moves every Muxbar-owned local path (ControlMaster sockets,
    /// control socket, state, logs, install.conf) under one folder, so a test copy of the app never
    /// touches the user's running Muxbar. Keep it short: socket paths are limited to 104 bytes.
    public static var testHome: String? { TestEnv.value("MUXBAR_HOME") }
    static var muxbarDir: String { testHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".muxbar") }
    /// Short directory for ControlMaster sockets: macOS limits socket paths to 104 bytes.
    public static var controlDir: String { muxbarDir + "/cm" }
    public static var controlPath: String { controlDir + "/%C" }
    public static var ipcSocket: String { muxbarDir + "/ctl.sock" }
    public static var installConf: String { muxbarDir + "/install.conf" }
    public static var supportDir: String {
        testHome.map { $0 + "/support" }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Muxbar")
    }
    public static var stateFile: String { supportDir + "/state.json" }
    public static var logDir: String {
        testHome.map { $0 + "/logs" } ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Muxbar")
    }

    /// Longest socket path ssh will try to bind: dir + 40-char %C hash + ~17-char temp suffix.
    public static var worstCaseSocketPathLength: Int { controlDir.utf8.count + 1 + 40 + 17 }

    public static func ensureDirs() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: controlDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: (controlDir as NSString).deletingLastPathComponent)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDir)
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }
}

/// Test-only switches, read from the environment at launch. They're never stored in settings, so
/// the user's own Muxbar can't pick them up from a shared state file.
public enum TestEnv {
    public static func value(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }

    /// `MUXBAR_TMUX_SOCKET=name`: every tmux command runs as `tmux -L name`, a separate tmux server,
    /// so a test instance can't see or touch the user's sessions. Only `[A-Za-z0-9_-]` is accepted.
    public static var tmuxSocket: String? {
        guard let s = value("MUXBAR_TMUX_SOCKET"), s.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
        else { return nil }
        return s
    }

    /// `MUXBAR_TEST=1`: record notifications instead of posting them, and never activate the app
    /// (a test copy must not steal focus from whatever the user is doing).
    public static var isTest: Bool { value("MUXBAR_TEST") == "1" }
}

/// PATH for local commands: apps launched from Finder get a minimal PATH without Homebrew.
public let augmentedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

public func findLocalTmux() -> String? {
    for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return nil
}
