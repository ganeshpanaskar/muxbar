import AppKit
import MuxbarCore
import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .idle, .running: return .green
        case .notAgent, .notRunning: return .gray
        case .unknown: return .secondary.opacity(0.5)
        case .ended: return .clear
        }
    }
}

func relativeAge(_ epoch: Int?) -> String {
    guard let epoch, epoch > 0 else { return "" }
    let s = max(0, Int(Date().timeIntervalSince1970) - epoch)
    if s < 60 { return "active just now" }
    if s < 3600 { return "active \(s / 60)m ago" }
    if s < 86400 { return "active \(s / 3600)h ago" }
    return "active \(s / 86400)d ago"
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
            : "This runs tmux kill-session \(rec.tmuxID ?? "") on \(where_). Anything running in it (including any agent) stops. This can't be undone."
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

    static func setGroup(_ store: SessionStore, _ rec: SessionRecord, _ g: String?) {
        Task { do { try await store.setGroup(key: rec.key, group: g) } catch { report(store, error) } }
    }

    static func nextWaiting(_ store: SessionStore) {
        Task { do { _ = try await store.focusNextWaiting() } catch { report(store, error) } }
    }

    static func reconnect(_ store: SessionStore, _ rec: SessionRecord) {
        store.embedded.session(rec.key)?.stop()
        Task { do { _ = try await store.focus(key: rec.key) } catch { report(store, error) } }
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
                Button { activateApp(); openWindow(id: "main") } label: { Image(systemName: "macwindow") }
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
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            if store.settings.terminal == .embedded {
                DetailPane()
            } else {
                ScrollView { SessionList(compact: false).padding(16) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                    .help("New session")
            }
            ToolbarItem {
                Button { store.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
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
        List(selection: Binding(get: { store.selectedKey }, set: { raw in
            // Rows in "Needs input" are tagged "pin:<key>" so a session can appear twice.
            let k = raw.map { $0.hasPrefix("pin:") ? String($0.dropFirst(4)) : $0 }
            guard k != store.selectedKey else { return }
            if let k, let rec = store.state.sessions[k], !rec.ended { Actions.focus(store, rec) } else { store.select(k) }
        })) {
            if let banner = store.banner {
                BannerView(text: banner, automation: store.automationDenied) { store.banner = nil }
            }
            let waiting = store.waitingSessions
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { rec in
                        SidebarRow(rec: rec, location: store.location(of: rec)).tag("pin:" + rec.key)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        Text("Needs input").foregroundStyle(.orange)
                        Text("\(waiting.count)").font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.25))).foregroundStyle(.orange)
                        Spacer()
                        Text("⌘J next").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(store.state.hosts, id: \.self) { host in
                Section {
                    let health = store.health[host] ?? .unknown
                    if let hint = health.hint, health != .ok {
                        Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // This host's groups (folders), then its ungrouped sessions.
                    ForEach(store.state.groups(for: host), id: \.self) { g in
                        GroupNode(host: host, group: g)
                    }
                    ForEach(store.ungroupedSessions(for: host)) { rec in
                        SidebarRow(rec: rec).tag(rec.key)
                    }
                    let others = store.otherSessions(for: host)
                    if !others.isEmpty { OthersNode(host: host, sessions: others) }
                } header: {
                    HostHeader(host: host)
                        .dropDestination(for: String.self) { keys, _ in
                            // Dropping on the host header takes a session out of its group.
                            let ks = keys.filter { store.state.sessions[$0]?.host == host }
                            Task { for k in ks { do { try await store.setGroup(key: k, group: nil) } catch { Actions.report(store, error) } } }
                            return true
                        }
                        .contextMenu {
                            Button("New Group on \(store.hostLabel(host))…") { Actions.newGroup(store, host: host) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.visible)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button { openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                Button { Actions.newGroup(store, host: nil) } label: { Label("New Group", systemImage: "folder.badge.plus") }
                Button { openWindow(id: "continue") } label: { Label("Continue Agent Session…", systemImage: "arrow.uturn.forward") }
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            let members = store.sessions(inGroup: group, host: host)
            if members.isEmpty {
                Text("Drag \(store.hostLabel(host)) sessions here").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(members) { rec in
                SidebarRow(rec: rec).tag(rec.key)
            }
        } label: {
            HStack {
                let waitingN = store.waitingCount(group: group, host: host)
                Label {
                    Text(group)
                } icon: {
                    WaitingFolderIcon(waiting: waitingN > 0)
                }
                Spacer()
                if waitingN > 0 {
                    Text("\(waitingN)").font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.3))).foregroundStyle(.orange)
                        .help("\(waitingN) waiting for input")
                }
                Text("\(store.sessions(inGroup: group, host: host).count)").font(.caption).foregroundStyle(.secondary)
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
        HStack(spacing: 6) {
            Text(host == localHost ? "This Mac" : host)
            let waitingCount = store.sessions(for: host).filter { store.status(of: $0) == .waiting }.count
            if waitingCount > 0 {
                Text("\(waitingCount) waiting").font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .foregroundStyle(.orange)
            }
            if health != .ok {
                Text(health.label).font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
            }
            Spacer()
            if store.sessions(for: host).contains(where: \.ended) {
                Button("Clear ended") { store.dismissEnded(host: host) }.buttonStyle(.borderless).font(.caption2)
            }
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord
    /// Where the session lives ("devbox · api"); shown in the pinned Needs input section.
    var location: String? = nil

    var body: some View {
        let status = store.status(of: rec)
        let waiting = status == .waiting
        HStack(spacing: 8) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name).lineLimit(1).foregroundStyle(rec.ended ? .secondary : .primary)
                    .fontWeight(waiting ? .semibold : .regular)
                Text(rec.ended ? "ended" : (waiting ? "Needs input · \(location ?? relativeAge(rec.lastActivity))" : "\(status.label) · \(relativeAge(rec.lastActivity))"))
                    .font(.caption).foregroundStyle(waiting ? Color.orange : .secondary).lineLimit(1)
                    .fontWeight(waiting ? .semibold : .regular)
            }
            Spacer(minLength: 0)
            if waiting { Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange).help("Waiting for your input") }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(waiting ? 0.16 : 0)))
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
                Button("Rename…") { Actions.rename(store, rec) }
                Button("Reconnect") { Actions.reconnect(store, rec) }
                Divider()
                Button("Kill Session…", role: .destructive) { Actions.kill(store, rec) }
            } else {
                Button("Resume Session") { Actions.resumeEnded(store, rec) }
                Button("Remove from list") { Actions.remove(store, rec) }
            }
        }
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
                        Text("Its tmux session is gone (for example after a restart). Resume recreates it in \(rec.managedDir ?? rec.path ?? "~") and continues its agent there.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("Resume Session") { Actions.resumeEnded(store, rec) }.keyboardShortcut(.defaultAction)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pane = store.embedded.session(key) {
                    PaneView(pane: pane, rec: rec)
                } else {
                    placeholder("Connecting…", systemImage: "network")
                }
            }
        } else {
            VStack(spacing: 14) {
                LaunchAnimationView(dark: colorScheme == .dark)
                    .frame(width: 220, height: 220)
                Text("Muxbar").font(.title2).fontWeight(.semibold)
                Text("Select a session, or create one with +.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let status = store.status(of: rec)
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 9, height: 9)
            Text(rec.name).font(.headline)
            Text("· \(rec.host == localHost ? "This Mac" : rec.host)").foregroundStyle(.secondary)
            if let p = rec.path { Text("· \(p)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            Spacer()
            Text(status.label).font(.caption).foregroundStyle(.secondary)
            if !rec.ended {
                Button { Actions.rename(store, rec) } label: { Image(systemName: "pencil") }.help("Rename")
                Button { Actions.kill(store, rec) } label: { Image(systemName: "trash") }.help("Kill session")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

/// Observes one pane so a disconnect shows the reconnect overlay immediately.
struct PaneView: View {
    @ObservedObject var pane: EmbeddedSession
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord

    var body: some View {
        ZStack(alignment: .trailing) {
            TerminalPaneHost(pane: pane, generation: pane.starts)
                .padding(.trailing, rec.tmuxID != nil ? HistoryScrollBar.width + 4 : 0)
            if rec.tmuxID != nil, pane.isRunning {
                HistoryScrollBar(key: rec.key)
            }
            if case .exited(let code) = pane.state {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 30))
                    Text("Disconnected\(code.map { " (exit \($0))" } ?? "")").font(.headline)
                    Text(rec.isPlainTab ? "The command ended." : "The tmux session is still running on \(rec.host == localHost ? "this Mac" : rec.host).")
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

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let term = pane.view
        if term.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            term.frame = container.bounds
            term.autoresizingMask = [.width, .height]
            container.addSubview(term)
        }
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
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
            TextField("Folder", text: $path, prompt: Text(host == localHost ? "~/src/project" : "~/src/project"))
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

/// Scroll bar for a session's history. Normally the history lives in tmux (the pane shows tmux's
/// screen), so the bar reads and drives tmux copy mode: drag, click above/below the thumb to page,
/// or use the wheel/trackpad over the pane. "Live" returns to the bottom.
/// A full-screen app (e.g. Claude Code's full-screen UI) keeps its own history, so the bar turns
/// into a scroll strip that sends scrolling to the app: ▲/▼ or click to page, drag to scroll.
struct HistoryScrollBar: View {
    @EnvironmentObject var store: SessionStore
    var key: String
    @StateObject private var poll = ScrollPoller()
    @StateObject private var drag = DragState()
    @State private var hover = false

    static let width: CGFloat = 12

    var body: some View {
        let info = store.scrollInfo[key]
        ZStack(alignment: .bottomTrailing) {
            Group {
                if info?.fullscreen == true { appStrip(info!) } else { historyBar(info) }
            }
            .frame(width: Self.width)
            .padding(.vertical, 4).padding(.trailing, 2)
            .onHover { hover = $0 }
            if let info, !info.fullscreen, !info.atLive {
                Button { store.scrollPane(key, toPosition: 0) } label: {
                    Label("Live", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .padding(.trailing, 22).padding(.bottom, 10)
                .help("Back to live output (typing does this too)")
            }
        }
        .onAppear { poll.start(store: store, key: key) }
        .onDisappear { poll.stop() }
    }

    private var trackFill: Color { Color.primary.opacity(hover || drag.active ? 0.14 : 0.08) }

    /// tmux history: a real thumb sized and placed by history length and position.
    private func historyBar(_ info: TmuxScrollInfo?) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let top = (info?.thumbTop ?? 1) * h
            let th = max(28, (info?.thumbHeight ?? 1) * h)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(trackFill)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(drag.active ? 0.6 : (hover ? 0.5 : 0.4)))
                    .frame(height: min(th, h))
                    .offset(y: min(max(0, top), h - min(th, h)))
            }
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
            .help(info.map { $0.history == 0 ? "No scrollback yet" : "Scroll back through \($0.history) lines of history" }
                  ?? "Scroll back through this session's history")
        }
    }

    /// Full-screen app: the app owns its history and position, so there's no thumb — ▲/▼ page,
    /// clicking the upper/lower half pages, and dragging scrolls by the distance moved.
    private func appStrip(_ info: TmuxScrollInfo) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                    .frame(width: Self.width, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { store.scrollPane(key, pages: 1) }
                Spacer(minLength: 0)
                Capsule().fill(Color.primary.opacity(drag.active ? 0.6 : (hover ? 0.5 : 0.35)))
                    .frame(width: 4, height: min(48, max(16, h / 6)))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .frame(width: Self.width, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { store.scrollPane(key, pages: -1) }
            }
            .foregroundStyle(Color.primary.opacity(hover ? 0.75 : 0.5))
            .background(RoundedRectangle(cornerRadius: 6).fill(trackFill))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !drag.active { drag.active = true; drag.grab = g.startLocation.y }
                    // Every 4 points dragged = one line; up = back in history, like a thumb.
                    let notches = Int((drag.grab - g.location.y) / 4)
                    if notches != 0 {
                        store.scrollPane(key, lines: notches)
                        drag.grab -= CGFloat(notches) * 4
                        drag.paging = true   // moved: not a click
                    }
                }
                .onEnded { g in
                    if !drag.paging, g.startLocation.y > 18, g.startLocation.y < h - 18 {
                        store.scrollPane(key, pages: g.startLocation.y < h / 2 ? 1 : -1)
                    }
                    drag.active = false; drag.paging = false
                })
            .help("This app is full-screen and keeps its own history. Scroll here or with the wheel; ▲/▼ page.")
        }
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
        Task { await store.refreshScrollInfo(key) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { _ = Task<Void, Never> { await store.refreshScrollInfo(key) } }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}
