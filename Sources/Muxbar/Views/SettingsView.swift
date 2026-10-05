import AppKit
import MuxbarCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = SettingsModel()

    var body: some View {
        Form {
            Section("Workspace folders (press Return to save)") {
                Text("New sessions without a folder get <root>/<group>/<session>. Renames and group moves move the folder; nothing is ever deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.state.hosts, id: \.self) { h in
                    RootField(host: h)
                }
            }
            Section("New sessions") {
                LabeledContent("Default command") {
                    HStack {
                        TextField("claude", text: $m.command)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { saveCommand() }
                        Button("Save") { saveCommand() }.disabled(m.command == store.settings.defaultCommand)
                    }
                }
                Text("Runs when a session's terminal opens — any CLI works: claude, codex, gemini, grok, aider… Empty = just a shell.\(agentHint)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        set: { on in on ? store.addHost(h) : store.removeHost(h) }))
                }
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
        .onAppear { m.command = store.settings.defaultCommand }
    }

    private var agentHint: String {
        guard let a = store.settings.defaultAgent else { return "" }
        let builtin = AgentProfile.builtins.contains { $0.id == a.id }
        return builtin ? " Status and resume use \(a.name)'s conventions." : " Status is detected from the \(a.processNames.joined(separator: ", ")) process and the screen."
    }

    private func saveCommand() {
        let c = m.command.trimmingCharacters(in: .whitespaces)
        store.updateSettings { $0.defaultCommand = c }
        m.command = c
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var loginItem = LoginItem.isEnabled
    @Published var loginError: String?
    @Published var command = ""
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
                if host == localHost {
                    Button { pick() } label: { Image(systemName: "folder") }.help("Choose a folder")
                }
                Button("Save") { save() }.disabled(m.value == store.workspaceRoot(host))
            }
        }
        .onAppear { m.value = store.workspaceRoot(host) }
    }

    private func save() {
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
