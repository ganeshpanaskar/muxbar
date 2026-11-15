import AppKit
import MuxbarCore

/// F7: the ⌘K quick switcher's rows, commands and first-prompt lookup.
extension SessionStore {
    /// Sessions (not archived) plus the commands the palette can run.
    func switcherItems() -> [QuickSwitch.Item] {
        var items = state.sessions.values.filter { !$0.archived }.map { r in
            QuickSwitch.Item(id: r.key, title: r.name, group: r.group, host: hostLabel(r.host), folder: r.path,
                             prompt: r.firstPromptID != nil && r.firstPromptID == r.resumeID ? r.firstPrompt : nil,
                             needsYou: status(of: r) == .waiting,
                             waitingSince: waitingSince[r.key].map { Int($0.timeIntervalSince1970) },
                             unread: r.unread && !r.ended, finishedAt: r.finishedAt, lastViewed: r.lastViewedAt)
        }
        items += [("new", "New Session…"), ("continue", "Continue Session…"), ("history", "Search History…"), ("settings", "Settings…")].map {
            QuickSwitch.Item(id: $0.0, kind: .command, title: $0.1)
        }
        for h in state.hosts where sleepCandidates(host: h).count > 0 {
            items.append(QuickSwitch.Item(id: "sleep:" + h, kind: .command, title: "Sleep idle sessions on \(hostLabel(h))"))
        }
        return items
    }

    func switcherRows(query: String) -> [QuickSwitch.Row] {
        QuickSwitch.rank(switcherItems(), query: query, now: Int(Date().timeIntervalSince1970))
    }

    /// Opens a row: a session (in the grid with ⌥), or runs a command.
    func openSwitcherRow(_ row: QuickSwitch.Row, toGrid: Bool = false) {
        switcherOpen = false
        switch row.item.kind {
        case .session:
            guard let rec = state.sessions[row.item.id] else { return }
            if toGrid {
                if !(state.layout == .grid && gridKeys.contains(rec.key)) { toggleInGrid(rec.key) } else { focusTile(rec.key) }
            } else if state.layout == .grid && gridKeys.contains(rec.key) {
                focusTile(rec.key)
            } else {
                if state.layout == .grid { mutate { $0.layout = .single }; focusedTile = nil }
                if rec.ended { select(rec.key) } else { Actions.focus(self, rec) }
            }
        case .command:
            let id = row.item.id
            if id == "settings" { WindowOpener.openSettings?() }
            else if id.hasPrefix("sleep:") { Actions.sleepIdle(self, host: String(id.dropFirst(6))) }
            else { WindowOpener.open?(id) }
        }
        restoreTerminalFocus()
    }

    /// Looks up the first prompt of conversations that don't have one yet (one ssh per host, in the
    /// background). Rows already shown keep their order; the next keystroke can match the prompt.
    func refreshFirstPrompts() {
        var byHost: [String: [(key: String, id: String, path: String, agent: AgentKind)]] = [:]
        for r in state.sessions.values where !r.archived && !r.ended {
            guard let id = r.resumeID, r.firstPromptID != id, !firstPromptTried.contains(r.key + "|" + id) else { continue }
            let agent = live[r.key]?.agent ?? r.agent ?? .claude
            var path = live[r.key]?.transcript ?? ""
            if path.isEmpty, agent == .claude, let cwd = r.path {
                path = "~/.claude/projects/" + AgentTranscript.claudeProjectDir(for: cwd) + "/" + id + ".jsonl"
            }
            guard !path.isEmpty else { continue }
            firstPromptTried.insert(r.key + "|" + id)
            byHost[r.host, default: []].append((r.key, id, path, agent))
        }
        for (host, list) in byHost {
            Task {
                let nonce = HostProbe.makeNonce()
                let r = await runner().run(host: host, script: AgentTranscript.headsScript(paths: list.map(\.path), nonce: nonce), timeout: 20)
                let heads = AgentTranscript.parseHeads(r.stdout, nonce: nonce)
                var found: [(String, String, String)] = []
                for (i, item) in list.enumerated() {
                    if let h = heads[i], let t = AgentTranscript.firstUserText(h, agent: item.agent) {
                        found.append((item.key, item.id, AgentTranscript.oneLine(t, limit: 160)))
                    }
                }
                guard !found.isEmpty else { return }
                mutate { st in for (k, id, t) in found { st.sessions[k]?.firstPrompt = t; st.sessions[k]?.firstPromptID = id } }
            }
        }
    }
}
