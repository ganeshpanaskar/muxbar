import AppKit
import MuxbarCore
import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .idle, .running: return .green
        case .notClaude, .notRunning: return .gray
        case .unknown: return .secondary.opacity(0.5)
        case .ended: return .clear
        }
    }
}

func relativeAge(_ epoch: Int?) -> String {
    guard let epoch, epoch > 0 else { return "" }
    return "active " + timeAgo(epoch)
}

/// "just now", "3m ago", "2h ago", "4d ago".
func timeAgo(_ epoch: Int) -> String {
    let s = max(0, Int(Date().timeIntervalSince1970) - epoch)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

/// The session list shared by the menu-bar popover and the main window.
struct SessionList: View {
    @EnvironmentObject var store: SessionStore
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner = store.banner {
                BannerView(text: banner, automation: store.automationDenied) { store.banner = nil }
            }
            ForEach(store.state.hosts, id: \.self) { host in
                HostSection(host: host, compact: compact)
            }
        }
    }
}

struct BannerView: View {
    var text: String
    var automation: Bool
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if automation {
                Button("Reset permission") {
                    // Clears a stale grant (e.g. after a rebuild) so macOS asks again on next use.
                    _ = Process.launchedProcess(launchPath: "/usr/bin/tccutil", arguments: ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "io.github.ganeshpanaskar.muxbar"])
                    dismiss()
                }
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}

struct HostSection: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    var compact: Bool

    var body: some View {
        let health = store.health[host] ?? .unknown
        let sessions = store.sessions(for: host)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(host == localHost ? "This Mac" : host).font(.headline)
                Text(health.label)
                    .font(.caption)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(health == .ok ? Color.green.opacity(0.15) : Color.orange.opacity(0.2)))
                Spacer()
                if sessions.contains(where: { $0.ended && $0.agent != nil }) {
                    Button("Resume all") { Actions.resumeAll(store, host: host) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Resume every ended Claude/Codex session here, each in its own conversation")
                }
                if sessions.contains(where: \.ended) {
                    Button("Clear ended") { store.dismissEnded(host: host) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if let hint = health.hint, health != .ok {
                Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sessions.isEmpty && health == .ok {
                Text("No sessions").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { rec in
                SessionRow(rec: rec, compact: compact)
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord
    var compact: Bool

    var body: some View {
        let status = store.status(of: rec)
        HStack(spacing: 8) {
            Circle()
                .fill(status.color)
                .overlay(Circle().stroke(Color.secondary.opacity(status == .ended ? 0.6 : 0), lineWidth: 1))
                .frame(width: 9, height: 9)
                .help(status.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name).fontWeight(.medium).foregroundStyle(rec.ended ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let p = rec.path { Text(p).lineLimit(1).truncationMode(.head) }
                    Text(rec.ended ? "ended" : relativeAge(rec.lastActivity))
                    if rec.isPlainTab { Text("· window only, no tmux") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { Actions.focus(store, rec) }
        .contextMenu {
            if !rec.ended {
                Button("Focus / Attach") { Actions.focus(store, rec) }
                Button("Rename…") { Actions.rename(store, rec) }
                Divider()
                Button("Kill Session…", role: .destructive) { Actions.kill(store, rec) }
            } else {
                Button("Resume Session") { Actions.resumeEnded(store, rec) }
                Button("Remove from list") { Actions.remove(store, rec) }
            }
        }
    }
}

/// User-initiated actions with NSAlert dialogs (work from the menu-bar popover too).
@MainActor
enum Actions {
    /// Removing a host with sessions asks first: Muxbar forgets them (they keep running there).
    @MainActor static func confirmRemoveHost(_ store: SessionStore, _ host: String) {
        let n = store.sessions(for: host).filter { !$0.ended }.count
        if n > 0 {
            let alert = NSAlert()
            alert.messageText = "Remove \(host)?"
            alert.informativeText = "Muxbar forgets its \(n) session\(n == 1 ? "" : "s") on \(host) (names in Muxbar and groups). They keep running there; adding the host again finds them."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.removeHost(host)
    }

    static func pasteImage(_ store: SessionStore) {
        guard let key = store.viewedKey ?? store.selectedKey else { NSSound.beep(); return }
        Task { do { try await store.pasteClipboardImage(key) } catch { report(store, error) } }
    }

    /// Above 100 MB a drop asks first.
    @MainActor static func confirmLargeDrop(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func sleep(_ store: SessionStore, _ rec: SessionRecord) {
        Task { do { try await store.sleep(rec.key) } catch { report(store, error) } }
    }

    static func wake(_ store: SessionStore, _ rec: SessionRecord) {
        Task { do { try await store.wake(rec.key) } catch { report(store, error) } }
    }

    static func sleepIdle(_ store: SessionStore, host: String) {
        Task {
            let res = await store.sleepIdle(host: host)
            let slept = res.filter { $0.result == "slept" }
            let freed = slept.reduce(0) { $0 + $1.freedKB }
            store.banner = slept.isEmpty ? "No idle agents could sleep on \(store.hostLabel(host))."
                : "Slept \(slept.count) agent\(slept.count == 1 ? "" : "s") on \(store.hostLabel(host)), freeing ~\(formatKB(freed)). Open a session to wake it."
        }
    }

    static func report(_ store: SessionStore, _ error: Error) {
        Log.error("action failed: \(error)")
        store.banner = error.localizedDescription
    }

    static func focus(_ store: SessionStore, _ rec: SessionRecord) {
        guard !rec.ended else { return }
        Task { do { _ = try await store.focus(key: rec.key) } catch { report(store, error) } }
    }

    static func rename(_ store: SessionStore, _ rec: SessionRecord) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = "Rename “\(rec.name)”"
        alert.informativeText = "Letters, digits, - and _ only. Renames the tmux session and the terminal title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = rec.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { do { _ = try await store.rename(key: rec.key, to: name) } catch { report(store, error) } }
    }

    static func kill(_ store: SessionStore, _ rec: SessionRecord) {
        activateApp()
        let alert = NSAlert()
        alert.alertStyle = .critical
        let where_ = rec.host == localHost ? "this Mac" : rec.host
        alert.messageText = "Kill “\(rec.name)” on \(where_)?"
        alert.informativeText = rec.isPlainTab
            ? "Removes it from Muxbar. The terminal window is left open."
            : "This runs tmux kill-session \(rec.tmuxID ?? "") on \(where_). Anything running in it (including Claude) stops. This can't be undone."
        alert.addButton(withTitle: "Kill Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await store.kill(key: rec.key) } catch { report(store, error) } }
    }

    static func askName(_ title: String, _ initial: String, _ button: String) -> String? {
        activateApp()
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// New group on a host. With no host given, asks which one (default: the selected session's).
    static func newGroup(_ store: SessionStore, host: String?, moving rec: SessionRecord? = nil) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = host.map { "New Group on \(store.hostLabel($0))" } ?? "New Group"
        alert.informativeText = "A group lives under one host and holds only that host's sessions."
        let box = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: host == nil ? 56 : 24))
        box.orientation = .vertical
        box.alignment = .leading
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        if host == nil {
            for h in store.state.hosts { popup.addItem(withTitle: store.hostLabel(h)); popup.lastItem?.representedObject = h }
            let preferred = store.selectedKey.flatMap { store.state.sessions[$0]?.host } ?? localHost
            if let i = store.state.hosts.firstIndex(of: preferred) { popup.selectItem(at: i) }
            box.addArrangedSubview(popup)
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Group name"
        box.addArrangedSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let h = host ?? (popup.selectedItem?.representedObject as? String) ?? localHost
        do {
            let g = try store.createGroup(host: h, field.stringValue)
            if let rec, rec.host == h { setGroup(store, rec, g) }
        } catch { report(store, error) }
    }

    static func renameGroup(_ store: SessionStore, host: String, _ g: String) {
        guard let name = askName("Rename Group “\(g)”", g, "Rename") else { return }
        Task { do { try await store.renameGroup(host: host, g, to: name) } catch { report(store, error) } }
    }

    static func deleteGroup(_ store: SessionStore, host: String, _ g: String) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = "Delete group “\(g)” on \(store.hostLabel(host))?"
        alert.informativeText = "Only the group is removed. Its sessions keep running and stay under \(store.hostLabel(host)); their workspace folders move back to the root (nothing is deleted)."
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await store.deleteGroup(host: host, g) } catch { report(store, error) } }
    }

    static func resumeEnded(_ store: SessionStore, _ rec: SessionRecord) {
        Task { do { _ = try await store.resumeEnded(key: rec.key) } catch { report(store, error) } }
    }

    static func newSession(_ store: SessionStore, host: String, group: String?) {
        store.newSessionPrefill = (host, group)
        activateApp()
        WindowOpener.open?("new")
    }

    static func setGroup(_ store: SessionStore, _ rec: SessionRecord, _ g: String?) {
        Task { do { try await store.setGroup(key: rec.key, group: g) } catch { report(store, error) } }
    }

    static func nextWaiting(_ store: SessionStore) {
        Task { do { _ = try await store.focusNextWaiting() } catch { report(store, error) } }
    }

    static func reconnect(_ store: SessionStore, _ rec: SessionRecord) {
        Task {
            // Is it still there? If the host restarted it's gone, and the pane shows Resume instead.
            await store.refresh(host: rec.host)
            guard store.state.sessions[rec.key]?.ended == false else { return }
            store.embedded.session(rec.key)?.stop()
            do { _ = try await store.focus(key: rec.key) } catch { report(store, error) }
        }
    }

    static func resumeAll(_ store: SessionStore, host: String) {
        Task {
            let r = await store.resumeAllEnded(host: host)
            var parts = ["Resumed \(r.resumed.count) session\(r.resumed.count == 1 ? "" : "s") on \(store.hostLabel(host))"]
            if !r.skipped.isEmpty { parts.append("left \(r.skipped.joined(separator: ", ")) (no agent, or the same conversation as another)") }
            if !r.failed.isEmpty { parts.append("couldn't resume \(r.failed.joined(separator: ", ")); see the log") }
            store.banner = parts.joined(separator: "; ") + "."
        }
    }

    static func remove(_ store: SessionStore, _ rec: SessionRecord) {
        Task { do { try await store.kill(key: rec.key) } catch { report(store, error) } }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let n = store.waitingSessions.count
            if n > 0 {
                Button { Actions.nextWaiting(store) } label: {
                    Label("\(n) waiting for input — go to next (⌘J)", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(.orange)
            }
            ScrollView {
                SessionList(compact: true).padding(.trailing, 10)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 460)
            Divider()
            HStack {
                Button { activateApp(); openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                Spacer()
                Button { activateApp(); store.goHome(); openWindow(id: "main") } label: { Image(systemName: "macwindow") }
                    .help("Open window")
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Muxbar")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
    }
}

/// One window: sessions in a sidebar, the selected session's built-in terminal on the right.
struct MainWindow: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { store.sidebarVisibility }, set: { store.sidebarVisibility = $0 })) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
        } detail: {
            if store.settings.terminal == .embedded {
                if store.inGrid { GridPane() } else { DetailPane() }
            } else {
                ScrollView { SessionList(compact: false).padding(16) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.goHome() } label: { Label("Home", systemImage: "house") }
                    .help("Home: every session at a glance (⌘0)")
            }
            ToolbarItem {
                Button { openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                    .help("New session")
            }
            ToolbarItem {
                Button { store.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
            }
            ToolbarItem {
                if store.gridKeys.count >= 2 && store.settings.terminal == .embedded {
                    Picker("Layout", selection: Binding(get: { store.state.layout },
                                                        set: { v in if v != store.state.layout { store.toggleExpand() } })) {
                        Image(systemName: "rectangle").tag(PaneLayout.single).help("One session (⌘⏎)")
                        Image(systemName: "square.grid.2x2").tag(PaneLayout.grid).help("Grid (⌘⏎)")
                    }
                    .pickerStyle(.segmented)
                }
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,) — hosts, workspace folders, terminal")
            }
            ToolbarItem {
                let n = store.waitingSessions.count
                if n > 0 {
                    Button { Actions.nextWaiting(store) } label: {
                        Label("\(n) waiting", systemImage: "hand.raised.fill").labelStyle(.titleAndIcon)
                    }
                    .foregroundStyle(.orange)
                    .help("Go to the next session waiting for input (⌘J)")
                }
            }
        }
        .overlay { if store.switcherOpen { QuickSwitcherView() } }
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // List writes the selection back on redraws; only a *change* of selection may attach,
        // otherwise a redraw would reconnect a dropped session in a loop.
        List(selection: Binding(get: { store.selectedKey ?? (store.inGrid ? nil : "home") }, set: { raw in
            // Rows in "Needs input" are tagged "pin:<key>" so a session can appear twice.
            if raw == "home" { store.goHome(); return }
            let k = raw.map { $0.hasPrefix("pin:") ? String($0.dropFirst(4)) : $0 }
            guard k != store.selectedKey else { return }
            // ⌘-click: the session joins (or leaves) the grid instead.
            if let k, NSApp.currentEvent?.modifierFlags.contains(.command) == true, store.settings.terminal == .embedded {
                store.toggleInGrid(k); return
            }
            if let k, store.state.layout == .grid, store.gridKeys.contains(k) { store.focusTile(k); return }
            if store.state.layout == .grid { store.mutate { $0.layout = .single }; store.focusedTile = nil }
            if let k, let rec = store.state.sessions[k], !rec.ended { Actions.focus(store, rec) } else { store.select(k) }
        })) {
            if store.needsSetup {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.blue)
                    Text("Finish setting up Muxbar").font(.callout)
                    Spacer()
                    Button("Set Up…") { openWindow(id: "setup") }
                }
            }
            if let banner = store.banner {
                BannerView(text: banner, automation: store.automationDenied) { store.banner = nil }
            }
            HomeRow().tag("home")
            // Inbox: needs input first (longest waiting), then finished and unread (newest first).
            if !store.waitingSessions.isEmpty || !store.unreadFinished.isEmpty { InboxSection() }
            ForEach(store.state.hosts, id: \.self) { host in
                HostSection2(host: host)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.visible)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button { openWindow(id: "new") } label: {
                        Label("New Session", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Button { store.goHome() } label: { Image(systemName: "house") }
                        .buttonStyle(.bordered).help("Home: every session at a glance (⌘0)")
                    Menu {
                        Button { Actions.newGroup(store, host: nil) } label: { Label("New Group…", systemImage: "folder.badge.plus") }
                        Button { openWindow(id: "continue") } label: { Label("Continue Claude Session…", systemImage: "arrow.uturn.forward") }
                        Button { openWindow(id: "history") } label: { Label("Search History…", systemImage: "magnifyingglass") }
                        Divider()
                        SettingsLink { Label("Settings…", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    .help("More")
                }
            }
            .padding(10)
            .background(.bar)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Home" at the top of the sidebar: the session cards, and how many need you or are working.
struct HomeRow: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let open = store.state.hosts.flatMap { store.sessions(for: $0) }.filter { !$0.ended }
        let working = open.filter { store.presence(of: $0) == .working }.count
        HStack(spacing: 10) {
            Image(systemName: "house.fill").font(.system(size: 13)).foregroundStyle(.blue).frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.blue.opacity(0.14)))
            Text("Home").font(.system(size: 13, weight: .medium))
            Spacer()
            if working > 0 {
                Label("\(working)", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.blue)
                    .help("\(working) working")
            }
            Text("\(open.count)").font(.caption).foregroundStyle(.secondary).help("\(open.count) open sessions")
        }
        .padding(.vertical, 3)
        .help("Every session at a glance (⌘0)")
    }
}

/// Sessions that need you, then finished ones you haven't seen.
struct InboxSection: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let waiting = store.waitingSessions
        let finished = store.unreadFinished
        let all: [SessionRecord] = waiting + finished
        if !all.isEmpty {
            Section {
                ForEach(all) { rec in
                    let tag: String = "pin:" + rec.key
                    SidebarRow(rec: rec, location: store.location(of: rec), inInbox: true).tag(tag)
                }
            } header: {
                HStack(spacing: 7) {
                    Image(systemName: "tray.full.fill").foregroundStyle(waiting.isEmpty ? Color.blue : .orange)
                    Text("Inbox").font(.system(size: 11, weight: .bold)).textCase(.uppercase).tracking(0.4)
                    Spacer(minLength: 4)
                    if !waiting.isEmpty {
                        Label("\(waiting.count)", systemImage: "hand.raised.fill").labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                    }
                    if !finished.isEmpty {
                        Label("\(finished.count)", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                    }
                }
                .help("\(waiting.count) waiting for you, \(finished.count) finished and not seen yet · ⌘J goes to the next one")
                .contextMenu { Button("Mark All Read") { store.markAllRead() } }
            }
        }
    }
}

/// One host's part of the sidebar: its groups, ungrouped sessions, Others, ports and ended ones.
struct HostSection2: View {
    @EnvironmentObject var store: SessionStore
    var host: String

    var body: some View {
        Section {
            let health = store.health[host] ?? .unknown
            if let hint = health.hint, health != .ok {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // This host's groups (folders), then its ungrouped sessions.
            ForEach(store.state.groups(for: host), id: \.self) { g in
                GroupNode(host: host, group: g)
            }
            ForEach(store.ungroupedSessions(for: host).filter { !$0.ended }) { rec in
                SidebarRow(rec: rec).tag(rec.key)
            }
            let others = store.otherSessions(for: host)
            if !others.isEmpty { OthersNode(host: host, sessions: others) }
            if host != localHost && (!(store.hostPorts[host] ?? []).isEmpty || !(store.state.forwards[host] ?? []).isEmpty) {
                PortsNode(host: host)
            }
            let ended = store.sessions(for: host).filter { $0.ended && !$0.isOutside }
            if !ended.isEmpty { EndedNode(host: host, sessions: ended) }
        } header: {
            HostHeader(host: host)
                .dropDestination(for: String.self) { keys, _ in
                    // Dropping on the host header takes a session out of its group.
                    let ks = keys.filter { store.state.sessions[$0]?.host == host }
                    Task { for k in ks { do { try await store.setGroup(key: k, group: nil) } catch { Actions.report(store, error) } } }
                    return true
                }
                .contextMenu {
                    Button("New Session on \(store.hostLabel(host))…") { Actions.newSession(store, host: host, group: nil) }
                    Button("New Group on \(store.hostLabel(host))…") { Actions.newGroup(store, host: host) }
                    Divider()
                    Button("Mark All Read on \(store.hostLabel(host))") { store.markAllRead(host: host) }
                    Button("Sleep Idle Agents on \(store.hostLabel(host))") { Actions.sleepIdle(store, host: host) }
                }
        }
    }
}

/// A user group in the sidebar tree: a folder you can expand, drop sessions onto, rename, delete.
struct GroupNode: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    var group: String
    @StateObject private var ui = GroupNodeState()

    var body: some View {
        DisclosureGroup(isExpanded: $ui.expanded) {
            let members = store.sessions(inGroup: group, host: host).filter { !$0.ended }
            if members.isEmpty {
                Text("Drag \(store.hostLabel(host)) sessions here").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(members) { rec in
                SidebarRow(rec: rec).tag(rec.key)
            }
        } label: {
            HStack {
                let waitingN = store.waitingCount(group: group, host: host)
                let unreadN = store.unreadCount(group: group, host: host)
                Label {
                    Text(group)
                } icon: {
                    WaitingFolderIcon(waiting: waitingN > 0)
                }
                Spacer()
                if unreadN > 0 {
                    Text("\(unreadN)").font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.25))).foregroundStyle(.blue)
                        .help("\(unreadN) finished, not seen yet")
                }
                if waitingN > 0 {
                    Text("\(waitingN)").font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.3))).foregroundStyle(.orange)
                        .help("\(waitingN) waiting for input")
                }
                Text("\(store.sessions(inGroup: group, host: host).filter { !$0.ended }.count)").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { keys, _ in
                // Groups belong to one host: only that host's sessions can be dropped in.
                let own = keys.filter { store.state.sessions[$0]?.host == host }
                Task { for k in own { do { try await store.setGroup(key: k, group: group) } catch { Actions.report(store, error) } } }
                if !own.isEmpty { ui.expanded = true }
                return !own.isEmpty
            }
            .contextMenu {
                Button("New Session in “\(group)”…") { Actions.newSession(store, host: host, group: group) }
                Button("Show Group in Grid") {
                    store.showInGrid(store.sessions(inGroup: group, host: host).filter { !$0.ended }.map(\.key))
                }
                .disabled(store.sessions(inGroup: group, host: host).filter { !$0.ended }.count < 2)
                Divider()
                Button("Rename Group…") { Actions.renameGroup(store, host: host, group) }
                Button("Delete Group") { Actions.deleteGroup(store, host: host, group) }
            }
        }
    }
}

@MainActor
final class GroupNodeState: ObservableObject {
    @Published var expanded = true
}

struct HostHeader: View {
    @EnvironmentObject var store: SessionStore
    var host: String

    var body: some View {
        let health = store.health[host] ?? .unknown
        HStack(spacing: 7) {
            Circle().fill(health == .ok ? Color.green : (health == .unknown ? Color.secondary.opacity(0.5) : Color.orange))
                .frame(width: 6, height: 6)
                .help(health == .ok ? "Connected" : health.label)
            Text(host == localHost ? "This Mac" : host)
                .font(.system(size: 11, weight: .bold)).textCase(.uppercase).tracking(0.4)
            if health != .ok && health != .unknown {
                Text(health.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if let m = store.hostMemory[host] {
                MemoryChip(host: host, mem: m)
            }
        }
    }
}

/// A host's ended sessions, folded away under one line, with Resume all and Clear.
struct EndedNode: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    var sessions: [SessionRecord]
    @StateObject private var ui = PortsNodeModel()

    var body: some View {
        DisclosureGroup(isExpanded: $ui.expanded) {
            ForEach(sessions.sorted { $0.name < $1.name }) { rec in
                SidebarRow(rec: rec).tag(rec.key)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Ended").foregroundStyle(.secondary)
                Text("\(sessions.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if sessions.contains(where: { $0.agent != nil }) {
                    Button("Resume all") { Actions.resumeAll(store, host: host) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Resume every ended Claude/Codex session here, each in its own conversation")
                }
                Button("Clear") { store.dismissEnded(host: host) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .help("Remove the ended sessions from the list")
            }
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var hover = HoverState()
    var rec: SessionRecord
    /// Where the session lives ("devbox · API"); shown in the Inbox.
    var location: String? = nil
    var inInbox = false

    var body: some View {
        let p = store.presence(of: rec)
        let waiting = p == .waiting
        let unread = p == .done
        HStack(spacing: 10) {
            AgentBadge(kind: store.agentKind(of: rec), presence: p, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(rec.name).lineLimit(1)
                        .font(.system(size: 13, weight: waiting || unread ? .semibold : .medium))
                        .foregroundStyle(rec.ended ? .secondary : .primary)
                    if unread { Circle().fill(Color.blue).frame(width: 6, height: 6).help("Finished — not seen yet") }
                }
                Text(inInbox && rec.host != localHost ? "\(store.hostLabel(rec.host)) · \(store.activity(of: rec))" : store.activity(of: rec))
                    .font(.system(size: 11))
                    .foregroundStyle(waiting ? Color.orange : .secondary)
                    .lineLimit(1)
                    .help(store.activity(of: rec))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                if p.isNotable && !(hover.on && !rec.ended) { StatusPill(presence: p, iconOnly: true) }
                if let kb = store.live[rec.key]?.memoryKB, kb >= 1_048_576, !rec.ended, !hover.on {
                    Text(formatKB(kb)).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(kb >= 8 * 1_048_576 ? Color.orange : .secondary)
                        .help("Memory used by this session's processes")
                }
            }
            if !rec.ended && (hover.on || store.selectedKey == rec.key) && hover.on {
                Menu {
                    Button("Close Pane (keeps running)") { store.closePane(key: rec.key) }
                        .disabled(store.embedded.session(rec.key) == nil)
                    Button("Kill Session…", role: .destructive) { Actions.kill(store, rec) }
                } label: { Image(systemName: "ellipsis.circle.fill").foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Close the pane or kill the session")
            }
        }
        .onHover { hover.on = $0 }
        .padding(.vertical, 4).padding(.horizontal, 2)
        .modifier(DraggableUnlessOutside(rec: rec))
        .contextMenu {
            if rec.isOutside {
                Text("Started outside Muxbar — stays in Others")
            } else {
            Menu("Move to Group") {
                let groups = store.state.groups(for: rec.host)
                ForEach(groups, id: \.self) { g in
                    Button(g) { Actions.setGroup(store, rec, g) }.disabled(rec.group == g)
                }
                if !groups.isEmpty { Divider() }
                Button("New Group on \(store.hostLabel(rec.host))…") { Actions.newGroup(store, host: rec.host, moving: rec) }
                if rec.group != nil {
                    Button("Remove from Group") { Actions.setGroup(store, rec, nil) }
                }
            }
            }
            Divider()
            if !rec.ended {
                if rec.unread {
                    Button("Mark as Read") { store.setUnread(rec.key, false) }
                } else {
                    Button("Mark as Unread") { store.setUnread(rec.key, true) }
                }
                if rec.sleep != nil {
                    Button("Wake Agent") { Actions.wake(store, rec) }
                } else if store.live[rec.key]?.agent != nil {
                    Button("Sleep Agent (frees ~\(formatKB(store.live[rec.key]?.memoryKB ?? 0)))") { Actions.sleep(store, rec) }
                        .disabled(store.status(of: rec) != .idle)
                }
                Toggle("Never Sleep", isOn: Binding(get: { rec.neverSleep },
                                                    set: { v in store.mutate { $0.sessions[rec.key]?.neverSleep = v } }))
                if store.settings.terminal == .embedded {
                    if store.state.layout == .grid && store.gridKeys.contains(rec.key) {
                        Button("Remove from Grid") { store.removeFromGrid(rec.key) }
                    } else {
                        Button("Add to Grid (⌘-click)") { store.toggleInGrid(rec.key) }
                    }
                }
                Button("Rename…") { Actions.rename(store, rec) }
                Button("Reconnect") { Actions.reconnect(store, rec) }
                Button("Close Pane (keeps running)") { store.closePane(key: rec.key) }
                    .disabled(store.embedded.session(rec.key) == nil)
                Divider()
                Button("Kill Session…", role: .destructive) { Actions.kill(store, rec) }
            } else {
                Button("Resume Session") { Actions.resumeEnded(store, rec) }
                Button("Remove from list") { Actions.remove(store, rec) }
            }
        }
    }
}

/// Host memory in the host header ("26/31 GB"), coloured by level; click for details.
struct MemoryChip: View {
    @EnvironmentObject var store: SessionStore
    let host: String
    let mem: HostMemory

    var body: some View {
        let level = store.memoryLevel(host)
        let color: Color = level == .critical ? .red : (level == .warn ? .orange : .secondary)
        Button {
            store.memoryPopoverHost = host
        } label: {
            MemoryBar(mem: mem, level: level, width: 30)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(level == .normal ? 0 : 0.15)))
        }
        .buttonStyle(.plain)
        .help("Memory: \(Int(mem.usedPercent))% used — click for the biggest sessions and processes")
        .popover(isPresented: Binding(get: { store.memoryPopoverHost == host },
                                      set: { if !$0 && store.memoryPopoverHost == host { store.memoryPopoverHost = nil } })) {
            MemoryPopover(host: host).environmentObject(store)
        }
    }
}

struct MemoryPopover: View {
    @EnvironmentObject var store: SessionStore
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(store.hostLabel(host)) memory").font(.headline)
            if let m = store.hostMemory[host] {
                let level = store.memoryLevel(host)
                ProgressView(value: min(100, m.usedPercent), total: 100)
                    .tint(level == .critical ? .red : (level == .warn ? .orange : .accentColor))
                Text("\(formatKB(m.usedKB)) of \(formatKB(m.totalKB)) used (\(Int(m.usedPercent))%)"
                     + (m.swapTotalKB > 0 ? " · swap \(formatKB(m.swapTotalKB - m.swapFreeKB)) used" : " · no swap")
                     + (m.load.first.map { String(format: " · load %.1f", $0) } ?? "") + (m.cpus > 0 ? " (\(m.cpus) CPUs)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let recs = store.sessions(for: host).filter { !$0.ended && (store.live[$0.key]?.memoryKB ?? 0) > 0 }
                .sorted { (store.live[$0.key]?.memoryKB ?? 0) > (store.live[$1.key]?.memoryKB ?? 0) }.prefix(8)
            if !recs.isEmpty {
                Text("Sessions").font(.subheadline.weight(.semibold))
                ForEach(Array(recs)) { r in
                    HStack {
                        Text(r.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(formatKB(store.live[r.key]?.memoryKB ?? 0)).font(.caption.monospacedDigit())
                    }
                }
            }
            let cand = store.sleepCandidates(host: host)
            if cand.count > 0 {
                Button("Sleep \(cand.count) idle agent session\(cand.count == 1 ? "" : "s") (~\(formatKB(cand.kb)))") {
                    Actions.sleepIdle(store, host: host)
                }
                .help("Exits idle agents (their conversations resume when you open the session again)")
            }
            Text("Processes").font(.subheadline.weight(.semibold))
            let top = (store.topProcesses[host] ?? []).prefix(8)
            if top.isEmpty { Text("Loading…").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(top), id: \.pid) { p in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.shortName).font(.caption).lineLimit(1)
                        Text(p.pane.flatMap { store.session(host: host, pane: $0)?.name } ?? "pid \(p.pid)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(formatKB(p.rssKB)).font(.caption.monospacedDigit())
                    Button("Stop…") { confirmStop(p) }.controlSize(.small)
                }
                .help(p.args)
            }
        }
        .padding(12)
        .frame(width: 380)
        .task { await store.fetchTopProcesses(host) }
    }

    func confirmStop(_ p: ProcessUsage) {
        let alert = NSAlert()
        alert.messageText = "Stop \(p.shortName) (pid \(p.pid)) on \(store.hostLabel(host))?"
        alert.informativeText = "Muxbar sends it SIGTERM, so it can clean up and exit. It uses \(formatKB(p.rssKB)).\n\n\(p.args.prefix(300))"
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await store.stopProcess(host: host, pid: p.pid) } catch { Actions.report(store, error) } }
    }
}

extension SidebarRow {
    func subtitle(status: SessionStatus, waiting: Bool, unread: Bool) -> String {
        if rec.ended { return "ended" }
        if let s = rec.sleep { return "Sleeping · freed \(formatKB(s.freedKB))" }
        if waiting { return "Needs input · \(location ?? relativeAge(rec.lastActivity))" }
        if unread {
            let when = timeAgo(rec.finishedAt ?? rec.lastActivity ?? Int(Date().timeIntervalSince1970))
            return inInbox ? "Finished \(when) · \(location ?? "")" : "Finished · \(when)"
        }
        return "\(status.label) · \(relativeAge(rec.lastActivity))"
    }
}

struct DetailPane: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let key = store.selectedKey, let rec = store.state.sessions[key] {
            VStack(spacing: 0) {
                DetailHeader(rec: rec)
                Divider()
                if rec.ended {
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("This session has ended").font(.headline)
                        Text("Its tmux session is gone (for example after a restart). Resume recreates it in \(rec.managedDir ?? rec.path ?? "~") and continues Claude there.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("Resume Session") { Actions.resumeEnded(store, rec) }.keyboardShortcut(.defaultAction)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pane = store.embedded.session(key) {
                    if let p = store.dropProgress {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(p).font(.callout); Spacer() }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        Divider()
                    }
                    if let sl = rec.sleep {
                        HStack(spacing: 8) {
                            Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                            Text("\(sl.agent.displayName) is asleep (freed \(formatKB(sl.freedKB)) · \(timeAgo(sl.sleptAt))). Waking resumes the same conversation.")
                                .font(.callout).lineLimit(2)
                            Spacer()
                            Button("Wake") { Actions.wake(store, rec) }.keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.indigo.opacity(0.12))
                        Divider()
                    }
                    PaneView(pane: pane, rec: rec)
                } else {
                    placeholder("Connecting…", systemImage: "network")
                }
            }
        } else {
            HomeDashboard()
        }
    }

    func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailHeader: View {
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord

    var body: some View {
        let p = store.presence(of: rec)
        VStack(spacing: 0) {
            // A thin line in the status colour along the top: a waiting session reads from across the room.
            Rectangle().fill(p.isNotable ? p.color : Color.clear).frame(height: 2)
            HStack(spacing: 10) {
                AgentBadge(kind: store.agentKind(of: rec), presence: p, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(rec.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        StatusPill(presence: p, compact: true)
                    }
                    Text(store.activity(of: rec)).font(.caption)
                        .foregroundStyle(p == .waiting ? Color.orange : .secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                FolderChip(rec: rec)
                if !rec.ended {
                    HStack(spacing: 2) {
                        if rec.sleep != nil {
                            iconButton("sun.max", "Wake the agent") { Actions.wake(store, rec) }
                        } else if store.agentKind(of: rec) != nil {
                            iconButton("moon.zzz", "Sleep the agent (frees ~\(formatKB(store.live[rec.key]?.memoryKB ?? 0)))") { Actions.sleep(store, rec) }
                                .disabled(store.status(of: rec) != .idle)
                        }
                        if store.settings.terminal == .embedded {
                            iconButton(store.gridKeys.contains(rec.key) ? "square.grid.2x2.fill" : "square.grid.2x2",
                                       store.gridKeys.contains(rec.key) ? "Remove from the grid" : "Add to the grid (⌘-click in the list)") {
                                if store.gridKeys.contains(rec.key) { store.removeFromGrid(rec.key) } else { store.toggleInGrid(rec.key) }
                            }
                        }
                        iconButton("pencil", "Rename") { Actions.rename(store, rec) }
                        iconButton("trash", "Kill session") { Actions.kill(store, rec) }
                    }
                } else {
                    Button("Resume") { Actions.resumeEnded(store, rec) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .background(p == .waiting ? Color.orange.opacity(0.06) : Color.clear)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// Observes one pane so a disconnect shows the reconnect overlay immediately.
struct PaneView: View {
    @ObservedObject var pane: EmbeddedSession
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord
    /// Only the pane on screen alone, or the focused grid tile, takes the keyboard.
    var takeFocus = true
    var tile = false

    var body: some View {
        ZStack(alignment: .trailing) {
            TerminalPaneHost(pane: pane, generation: pane.starts, takeFocus: takeFocus, tile: tile) {
                // A click in a grid tile focuses that tile.
                if store.state.layout == .grid, store.gridKeys.contains(rec.key), store.focusedTile != rec.key { store.focusTile(rec.key) }
            }
                .padding(.trailing, rec.tmuxID != nil ? 14 : 0)
                .padding(.leading, 6).padding(.top, 4)
            if rec.tmuxID != nil, pane.isRunning {
                HistoryScrollBar(key: rec.key)
            }
            if case .exited(let code) = pane.state {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 30))
                    Text("Disconnected\(code.map { " (exit \($0))" } ?? "")").font(.headline)
                    Text(rec.isPlainTab ? "The command ended." : "The connection to \(rec.host == localHost ? "this Mac's" : rec.host + "'s") tmux session closed. Reconnect checks it's still there first.")
                        .foregroundStyle(.secondary)
                    Button("Reconnect") { Actions.reconnect(store, rec) }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            }
        }
    }
}

/// Hosts the session's SwiftTerm view. The view is owned by EmbeddedSession, so switching
/// sessions or closing the window never kills the attach.
struct TerminalPaneHost: NSViewRepresentable {
    let pane: EmbeddedSession
    var generation: Int
    var takeFocus = true
    var tile = false
    var onClick: () -> Void = {}

    /// Remembers the single-view size, so panes leaving the grid can get it back (tmux sizes each
    /// window to its pane).
    final class PaneContainer: NSView {
        @MainActor static var lastSingleSize: NSSize?
        var tile = false
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if !tile && newSize.width > 100 && newSize.height > 60 { PaneContainer.lastSingleSize = newSize }
        }

        /// The terminal is always exactly the container. (Autoresizing adds size deltas: a view that
        /// kept its old size while this container was still empty would end up larger than it.)
        override func resizeSubviews(withOldSize oldSize: NSSize) {
            for v in subviews { v.frame = bounds }
        }
    }

    final class Coordinator: NSObject {
        var onClick: () -> Void = {}
        @objc func clicked() { onClick() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = PaneContainer()
        container.tile = tile
        container.wantsLayer = true
        // Sees clicks anywhere in the terminal without delaying them (SwiftTerm's own mouse
        // handling and focus aren't overridable).
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked))
        click.delaysPrimaryMouseButtonEvents = false
        container.addGestureRecognizer(click)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.onClick = onClick
        (container as? PaneContainer)?.tile = tile
        let term = pane.view
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.autoresizingMask = []
            term.frame = container.bounds   // ignored by the view while the container is still empty
            container.addSubview(term)
        }
        // A view has one superview: moving it into this container takes it out of the old one
        // (single view ↔ grid tile), and the attach keeps running.
        guard takeFocus else { return }
        DispatchQueue.main.async { if term.window?.firstResponder !== term { term.window?.makeFirstResponder(term) } }
    }
}

/// Folder field with a picker: the standard folder dialog for this Mac; recent folders for a
/// remote host (a Mac dialog can't browse a remote filesystem).
struct FolderField: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    @Binding var path: String
    var extra: [String] = []

    var body: some View {
        HStack(spacing: 6) {
            TextField("Folder", text: $path, prompt: Text("~/src/project"))
                .labelsHidden()   // the caller supplies the label
            if host == localHost {
                Button { pick() } label: { Image(systemName: "folder") }
                    .help("Choose a folder")
            }
            let recents = Array(NSOrderedSet(array: (store.state.recentDirs[host] ?? []) + extra).compactMap { $0 as? String }.prefix(15))
            if !recents.isEmpty {
                Menu {
                    ForEach(recents, id: \.self) { d in Button(d) { path = d } }
                } label: { Image(systemName: host == localHost ? "clock" : "folder") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(host == localHost ? "Recent folders" : "Recent folders on \(host)")
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true   // "New Folder" in the panel
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let start = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: start) { panel.directoryURL = URL(fileURLWithPath: start) }
        activateApp()
        if panel.runModal() == .OK, let url = panel.url {
            let home = NSHomeDirectory()
            path = url.path.hasPrefix(home + "/") ? "~/" + url.path.dropFirst(home.count + 1) : url.path
        }
    }
}

/// Status dot; pulses while the session waits for input (static with Reduce Motion).
struct StatusDot: View {
    var status: SessionStatus
    @StateObject private var pulse = PulseState()

    var body: some View {
        ZStack {
            if status == .waiting {
                Circle().stroke(Color.orange, lineWidth: 2)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse.on ? 2.1 : 1)
                    .opacity(pulse.on ? 0 : 0.8)
            }
            Circle().fill(status.color)
                .overlay(Circle().stroke(Color.secondary.opacity(status == .ended ? 0.6 : 0), lineWidth: 1))
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .help(status.label)
        .onAppear { pulse.set(status == .waiting) }
        .onChange(of: status) { _, s in pulse.set(s == .waiting) }
    }
}

@MainActor
final class PulseState: ObservableObject {
    @Published var on = false
    func set(_ active: Bool) {
        guard active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            withAnimation(.default) { on = false }; return
        }
        on = false
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true }
    }
}

/// Folder icon that pulses orange while a session inside it waits for input.
struct WaitingFolderIcon: View {
    var waiting: Bool
    @StateObject private var pulse = PulseState()

    var body: some View {
        Image(systemName: waiting ? "folder.fill" : "folder")
            .foregroundStyle(waiting ? Color.orange : Color.secondary)
            .opacity(waiting && pulse.on ? 0.45 : 1)
            .onAppear { pulse.set(waiting) }
            .onChange(of: waiting) { _, w in pulse.set(w) }
    }
}

/// Sessions started outside Muxbar: shown together, fixed in place (no moving in or out).
struct OthersNode: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    var sessions: [SessionRecord]
    @StateObject private var ui = GroupNodeState()

    var body: some View {
        DisclosureGroup(isExpanded: $ui.expanded) {
            ForEach(sessions) { rec in SidebarRow(rec: rec).tag(rec.key) }
        } label: {
            HStack {
                let waitingN = sessions.filter { store.status(of: $0) == .waiting }.count
                Label("Others", systemImage: waitingN > 0 ? "tray.full.fill" : "tray")
                    .foregroundStyle(waitingN > 0 ? Color.orange : .secondary)
                    .help("Sessions started outside Muxbar. They stay here and can't be moved into groups.")
                Spacer()
                if waitingN > 0 {
                    Text("\(waitingN)").font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.3))).foregroundStyle(.orange)
                }
                Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Only Muxbar sessions can be dragged into groups; Others stay put.
struct DraggableUnlessOutside: ViewModifier {
    var rec: SessionRecord
    func body(content: Content) -> some View {
        if rec.isOutside { content } else { content.draggable(rec.key) }
    }
}

/// Scroll bar for a session's history. The history lives in tmux (the pane shows tmux's screen),
/// so the bar reads and drives tmux copy mode: drag, click above/below the thumb to page, or use
/// the wheel/trackpad over the pane. "Live" returns to the bottom.
struct HistoryScrollBar: View {
    @EnvironmentObject var store: SessionStore
    var key: String
    @StateObject private var poll = ScrollPoller()
    @StateObject private var drag = DragState()

    var body: some View {
        let info = store.scrollInfo[key]
        Group {
            if let info, !info.usesTmuxHistory {
                AppPageBar(key: key, active: info.alternate)
            } else {
                tmuxHistoryBar(info)
            }
        }
        .onAppear { poll.start(store: store, key: key) }
        .onDisappear { poll.stop() }
    }

    @ViewBuilder
    private func tmuxHistoryBar(_ info: TmuxScrollInfo?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geo in
                let h = geo.size.height
                let top = (info?.thumbTop ?? 1) * h
                let th = max(24, (info?.thumbHeight ?? 1) * h)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(drag.active ? 0.55 : 0.35))
                        .frame(height: min(th, h))
                        .offset(y: min(max(0, top), h - min(th, h)))
                }
                .frame(width: 10)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let info else { return }
                        if !drag.active {
                            drag.active = true
                            let inThumb = g.startLocation.y >= top && g.startLocation.y <= top + th
                            if !inThumb {
                                // Click on the track: page up/down by a screen.
                                let page = max(1, info.height - 2)
                                store.scrollPane(key, lines: g.startLocation.y < top ? page : -page)
                                drag.paging = true
                                return
                            }
                            drag.grab = g.startLocation.y - top
                        }
                        guard !drag.paging else { return }
                        let f = Double((g.location.y - drag.grab) / h)
                        store.scrollPane(key, toPosition: info.position(forThumbTop: f))
                    }
                    .onEnded { _ in drag.active = false; drag.paging = false })
                .help("Scroll back through this session's history")
            }
            .frame(width: 10)
            .padding(.vertical, 4).padding(.trailing, 2)
            if let info, !info.atLive {
                Button { store.scrollPane(key, toPosition: 0) } label: {
                    Label("Live", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .padding(.trailing, 20).padding(.bottom, 10)
                .help("Back to live output (typing does this too)")
            }
        }
    }
}

/// For full-screen apps (Claude Code, less, vim) the history lives inside the app, which doesn't
/// report a position, so the bar pages instead: ▲ / ▼ or click the upper / lower half.
struct AppPageBar: View {
    @EnvironmentObject var store: SessionStore
    var key: String
    var active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Button { store.scrollPages(key, 1) } label: { Image(systemName: "chevron.up") }
                .help("Page up (sends Page Up to the app)")
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(active ? 0.08 : 0.03))
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        store.scrollPages(key, p.y < geo.size.height / 2 ? 1 : -1)
                    }
            }
            .frame(width: 10)
            Button { store.scrollPages(key, -1) } label: { Image(systemName: "chevron.down") }
                .help("Page down")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 9, weight: .bold))
        .frame(width: 14)
        .padding(.vertical, 4)
        .disabled(!active)
        .help(active ? "Scroll this app's own history (wheel/trackpad works too)" : "Nothing to scroll yet")
    }
}

@MainActor
final class DragState: ObservableObject {
    @Published var active = false
    var grab: CGFloat = 0
    var paging = false
}

/// Keeps the scroll bar in step with output (history grows) while the pane is visible.
@MainActor
final class ScrollPoller: ObservableObject {
    private var timer: Timer?
    func start(store: SessionStore, key: String) {
        stop()
        Task<Void, Never> { await store.refreshScrollInfo(key) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { _ = Task<Void, Never> { await store.refreshScrollInfo(key) } }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

@MainActor
final class HoverState: ObservableObject { @Published var on = false }

/// F8: a host's listening ports (collapsed), each forwardable to localhost on this Mac.
struct PortsNode: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    @StateObject private var ui = PortsNodeModel()

    var body: some View {
        let rows = store.portRows(host)
        let fwd = rows.filter { $0.forward != nil }.count
        DisclosureGroup(isExpanded: $ui.expanded) {
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Text(verbatim: "\(r.remote)").font(.callout.monospacedDigit())
                    Text([r.port?.process, r.owner?.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = r.forward {
                        Text(verbatim: "→ :\(f.local)").font(.caption.monospacedDigit())
                        Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(f.local)/")!) }
                            .disabled(!r.listening)
                        Button("Stop") { Task { do { try await store.unforward(host: host, port: r.remote) } catch { Actions.report(store, error) } } }
                    } else {
                        Button("Forward") { Task { do { try await store.forward(host: host, port: r.remote) } catch { Actions.report(store, error) } } }
                    }
                }
                .buttonStyle(.borderless)
                .opacity(r.listening ? 1 : 0.45)
                .help(r.listening ? "localhost on this Mac only" : "Not listening right now; the forward stays until you stop it")
            }
        } label: {
            Label(fwd > 0 ? "Ports (\(rows.count), \(fwd) forwarded)" : "Ports (\(rows.count))", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class PortsNodeModel: ObservableObject { @Published var expanded = false }
