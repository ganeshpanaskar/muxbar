import Foundation

/// A tab is safe to reuse for a reattach only when it's idle at a prompt or shows a finished
/// connection — never when some other program may be reading input (N1).
public func isSafeToReattach(lastLine: String) -> Bool {
    let l = lastLine.trimmingCharacters(in: .whitespaces)
    if l.isEmpty { return true }
    let finished = ["[Process completed]", "Connection to", "Connection closed", "[detached",
                    "[exited]", "[server exited]", "[lost server]", "client_loop: send disconnect",
                    "broken pipe"]
    if finished.contains(where: l.contains) { return true }
    guard let last = l.last else { return true }
    return "%$#>❯".contains(last)
}

/// True if `psOutput` (`ps -axo command=`) has a live attach client for this session.
/// Terminal's own `busy` flag can't be trusted (shell wrappers that rename the shell hide child
/// processes), so liveness is judged from the attach command Muxbar itself launched.
/// - Parameter socket: the `tmux -L` server the session lives on (nil = default server); clients
///   of another server with the same `$id` don't count.
public func hasLiveAttachClient(psOutput: String, host: String, tmuxID: String, socket: String? = nil) -> Bool {
    let id = NSRegularExpression.escapedPattern(for: tmuxID)
    let pattern = #"attach-session -t '?"# + id + #"'?(\s|$)"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let sockRE = try? NSRegularExpression(pattern: #"tmux'? -L '?([A-Za-z0-9_-]+)'?"#) else { return false }
    for raw in psOutput.split(separator: "\n") {
        let line = String(raw)
        guard re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
        let m = sockRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        let lineSocket = m.flatMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } }
        guard lineSocket == socket else { continue }
        let tokens = line.split(separator: " ").map(String.init)
        guard let first = tokens.first else { continue }
        let exe = (first as NSString).lastPathComponent
        if host == localHost {
            if exe == "tmux" { return true }
        } else if exe == "ssh" && tokens.contains(host) {
            return true
        }
    }
    return false
}
