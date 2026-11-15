import AppKit
import MuxbarCore

/// F10: several live sessions at once. Each tile hosts the session's own terminal view (moved, not
/// copied), so only the focused tile gets keystrokes and tmux sizes each window to its tile.
extension SessionStore {
    /// Grid members that still exist, in tile order.
    var gridKeys: [String] { state.grid.filter { state.sessions[$0] != nil } }

    var inGrid: Bool { state.layout == .grid && !gridKeys.isEmpty }

    /// Shows these sessions (at most 6) as tiles, attaching any that aren't open yet.
    func showInGrid(_ keys: [String], focus: String? = nil) {
        var ks: [String] = []
        for k in keys where state.sessions[k] != nil && !ks.contains(k) { ks.append(k) }
        ks = Array(ks.prefix(GridLayout.maxTiles))
        guard !ks.isEmpty else { return }
        mutate { $0.grid = ks; $0.layout = .grid }
        for k in ks { attachPane(k) }
        let f = focus.flatMap { ks.contains($0) ? $0 : nil } ?? selectedKey.flatMap { ks.contains($0) ? $0 : nil } ?? ks[0]
        focusTile(f)
    }

    /// ⌘-click in the sidebar, Add to Grid: the session joins (or leaves) the grid. Starting a grid
    /// from single view keeps the session you were looking at as the first tile.
    func toggleInGrid(_ key: String) {
        var ks = state.layout == .grid ? gridKeys : (selectedKey.map { [$0] } ?? [])
        if let i = ks.firstIndex(of: key) { ks.remove(at: i) } else {
            guard ks.count < GridLayout.maxTiles else { banner = "The grid shows at most \(GridLayout.maxTiles) sessions"; return }
            ks.append(key)
        }
        if ks.count <= 1 {
            let old = gridKeys
            mutate { $0.grid = ks; $0.layout = .single }
            focusedTile = nil
            select(ks.first ?? key)
            restoreSingleSizes(old, shown: ks.first ?? key)
        } else {
            showInGrid(ks, focus: ks.contains(key) ? key : nil)
        }
    }

    func removeFromGrid(_ key: String) {
        let old = gridKeys
        var ks = old
        ks.removeAll { $0 == key }
        if ks.count <= 1 {
            mutate { $0.grid = ks; $0.layout = .single }
            focusedTile = nil
            select(ks.first ?? key)
            restoreSingleSizes(old, shown: ks.first ?? key)
        } else {
            showInGrid(ks, focus: focusedTile == key ? nil : focusedTile)
            restoreSingleSizes([key], shown: nil)
        }
    }

    func clearGrid() {
        let k = focusedTile ?? selectedKey
        let old = gridKeys
        mutate { $0.grid = []; $0.layout = .single }
        focusedTile = nil
        if let k { select(k) }
        restoreSingleSizes(old, shown: k)
    }

    /// Panes that left the grid but aren't on screen keep their tile size (and so does their tmux
    /// window) until shown again; give them the single-view size now.
    func restoreSingleSizes(_ keys: [String], shown: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let size = TerminalPaneHost.PaneContainer.lastSingleSize else { return }
            for k in keys where k != shown && !(self.inGrid && self.gridKeys.contains(k)) {
                guard let v = self.embedded.session(k)?.view, v.frame.size != size else { continue }
                v.setFrameSize(size)
            }
        }
    }

    /// ⌘⏎: the focused tile alone, or back to the grid.
    func toggleExpand() {
        if state.layout == .grid {
            let k = focusedTile ?? selectedKey
            mutate { $0.layout = .single }
            focusedTile = nil
            if let k { select(k) }
            restoreSingleSizes(gridKeys, shown: k)
        } else if gridKeys.count >= 2 {
            showInGrid(gridKeys, focus: selectedKey)
        }
    }

    /// ⌃⌘ + arrow keys.
    func moveTileFocus(_ d: GridLayout.Direction) {
        let ks = gridKeys
        guard state.layout == .grid, let f = focusedTile, let i = ks.firstIndex(of: f) else { return }
        focusTile(ks[GridLayout.neighbor(of: i, count: ks.count, d)])
    }

    /// Makes `key` the tile that gets keystrokes (and the sidebar's selection).
    func focusTile(_ key: String) {
        guard state.sessions[key] != nil else { return }
        if focusedTile != key { focusedTile = key }
        if selectedKey != key {
            setSelection(key)
            mutate { $0.sessions[key]?.lastViewedAt = Int(Date().timeIntervalSince1970) }
        }
        if let v = embedded.session(key)?.view, let w = v.window, w.firstResponder !== v { w.makeFirstResponder(v) }
        rememberPanes()
    }

    /// Gives the keyboard back to the pane on screen (after the ⌘K palette closes).
    func restoreTerminalFocus() {
        let k = state.layout == .grid ? (focusedTile ?? selectedKey) : selectedKey
        guard let k, let v = embedded.session(k)?.view else { return }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}
