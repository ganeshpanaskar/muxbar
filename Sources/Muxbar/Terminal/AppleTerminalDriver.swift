import AppKit
import MuxbarCore

/// Terminal.app. Its AppleScript has no "new tab" command, so each session gets its own window.
/// A tab is identified by window id + tty (tty numbers get recycled, so tty alone never counts),
/// falling back to the custom title Muxbar set.
@MainActor
struct AppleTerminalDriver: TerminalDriver {
    let kind = TerminalKind.terminal
    private let app = "tell application id \"com.apple.Terminal\""

    func open(command: String, title: String) throws -> TabRef {
        let s = """
        \(app)
          activate
          set t to do script \(AppleScriptRunner.string(command))
          set custom title of t to \(AppleScriptRunner.string(title))
          set title displays custom title of t to true
          set title displays device name of t to false
          set title displays shell path of t to false
          set title displays window size of t to false
          set title displays file name of t to false
          set tt to tty of t
          set wid to 0
          repeat with w in windows
            repeat with x in tabs of w
              if tty of x is tt then set wid to id of w
            end repeat
          end repeat
          return (wid as text) & "|" & tt
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        let parts = out.split(separator: "|", maxSplits: 1).map(String.init)
        return TabRef(kind: .terminal, windowID: Int(parts.first ?? ""), tty: parts.count > 1 ? parts[1] : nil)
    }

    /// AppleScript handler that sets `w`/`x` to the matching window/tab, or leaves them missing.
    private func finder(_ ref: TabRef, title: String) -> String {
        let wid = ref.windowID ?? -1
        let tty = AppleScriptRunner.string(ref.tty ?? "")
        let ttl = AppleScriptRunner.string(title)
        return """
          set w to missing value
          set x to missing value
          repeat with ww in windows
            if id of ww is \(wid) then
              repeat with xx in tabs of ww
                if tty of xx is \(tty) then
                  set w to contents of ww
                  set x to contents of xx
                end if
              end repeat
            end if
          end repeat
          if x is missing value and \(ttl) is not "" then
            repeat with ww in windows
              repeat with xx in tabs of ww
                if custom title of xx is \(ttl) then
                  set w to contents of ww
                  set x to contents of xx
                end if
              end repeat
            end repeat
          end if
        """
    }

    func locate(_ ref: TabRef, title: String) throws -> LocatedTab? {
        let s = """
        \(app)
        \(finder(ref, title: title))
          if x is missing value then return "@@NOTFOUND"
          set c to history of x
          return ((id of w) as text) & "|" & (tty of x) & "|" & c
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        if out == "@@NOTFOUND" { return nil }
        let parts = out.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let last = parts[2].split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return LocatedTab(ref: TabRef(kind: .terminal, windowID: Int(parts[0]), tty: parts[1]), lastLine: last)
    }

    func bringToFront(_ ref: TabRef) throws {
        let s = """
        \(app)
        \(finder(ref, title: ""))
          if x is missing value then return "@@NOTFOUND"
          set selected of x to true
          set index of w to 1
          activate
          return "ok"
        end tell
        """
        if try AppleScriptRunner.run(s).stringValue == "@@NOTFOUND" {
            throw TerminalError(message: "Terminal window not found", code: -2)
        }
    }

    func run(command: String, in ref: TabRef) throws {
        let s = """
        \(app)
        \(finder(ref, title: ""))
          if x is missing value then return "@@NOTFOUND"
          do script \(AppleScriptRunner.string(command)) in x
          set selected of x to true
          set index of w to 1
          activate
          return "ok"
        end tell
        """
        if try AppleScriptRunner.run(s).stringValue == "@@NOTFOUND" {
            throw TerminalError(message: "Terminal window not found", code: -2)
        }
    }

    func setTitle(_ ref: TabRef, _ title: String) throws {
        let s = """
        \(app)
        \(finder(ref, title: ""))
          if x is missing value then return "@@NOTFOUND"
          set custom title of x to \(AppleScriptRunner.string(title))
          set title displays custom title of x to true
          return "ok"
        end tell
        """
        _ = try AppleScriptRunner.run(s)
    }

    func tabs() throws -> [TabInfo] {
        let s = """
        \(app)
          set out to ""
          repeat with w in windows
            repeat with x in tabs of w
              set out to out & (id of w as text) & (character id 9) & (tty of x) & (character id 9) & (custom title of x) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        let out = try AppleScriptRunner.run(s).stringValue ?? ""
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { return nil }
            return TabInfo(kind: .terminal, windowID: Int(f[0]), tty: f[1], itermSessionID: nil, title: f[2])
        }
    }
}
