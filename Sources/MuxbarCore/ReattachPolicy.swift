import Foundation

/// A tab is safe to reuse for a reattach only when it's idle at a prompt or shows a finished
/// connection — never when some other program may be reading input (N1).
public func isSafeToReattach(lastLine: String) -> Bool {
    let l = lastLine.trimmingCharacters(in: .whitespaces)
    if l.isEmpty { return true }
    let finished = ["[Process completed]", "Connection to", "Connection closed", "[detached",
                    "[exited]", "[server exited]", "[lost server]", "client_loop: send disconnect",
                    "Your SSH session ended unexpectedly", "broken pipe"]
    if finished.contains(where: l.contains) { return true }
    guard let last = l.last else { return true }
    return "%$#>❯".contains(last)
}

/// True if `psOutput` (`ps -axo command=`) has a live attach client for this session.
/// Terminal's own `busy` flag can't be trusted (shell wrappers that rename the shell hide child
/// processes), so liveness is judged from the attach command Muxbar itself launched.
public func hasLiveAttachClient(psOutput: String, host: String, tmuxID: String) -> Bool {
    let id = NSRegularExpression.escapedPattern(for: tmuxID)
    let pattern = #"attach-session -t '?"# + id + #"'?(\s|$)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    for raw in psOutput.split(separator: "\n") {
        let line = String(raw)
        guard re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
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
