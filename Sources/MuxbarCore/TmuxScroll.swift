import Foundation

/// Scrolling a tmux session's history from outside (Muxbar's pane scroll bar and wheel).
/// `scroll_position` counts lines up from the bottom; 0 / not in copy mode = live output.
public struct TmuxScrollInfo: Equatable, Sendable {
    public var history: Int
    public var inMode: Bool
    public var position: Int
    public var height: Int

    public init(history: Int, inMode: Bool, position: Int, height: Int) {
        self.history = history; self.inMode = inMode; self.position = position; self.height = height
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
        "\(tmux) display-message -p -t \(shellQuote(id)) '#{history_size} #{pane_in_mode} #{scroll_position} #{pane_height}'"
    }

    public static func parse(_ out: String) -> TmuxScrollInfo? {
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard f.count == 4, let h = Int(f[0]), let ht = Int(f[3]) else { return nil }
        return TmuxScrollInfo(history: h, inMode: f[1] == "1", position: Int(f[2]) ?? 0, height: ht)
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
