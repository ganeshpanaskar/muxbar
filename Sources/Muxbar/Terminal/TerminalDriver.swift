import AppKit
import MuxbarCore

struct TerminalError: Error, LocalizedError {
    var message: String
    var code: Int
    var errorDescription: String? { message }

    /// macOS Automation permission denied (TCC).
    var isAutomationDenied: Bool { code == -1743 || code == -10004 }
}

/// What a located tab looks like, so the store can decide whether reattaching in place is safe.
struct LocatedTab {
    var ref: TabRef
    var lastLine: String
    /// Set when the terminal itself knows whether a shell prompt is in the foreground (iTerm2's
    /// jobName); otherwise the store judges from `lastLine`.
    var atPrompt: Bool? = nil

    var safeToReattach: Bool { atPrompt ?? isSafeToReattach(lastLine: lastLine) }
}

/// Foreground job names that mean "sitting at a shell prompt".
func isShellJob(_ job: String) -> Bool {
    let j = job.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = j.split(separator: " ").first.map(String.init) ?? j
    return ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "login", "dash"].contains(base)
}

struct TabInfo: Codable {
    var kind: TerminalKind
    var windowID: Int?
    var tty: String?
    var itermSessionID: String?
    var title: String
}

/// Opens, finds, focuses and names windows/tabs in the user's terminal. Never reads or sends
/// keystrokes except the single launch/attach command (N1).
@MainActor
protocol TerminalDriver {
    var kind: TerminalKind { get }
    func open(command: String, title: String) throws -> TabRef
    func locate(_ ref: TabRef, title: String) throws -> LocatedTab?
    func bringToFront(_ ref: TabRef) throws
    /// Runs `command` in an existing tab that is sitting at a shell prompt.
    func run(command: String, in ref: TabRef) throws
    func setTitle(_ ref: TabRef, _ title: String) throws
    func tabs() throws -> [TabInfo]
}

enum AppleScriptRunner {
    @MainActor
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalError(message: "AppleScript failed to compile", code: -1)
        }
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? -1
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            Log.error("AppleScript error \(code): \(msg)")
            throw TerminalError(message: msg, code: code)
        }
        return result
    }

    static func string(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

@MainActor
func makeDriver(_ kind: TerminalKind) -> TerminalDriver {
    kind == .iterm ? ITermDriver() : AppleTerminalDriver()
}

func isITermInstalled() -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
}
