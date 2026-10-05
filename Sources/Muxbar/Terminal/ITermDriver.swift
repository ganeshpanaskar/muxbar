import AppKit
import MuxbarCore

/// iTerm2: real tabs, identified by the session's `unique ID`.
@MainActor
struct ITermDriver: TerminalDriver {
    let kind = TerminalKind.iterm
    private let app = "tell application id \"com.googlecode.iterm2\""

    func open(command: String, title: String) throws -> TabRef {
        // Open a normal shell tab, then type the command into it: iTerm's `command` parameter
        // splits on spaces without shell quoting, and the shell must outlive ssh anyway.
        let s = """
        \(app)
          activate
          if (count of windows) = 0 then
            set w to (create window with default profile)
          else
            set w to current window
            tell w to create tab with default profile
          end if
          set s to current session of w
          tell s
            write text \(AppleScriptRunner.string(command))
            set name to \(AppleScriptRunner.string(title))
          end tell
          return (unique ID of s) & "|" & (tty of s)
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        let parts = out.split(separator: "|", maxSplits: 1).map(String.init)
        return TabRef(kind: .iterm, tty: parts.count > 1 ? parts[1] : nil, itermSessionID: parts.first)
    }

    /// Sets fw/ft/fs to the window/tab/session with this unique ID. Uses index references:
    /// `contents of <loop var>` collides with iTerm's own `contents` property.
    private func finder(_ ref: TabRef) -> String {
        let id = AppleScriptRunner.string(ref.itermSessionID ?? "@@none")
        return """
          set fw to missing value
          set ft to missing value
          set fs to missing value
          repeat with wi from 1 to (count of windows)
            repeat with ti from 1 to (count of tabs of window wi)
              repeat with si from 1 to (count of sessions of tab ti of window wi)
                if unique ID of session si of tab ti of window wi is \(id) then
                  set fw to window wi
                  set ft to tab ti of window wi
                  set fs to session si of tab ti of window wi
                end if
              end repeat
            end repeat
          end repeat
        """
    }

    func locate(_ ref: TabRef, title: String) throws -> LocatedTab? {
        let s = """
        \(app)
        \(finder(ref))
          if fs is missing value then return "@@NOTFOUND"
          set j to ""
          try
            set j to (variable of fs named "jobName")
          end try
          return (tty of fs) & "|" & j & "|" & (text of fs)
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        if out == "@@NOTFOUND" { return nil }
        let parts = out.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let job = parts.count > 1 ? parts[1] : ""
        let last = (parts.count > 2 ? parts[2] : "").split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var r = ref
        r.tty = parts.first
        // The screen can still show a dead tmux status bar after ssh dies, so trust iTerm's job.
        return LocatedTab(ref: r, lastLine: last, atPrompt: job.isEmpty ? nil : isShellJob(job))
    }

    private func perform(_ ref: TabRef, _ body: String) throws {
        let s = """
        \(app)
        \(finder(ref))
          if fs is missing value then return "@@NOTFOUND"
        \(body)
          return "ok"
        end tell
        """
        if try AppleScriptRunner.run(s).stringValue == "@@NOTFOUND" {
            throw TerminalError(message: "iTerm2 session not found", code: -2)
        }
    }

    func bringToFront(_ ref: TabRef) throws {
        try perform(ref, """
          select fw
          tell ft to select
          tell fs to select
          activate
        """)
    }

    func run(command: String, in ref: TabRef) throws {
        // After an abrupt disconnect, the terminal's answers to tmux's queries can sit in the
        // shell's input line as junk. Ctrl-C at a prompt discards it before we type.
        try perform(ref, """
          tell fs to write text (character id 3) newline no
          delay 0.4
          tell fs to write text \(AppleScriptRunner.string(command))
          select fw
          tell ft to select
          tell fs to select
          activate
        """)
    }

    func setTitle(_ ref: TabRef, _ title: String) throws {
        try perform(ref, "  tell fs to set name to \(AppleScriptRunner.string(title))")
    }

    func tabs() throws -> [TabInfo] {
        let s = """
        \(app)
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                set out to out & (unique ID of s) & (character id 9) & (tty of s) & (character id 9) & (name of s) & linefeed
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { return nil }
            return TabInfo(kind: .iterm, windowID: nil, tty: f[1], itermSessionID: f[0], title: f[2])
        }
    }
}
