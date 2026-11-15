import AppKit
import MuxbarCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = SettingsModel()

    var body: some View {
        Form {
            Section("Remote hosts") {
                let added = store.state.hosts.filter { $0 != localHost }
                if added.isEmpty { Text("None yet. Add one by its address or ~/.ssh/config alias.").foregroundStyle(.secondary) }
                ForEach(added, id: \.self) { h in
                    HStack {
                        let hh = store.health[h] ?? .unknown
                        Circle().fill(hh == .ok ? Color.green : (hh == .unknown ? Color.gray : .orange)).frame(width: 8, height: 8)
                        Text(h).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(hh.label).font(.caption).foregroundStyle(.secondary).help(hh.hint ?? "")
                        Button("Remove…") { Actions.confirmRemoveHost(store, h) }
                    }
                }
                HostAddRow(adder: m.adder, existing: store.state.hosts) { h, _ in
                    do { try store.addRemoteHost(h) } catch { store.banner = error.localizedDescription }
                }
            }
            Section("Workspace folders (press Return to save)") {
                Text("New sessions without a folder get <root>/<group>/<session>. Changing a root only affects new sessions: existing ones keep their folders, and renames and group moves keep a folder under the root it was made in. Nothing is ever deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.state.hosts, id: \.self) { h in
                    RootField(host: h)
                }
            }
            Section("Exact status (agent hooks)") {
                Text("Claude Code and Codex can tell Muxbar exactly when they're working, waiting for you or done, through their own hooks — instead of Muxbar reading the screen. Install adds Muxbar's small status plugin (Claude) or hook entries (Codex) on that host; Remove takes them out. Restart running sessions afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.state.hosts, id: \.self) { h in
                    HookHostRow(host: h, hooks: store.hooks)
                }
            }
            Section("New sessions") {
                Picker("Start with", selection: Binding(
                    get: { store.settings.newSessionStart },
                    set: { v in store.updateSettings { $0.newSessionStart = v } })) {
                    Text("Shell").tag("shell")
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Other").tag("other")
                }
                TextField("Other command", text: $m.command, prompt: Text("e.g. gemini, grok, aider"))
                    .onSubmit { saveCommand() }
                Text("Muxbar works with any terminal agent. Claude Code and Codex get exact status, history and sleep; other CLIs (Gemini, Grok, Aider…) get status read from their screen. Press Return to save the command.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Mouse & copy") {
                Toggle("Send mouse clicks to terminal apps", isOn: Binding(
                    get: { store.settings.passMouseToApps },
                    set: { v in store.updateSettings { $0.passMouseToApps = v } }))
                Text(store.settings.passMouseToApps
                     ? "Apps like Claude Code and vim get clicks and drags. Hold ⌥ Option while dragging to select text, then ⌘C."
                     : "Drag to select text, then ⌘C / ⌘V — in every pane, local or remote. Turn on to let apps like vim use the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Picker("Open sessions in", selection: Binding(
                    get: { store.settings.terminal },
                    set: { v in store.updateSettings { $0.terminal = v } })) {
                    Text("Muxbar window (built-in terminal)").tag(TerminalKind.embedded)
                    Text("Terminal (one window per session)").tag(TerminalKind.terminal)
                    if isITermInstalled() { Text("iTerm2 (tabs)").tag(TerminalKind.iterm) }
                }
            }
            Section("Hosts (from ~/.ssh/config)") {
                let hosts = store.availableSSHHosts()
                if hosts.isEmpty { Text("No Host entries found.").foregroundStyle(.secondary) }
                ForEach(hosts, id: \.self) { h in
                    Toggle(h, isOn: Binding(
                        get: { store.state.hosts.contains(h) },
                        set: { on in on ? store.addHost(h) : Actions.confirmRemoveHost(store, h) }))
                }
            }
            Section("Port forwarding") {
                Toggle("Auto-forward new ports from my sessions", isOn: Binding(
                    get: { store.settings.autoForward },
                    set: { v in store.updateSettings { $0.autoForward = v } }))
                Text("A server your session starts on a remote host opens on localhost here. Forwards listen on 127.0.0.1 only and come back after a reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                Toggle("Warn before a host runs out of memory", isOn: Binding(
                    get: { store.settings.memAlerts },
                    set: { v in store.updateSettings { $0.memAlerts = v } }))
                Stepper("Orange at \(store.settings.memWarnPct)% used", value: Binding(
                    get: { store.settings.memWarnPct },
                    set: { v in store.updateSettings { $0.memWarnPct = min(v, $0.memCritPct - 1) } }), in: 50...95, step: 5)
                Stepper("Red and alert at \(store.settings.memCritPct)% used", value: Binding(
                    get: { store.settings.memCritPct },
                    set: { v in store.updateSettings { $0.memCritPct = max(v, $0.memWarnPct + 1) } }), in: 60...99, step: 1)
                Text("Also alerts when memory is falling fast enough to run out within 5 minutes. A host above the orange line is checked every 5 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sleeping agents") {
                Toggle("Put idle agents to sleep automatically", isOn: Binding(
                    get: { store.settings.autoSleepMinutes != nil },
                    set: { on in store.updateSettings { $0.autoSleepMinutes = on ? 30 : nil } }))
                if let mins = store.settings.autoSleepMinutes {
                    Stepper("After \(mins) min idle", value: Binding(
                        get: { mins },
                        set: { v in store.updateSettings { $0.autoSleepMinutes = v } }), in: 5...1440, step: 5)
                }
                Toggle("Wake when opened", isOn: Binding(
                    get: { store.settings.wakeOnOpen },
                    set: { v in store.updateSettings { $0.wakeOnOpen = v } }))
                Text("Sleeping exits the agent to free its memory; the session and its shell stay. Opening it resumes the same conversation. Never sleeps an agent that's busy, waiting, on screen, has typed text, or has a background job.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify when an agent finishes", isOn: Binding(
                    get: { store.settings.notifyOnFinish },
                    set: { v in store.updateSettings { $0.notifyOnFinish = v } }))
                Picker("Dock badge counts", selection: Binding(
                    get: { store.settings.dockBadgeMode },
                    set: { v in store.updateSettings { $0.dockBadgeMode = v }; Attention.shared.refreshBadge(store) })) {
                    Text("Needs input and finished").tag(DockBadgeMode.needsInputAndFinished)
                    Text("Needs input only").tag(DockBadgeMode.needsInput)
                }
                Text("Waiting sessions always notify. Finished ones notify at most once a minute each, never for the session you're looking at.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open Muxbar at login", isOn: Binding(
                    get: { m.loginItem },
                    set: { on in
                        do { try LoginItem.set(on); m.loginError = nil } catch {
                            m.loginError = error.localizedDescription
                            Log.error("login item: \(error)")
                        }
                        m.loginItem = LoginItem.isEnabled
                    }))
                if let e = m.loginError { Text(e).font(.caption).foregroundStyle(.red) }
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { store.settings.checkForUpdates },
                    set: { on in store.updateSettings { $0.checkForUpdates = on } }))
                LabeledContent("Version \(Updater.currentVersion.description)") {
                    Button("Check now") { _ = Task<Void, Never> { await Updater.shared.check(manual: true) } }
                }
                Text("Minor updates install themselves (Muxbar restarts; sessions keep running). Major updates ask first. Only GitHub's release API is contacted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear { m.command = store.settings.otherCommand }
        .onDisappear { saveCommand() }
    }

    private func saveCommand() {
        let c = m.command.trimmingCharacters(in: .whitespaces)
        if c != store.settings.otherCommand { store.updateSettings { $0.otherCommand = c } }
    }
}

/// One host's hook status for each agent, with Install / Remove (always confirmed first).
struct HookHostRow: View {
    @EnvironmentObject var store: SessionStore
    let host: String
    @ObservedObject var hooks: StatusHooks

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.hostLabel(host)).font(.subheadline.weight(.semibold))
            ForEach(AgentKind.allCases, id: \.self) { a in
                let st = hooks.state(host, a)
                HStack {
                    Text(a.displayName).frame(width: 60, alignment: .leading)
                    Text(Self.label(st)).font(.caption).foregroundStyle(st == .installed ? .green : (st == .blocked ? .red : .secondary))
                    Spacer()
                    if hooks.busy.contains("\(host)|\(a.rawValue)") { ProgressView().controlSize(.small) }
                    Button(st == .installed || st == .needsTrust ? "Remove" : "Install…") { confirm(a, remove: st == .installed || st == .needsTrust) }
                        .disabled(hooks.busy.contains("\(host)|\(a.rawValue)") || st == .agentMissing && a == .claude)
                }
                if let d = hooks.details["\(host)|\(a.rawValue)"], !d.isEmpty, st != .installed {
                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .task { await hooks.refresh(host: host) }
    }

    static func label(_ s: HookInstall.State) -> String {
        switch s {
        case .installed: return "Installed"
        case .notInstalled: return "Not installed"
        case .blocked: return "Blocked by policy"
        case .needsTrust: return "Installed — trust it once in Codex (/hooks)"
        case .agentMissing: return "Not on this host"
        case .unknown: return "Checking…"
        }
    }

    func confirm(_ agent: AgentKind, remove: Bool) {
        let where_ = store.hostLabel(host)
        let alert = NSAlert()
        if remove {
            alert.messageText = "Remove Muxbar's status hooks for \(agent.displayName) on \(where_)?"
            alert.informativeText = agent == .claude
                ? "Muxbar will run:\n  claude plugin uninstall \(HookInstall.pluginID)\n  claude plugin marketplace remove \(HookInstall.marketplace)"
                : "Muxbar will remove only its own handlers (tagged \(HookInstall.tag)) from ~/.codex/hooks.json, after a backup."
            alert.addButton(withTitle: "Remove")
        } else {
            alert.messageText = "Install Muxbar's status hooks for \(agent.displayName) on \(where_)?"
            alert.informativeText = (agent == .claude
                ? "Muxbar copies its status plugin to ~/.muxbar/agent-plugin and runs:\n  claude plugin marketplace add ~/.muxbar/agent-plugin\n  claude plugin install \(HookInstall.pluginID)"
                : "Muxbar copies its status hook to ~/.muxbar/agent-plugin and adds handlers (tagged \(HookInstall.tag)) to ~/.codex/hooks.json, after a backup. Codex then asks you to trust them once (/hooks).")
                + "\n\nThe hooks only write small status files under ~/.muxbar/state (state, session id, folder). Remove undoes it."
            alert.addButton(withTitle: "Install")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                if remove { try await hooks.uninstall(host: host, agent: agent) } else { try await hooks.install(host: host, agent: agent) }
            } catch {
                Log.error("status hooks on \(host): \(error)")
                store.banner = error.localizedDescription
            }
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var loginItem = LoginItem.isEnabled
    @Published var loginError: String?
    @Published var command = ""
    let adder = HostAdder()
}

struct RootField: View {
    @EnvironmentObject var store: SessionStore
    var host: String
    @StateObject private var m = RootFieldModel()

    var body: some View {
        LabeledContent(host == localHost ? "This Mac" : host) {
            HStack {
                TextField("root", text: $m.value)
                    .labelsHidden()
                    .onSubmit { save() }
                if !m.value.isEmpty && !Workspace.isValidRoot(m.value) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Must start with / or ~/")
                }
                if host == localHost {
                    Button { pick() } label: { Image(systemName: "folder") }.help("Choose a folder")
                }
                Button("Save") { save() }.disabled(m.value == store.workspaceRoot(host))
            }
        }
        .onAppear { m.value = store.workspaceRoot(host) }
    }

    private func save() {
        guard m.value.trimmingCharacters(in: .whitespaces).isEmpty || Workspace.isValidRoot(m.value) else { return }
        store.updateSettings { $0.workspaceRoots[host] = m.value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : m.value }
        m.value = store.workspaceRoot(host)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use as Root"
        if panel.runModal() == .OK, let url = panel.url {
            let home = NSHomeDirectory()
            m.value = url.path.hasPrefix(home + "/") ? "~/" + url.path.dropFirst(home.count + 1) : url.path
            save()
        }
    }
}

@MainActor
final class RootFieldModel: ObservableObject { @Published var value = "" }
