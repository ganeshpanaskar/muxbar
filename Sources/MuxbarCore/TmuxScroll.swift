import Foundation

/// Scrolling a tmux session's history from outside (Muxbar's pane scroll bar and wheel).
/// `scroll_position` counts lines up from the bottom; 0 / not in copy mode = live output.
///
/// Full-screen apps (Claude Code's full-screen UI, vim, less…) draw on the alternate screen, where
/// tmux keeps no history: the app owns it. Then scrolling is sent to the app instead — as mouse
/// wheel events if it asked for mouse input, else as arrow keys (what Terminal and iTerm2 do).
public struct TmuxScrollInfo: Equatable, Sendable {
    public var history: Int
    public var inMode: Bool
    public var position: Int
    public var height: Int
    /// The pane shows the alternate screen (a full-screen app).
    public var fullscreen: Bool
    /// The app in the pane asked for mouse events (so it can take wheel scrolling).
    public var appMouse: Bool

    public init(history: Int, inMode: Bool, position: Int, height: Int, fullscreen: Bool = false, appMouse: Bool = false) {
        self.history = history; self.inMode = inMode; self.position = position; self.height = height
        self.fullscreen = fullscreen; self.appMouse = appMouse
    }

    /// Thumb geometry as fractions of the track (0 = top).
    public var thumbTop: Double {
        let total = Double(history + height)
        guard total > 0 else { return 0 }
        return Double(history - (inMode ? position : 0)) / total
    }
    public var thumbHeight: Double {
        let total = Double(history + height)
        guard total > 0 else { return 1 }
        return max(0.04, Double(height) / total)
    }
    public var atLive: Bool { !inMode || position == 0 }

    /// Lines-from-bottom for a thumb whose top sits at `fraction` of the track.
    public func position(forThumbTop fraction: Double) -> Int {
        let total = Double(history + height)
        let p = Double(history) - fraction * total
        return min(history, max(0, Int(p.rounded())))
    }
}

public enum TmuxScroll {
    public static func infoScript(tmux: String = "tmux", id: String) -> String {
        "\(tmux) display-message -p -t \(shellQuote(id)) '#{history_size} #{pane_in_mode} #{scroll_position} #{pane_height} #{alternate_on} #{mouse_any_flag}'"
    }

    /// Accepts the 6-field output of `infoScript` (and the older 4-field form).
    public static func parse(_ out: String) -> TmuxScrollInfo? {
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard f.count == 4 || f.count == 6, let h = Int(f[0]), let ht = Int(f[3]) else { return nil }
        return TmuxScrollInfo(history: h, inMode: f[1] == "1", position: Int(f[2]) ?? 0, height: ht,
                              fullscreen: f.count == 6 && f[4] == "1", appMouse: f.count == 6 && f[5] == "1")
    }

    /// Scrolls a full-screen app by `ticks` wheel notches (positive = up/back). Apps that asked for
    /// mouse input get SGR wheel events at (`col`, `row`); others get arrow keys.
    public static func appScrollScript(tmux: String = "tmux", id: String, ticks: Int, mouse: Bool,
                                       col: Int = 10, row: Int = 10) -> String {
        let n = min(30, abs(ticks))
        guard n > 0 else { return "true" }
        let t = shellQuote(id)
        if mouse {
            let event = "\\033[<\(ticks > 0 ? 64 : 65);\(max(1, col));\(max(1, row))M"
            return "\(tmux) send-keys -t \(t) -l \"$(printf '\(String(repeating: event, count: n))')\""
        }
        let key = ticks > 0 ? "Up" : "Down"
        return "\(tmux) send-keys -t \(t) " + Array(repeating: key, count: n).joined(separator: " ")
    }

    /// Pages a full-screen app with Page Up / Page Down keys (positive = up/back).
    public static func appPageScript(tmux: String = "tmux", id: String, pages: Int) -> String {
        let n = min(10, abs(pages))
        guard n > 0 else { return "true" }
        return "\(tmux) send-keys -t \(shellQuote(id)) " + Array(repeating: pages > 0 ? "PPage" : "NPage", count: n).joined(separator: " ")
    }

    /// Positive = scroll up (back in history). `copy-mode -e` exits again at the bottom.
    public static func scrollScript(tmux: String = "tmux", id: String, lines: Int) -> String {
        let t = shellQuote(id)
        if lines > 0 { return "\(tmux) copy-mode -e -t \(t) && \(tmux) send-keys -t \(t) -X -N \(lines) scroll-up" }
        if lines < 0 { return "\(tmux) send-keys -t \(t) -X -N \(-lines) scroll-down 2>/dev/null; true" }
        return "true"
    }

    /// Jump to `position` lines from the bottom; 0 = back to live output.
    public static func gotoScript(tmux: String = "tmux", id: String, position: Int) -> String {
        let t = shellQuote(id)
        if position <= 0 { return "\(tmux) send-keys -t \(t) -X cancel 2>/dev/null; true" }
        return "\(tmux) copy-mode -e -t \(t) && \(tmux) send-keys -t \(t) -X goto-line \(position)"
    }
}
