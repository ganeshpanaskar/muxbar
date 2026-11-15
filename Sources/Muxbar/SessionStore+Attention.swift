import AppKit
import MuxbarCore

/// F2: sessions become unread when their agent finishes or starts waiting while you aren't looking;
/// looking at one for a moment marks it read. The Inbox lists waiting sessions, then unread ones.
extension SessionStore {
    /// Seconds a session must be on screen before it counts as read.
    static let readAfter: TimeInterval = 1.5

    /// Muxbar is frontmost with its main window visible (test instances never activate, so they
    /// assume it unless a test says otherwise).
    var appFrontmost: Bool {
        if let o = viewingOverride { return o }
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
        }
    }

    /// The session you're looking at right now: the selected pane (or, in a grid, the focused tile).
    var viewedKey: String? {
        guard appFrontmost else { return nil }
        return state.layout == .grid ? (focusedTile ?? selectedKey) : selectedKey
    }

    func isViewing(_ key: String) -> Bool { viewedKey == key }

    /// Runs after each poll of `host`: finds new finishes/waits and marks them unread.
    func processAttention(host: String, before: [String: LiveInfo], after: [String: LiveInfo]) -> [(SessionRecord, Unread.Event)] {
        var events: [(SessionRecord, Unread.Event)] = []
        let now = Int(Date().timeIntervalSince1970)
        for (key, info) in after where state.sessions[key]?.host == host {
            if info.status == .idle { if before[key]?.status != .idle || idleSinceAt[key] == nil { idleSinceAt[key] = now } }
            else { idleSinceAt[key] = nil }
            var t = trackers[key] ?? Unread.Tracker()
            let ev = Unread.step(&t, prev: before[key]?.status, next: info.status, source: info.source,
                                 hookEvent: info.hookEvent, hookTS: info.hookTS)
            trackers[key] = t
            guard let ev, let rec = state.sessions[key], !isViewing(key) else { continue }
            markUnread(key, event: ev, info: info)
            events.append((state.sessions[key] ?? rec, ev))
        }
        return events
    }

    private func markUnread(_ key: String, event: Unread.Event, info: LiveInfo) {
        let now = Int(Date().timeIntervalSince1970)
        let reply = info.reply.isEmpty ? nil : AgentTranscript.oneLine(info.reply)
        mutate { st in
            st.sessions[key]?.unread = true
            if event == .finished {
                st.sessions[key]?.finishedAt = now
                if let r = reply { st.sessions[key]?.lastReply = r }
            }
        }
        if event == .finished && reply == nil { Task { await fetchPreview(key, info: info) } }
    }

    /// The start of the agent's last reply, from its transcript (when the hook didn't carry it).
    func fetchPreview(_ key: String, info: LiveInfo) async {
        guard let rec = state.sessions[key] else { return }
        let agent = info.agent ?? rec.agent ?? .claude
        var path = info.transcript.isEmpty ? nil : info.transcript
        var dir: String?
        if agent == .claude, let cwd = rec.path {
            dir = "~/.claude/projects/" + AgentTranscript.claudeProjectDir(for: cwd)
            if path == nil, let id = rec.resumeID { path = dir! + "/" + id + ".jsonl" }
        }
        guard path != nil || dir != nil else { return }
        let r = await runner().run(host: rec.host, script: AgentTranscript.tailScript(path: path, dir: dir), timeout: 15)
        guard let text = AgentTranscript.lastAssistantText(r.stdout, agent: agent) else { return }
        let line = AgentTranscript.oneLine(text)
        mutate { $0.sessions[key]?.lastReply = line }
    }

    func setUnread(_ key: String, _ unread: Bool) {
        mutate { st in
            st.sessions[key]?.unread = unread
            if !unread { st.sessions[key]?.lastViewedAt = Int(Date().timeIntervalSince1970) }
            else if st.sessions[key]?.finishedAt == nil { st.sessions[key]?.finishedAt = Int(Date().timeIntervalSince1970) }
        }
        if unread {
            viewStart[key] = nil; keepUnreadUntilLeft = key
            if state.layout == .grid && gridKeys.contains(key) && key != viewedKey { gridSticky.insert(key); tileViewStart[key] = nil }
        }
        Attention.shared.refreshBadge(self)
    }

    func markAllRead(host: String? = nil) {
        mutate { st in
            for k in st.sessions.keys where st.sessions[k]?.unread == true && (host == nil || st.sessions[k]?.host == host) {
                st.sessions[k]?.unread = false
            }
        }
        Attention.shared.refreshBadge(self)
    }

    /// Seconds an unread grid tile that isn't focused must be on screen before it counts as read.
    static let tileReadAfter: TimeInterval = 3

    /// Called twice a second: a session on screen for `readAfter` seconds becomes read.
    func tickViewing() {
        tickGridTiles()
        guard let key = viewedKey else { viewStart.removeAll(); keepUnreadUntilLeft = nil; return }
        // "Mark as Unread" on the session you're looking at keeps it unread until you look away.
        if keepUnreadUntilLeft == key { return }
        keepUnreadUntilLeft = nil
        for k in viewStart.keys where k != key { viewStart[k] = nil }
        guard state.sessions[key]?.unread == true else { viewStart[key] = nil; return }
        let start = viewStart[key] ?? Date()
        viewStart[key] = start
        if Date().timeIntervalSince(start) >= Self.readAfter {
            viewStart[key] = nil
            setUnread(key, false)
        }
    }

    /// Grid tiles on screen but not focused: read after `tileReadAfter` seconds.
    private func tickGridTiles() {
        guard state.layout == .grid, appFrontmost else { tileViewStart.removeAll(); gridSticky.removeAll(); return }
        let visible = Set(gridKeys).subtracting([viewedKey].compactMap { $0 })
        gridSticky.formIntersection(visible)
        let now = Date()
        for k in Array(tileViewStart.keys) where !visible.contains(k) || state.sessions[k]?.unread != true { tileViewStart[k] = nil }
        for k in visible where state.sessions[k]?.unread == true && !gridSticky.contains(k) {
            let start = tileViewStart[k] ?? now
            tileViewStart[k] = start
            if now.timeIntervalSince(start) >= Self.tileReadAfter {
                tileViewStart[k] = nil
                setUnread(k, false)
            }
        }
    }

    /// Unread sessions that aren't waiting (waiting ones are listed first anyway), newest first.
    var unreadFinished: [SessionRecord] {
        state.sessions.values.filter { $0.unread && !$0.archived && !$0.ended && status(of: $0) != .waiting }
            .sorted { ($0.finishedAt ?? 0, $0.name) > ($1.finishedAt ?? 0, $1.name) }
    }

    /// The Inbox: needs input (longest waiting first), then finished and unread (newest first).
    var inbox: [SessionRecord] { waitingSessions + unreadFinished }

    func unreadCount(group: String, host: String) -> Int {
        sessions(inGroup: group, host: host).filter { $0.unread && status(of: $0) != .waiting }.count
    }

    func unreadCount(host: String) -> Int {
        sessions(for: host).filter { $0.unread && !$0.ended && status(of: $0) != .waiting }.count
    }
}
