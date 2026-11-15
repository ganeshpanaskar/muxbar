import Foundation

/// Scrolling a tmux session's history from outside (Muxbar's pane scroll bar and wheel).
/// `scroll_position` counts lines up from the bottom; 0 / not in copy mode = live output.
public struct TmuxScrollInfo: Equatable, Sendable {
    public var history: Int
    public var inMode: Bool
    public var position: Int
    public var height: Int
    /// Full-screen app (alternate screen: Claude Code, less, vim). It keeps its own history and
    /// tmux has none, so scrolling must go to the app as Page Up / Page Down.
    public var alternate: Bool = false
    /// The app turned on mouse reporting (Claude Code's fullscreen view, Codex with mouse on):
    /// it scrolls line by line on wheel events, so those are sent instead of Page Up / Page Down.
    public var mouse: MouseMode = .off

    public enum MouseMode: Equatable, Sendable { case off, legacy, sgr }

    public init(history: Int, inMode: Bool, position: Int, height: Int, alternate: Bool = false, mouse: MouseMode = .off) {
        self.history = history; self.inMode = inMode; self.position = position; self.height = height
        self.alternate = alternate; self.mouse = mouse
    }

    /// Scroll through tmux history (copy mode) — only for normal-screen panes that have some.
    public var usesTmuxHistory: Bool { !alternate && history > 0 }

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
        "\(tmux) display-message -p -t \(shellQuote(id)) '#{history_size} #{pane_in_mode} #{scroll_position} #{pane_height} #{alternate_on} #{mouse_any_flag}#{mouse_button_flag}#{mouse_standard_flag} #{mouse_sgr_flag}'"
    }

    /// Reads the info line; when a script printed more before it, the last line.
    public static func parse(_ out: String) -> TmuxScrollInfo? {
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let f = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: false)
        guard [4, 5, 7].contains(f.count), let h = Int(f[0]), let ht = Int(f[3]) else { return nil }
        var mouse = TmuxScrollInfo.MouseMode.off
        if f.count == 7, f[5].contains("1") { mouse = f[6] == "1" ? .sgr : .legacy }
        return TmuxScrollInfo(history: h, inMode: f[1] == "1", position: Int(f[2]) ?? 0, height: ht,
                              alternate: f.count >= 5 && f[4] == "1", mouse: mouse)
    }

    /// What a terminal sends for `events` wheel steps (> 0 = up) at `col`, `row` (1-based, SGR
    /// encoding), or for Page Up / Page Down. Written to the attached tmux client, tmux passes it
    /// to the pane's app.
    public static func clientWheelBytes(events: Int, col: Int, row: Int) -> [UInt8] {
        guard events != 0 else { return [] }
        let one = Array("\u{1B}[<\(events > 0 ? 64 : 65);\(col);\(row)M".utf8)
        return Array(repeating: one, count: min(abs(events), 40)).flatMap { $0 }
    }
    public static func clientPageBytes(pages: Int) -> [UInt8] {
        guard pages != 0 else { return [] }
        return Array(repeating: Array((pages > 0 ? "\u{1B}[5~" : "\u{1B}[6~").utf8), count: min(abs(pages), 20)).flatMap { $0 }
    }

    /// Wheel events (events > 0 = up) delivered to the app as mouse reports at `col`, `row`
    /// (1-based), as a terminal would send them. One tmux call however many there are.
    public static func wheelScript(tmux: String = "tmux", id: String, events: Int, mouse: TmuxScrollInfo.MouseMode,
                                   col: Int, row: Int) -> String {
        guard events != 0, mouse != .off else { return "true" }
        let button = events > 0 ? 64 : 65
        let one: [UInt8]
        if mouse == .sgr {
            one = Array("\u{1B}[<\(button);\(col);\(row)M".utf8)
        } else {   // X10 encoding: values offset by 32, limited to 223
            one = [0x1B, 0x5B, 0x4D, UInt8(32 + button), UInt8(32 + min(col, 223)), UInt8(32 + min(row, 223))]
        }
        let bytes = Array(repeating: one, count: min(abs(events), 40)).flatMap { $0 }
        return "\(tmux) send-keys -t \(shellQuote(id)) -H " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Positive = scroll up (back in history). `copy-mode -e` exits again at the bottom.
    public static func scrollScript(tmux: String = "tmux", id: String, lines: Int) -> String {
        let t = shellQuote(id)
        if lines > 0 { return "\(tmux) copy-mode -e -t \(t) && \(tmux) send-keys -t \(t) -X -N \(lines) scroll-up" }
        if lines < 0 { return "\(tmux) send-keys -t \(t) -X -N \(-lines) scroll-down 2>/dev/null; true" }
        return "true"
    }

    /// Page Up (pages > 0) / Page Down (pages < 0) sent to the app in the pane.
    public static func pageKeysScript(tmux: String = "tmux", id: String, pages: Int) -> String {
        guard pages != 0 else { return "true" }
        let key = pages > 0 ? "PPage" : "NPage"
        return "\(tmux) send-keys -t \(shellQuote(id))" + String(repeating: " \(key)", count: min(abs(pages), 20))
    }

    /// Jump to `position` lines from the bottom; 0 = back to live output.
    public static func gotoScript(tmux: String = "tmux", id: String, position: Int) -> String {
        let t = shellQuote(id)
        if position <= 0 { return "\(tmux) send-keys -t \(t) -X cancel 2>/dev/null; true" }
        return "\(tmux) copy-mode -e -t \(t) && \(tmux) send-keys -t \(t) -X goto-line \(position)"
    }
}
