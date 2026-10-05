import AppKit
import MuxbarCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = SettingsModel()
    @State private var editingAgent: AgentProfile?
    @State private var originalAgentID: String?
    @State private var showingAgentEditor = false
    @State private var agentToDelete: AgentProfile?

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
            Section {
                if store.settings.customAgents.isEmpty {
                    Text("No custom agents yet.").foregroundStyle(.secondary)
                }
                ForEach(store.settings.customAgents) { agent in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name)
                            Text(agent.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { beginEditing(agent) }
                            .accessibilityLabel("Edit \(agent.name)")
                        Button(role: .destructive) { agentToDelete = agent } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(agent.name)")
                        .accessibilityLabel("Remove \(agent.name)")
                    }
                }
                Button {
                    editingAgent = AgentProfile(id: "", name: "", command: "")
                    originalAgentID = nil
                    showingAgentEditor = true
                } label: {
                    Label("Add Custom Agent", systemImage: "plus")
                }
            } header: {
                Text("Custom agents")
            } footer: {
                Text("Profiles can define how Muxbar starts, detects, and resumes a command-line agent.")
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
        .sheet(isPresented: $showingAgentEditor) {
            if let editingAgent {
                AgentProfileEditorView(
                    profile: editingAgent,
                    originalID: originalAgentID,
                    existingAgents: store.settings.customAgents,
                    onSave: saveAgent
                )
            }
        }
        .confirmationDialog("Remove custom agent?", isPresented: Binding(
            get: { agentToDelete != nil },
            set: { if !$0 { agentToDelete = nil } }
        ), titleVisibility: .visible, presenting: agentToDelete) { agent in
            Button("Remove \(agent.name)", role: .destructive) {
                store.updateSettings { settings in
                    settings.customAgents.removeAll { $0.id == agent.id }
                }
                agentToDelete = nil
            }
            Button("Cancel", role: .cancel) { agentToDelete = nil }
        } message: { _ in
            Text("Muxbar will stop using this profile's detection and resume settings. Existing terminal sessions are not changed.")
        }
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

    private func beginEditing(_ agent: AgentProfile) {
        editingAgent = agent
        originalAgentID = agent.id
        showingAgentEditor = true
    }

    private func saveAgent(_ agent: AgentProfile) {
        store.updateSettings { settings in
            if let originalAgentID,
               let index = settings.customAgents.firstIndex(where: { $0.id == originalAgentID }) {
                settings.customAgents[index] = agent
            } else {
                settings.customAgents.append(agent)
            }
        }
        showingAgentEditor = false
        editingAgent = nil
        originalAgentID = nil
    }
}

private struct AgentProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AgentProfile
    let originalID: String?
    let existingAgents: [AgentProfile]
    let onSave: (AgentProfile) -> Void

    @State private var id: String
    @State private var name: String
    @State private var command: String
    @State private var processNames: String
    @State private var resumeTemplate: String
    @State private var continueCommand: String
    @State private var waitingMarkers: String
    @State private var workingMarkers: String
    @State private var validationError: String?

    init(profile: AgentProfile, originalID: String?, existingAgents: [AgentProfile], onSave: @escaping (AgentProfile) -> Void) {
        self.profile = profile
        self.originalID = originalID
        self.existingAgents = existingAgents
        self.onSave = onSave
        _id = State(initialValue: profile.id)
        _name = State(initialValue: profile.name)
        _command = State(initialValue: profile.command)
        _processNames = State(initialValue: profile.processNames.joined(separator: ", "))
        _resumeTemplate = State(initialValue: profile.resumeTemplate ?? "")
        _continueCommand = State(initialValue: profile.continueCommand ?? "")
        _waitingMarkers = State(initialValue: profile.waitingMarkers.joined(separator: "\n"))
        _workingMarkers = State(initialValue: profile.workingMarkers.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Identifier", text: $id)
                        .disabled(originalID != nil)
                    if originalID != nil {
                        Text("The identifier is stable because saved sessions refer to it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Name", text: $name)
                    TextField("Command", text: $command)
                        .font(.system(.body, design: .monospaced))
                    Text("Required: a unique identifier, a display name, and the shell command to start the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Resume") {
                    TextField("Resume command with {id}", text: $resumeTemplate)
                        .font(.system(.body, design: .monospaced))
                    TextField("Continue command", text: $continueCommand)
                        .font(.system(.body, design: .monospaced))
                    Text("Leave either field blank when the command is unsupported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Detection") {
                    TextField("Process names (comma-separated)", text: $processNames)
                        .font(.system(.body, design: .monospaced))
                    Text("Leave process names blank to infer the executable from the start command.")
                        .font(.caption).foregroundStyle(.secondary)
                    markerEditor("Waiting markers", text: $waitingMarkers)
                    markerEditor("Working markers", text: $workingMarkers)
                }
                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(originalID == nil ? "Add Custom Agent" : "Edit Custom Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(minWidth: 480, minHeight: 560)
        }
    }

    private func markerEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 54, maxHeight: 72)
            Text("One marker per line")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty, !trimmedCommand.isEmpty else {
            validationError = "Identifier, name, and command are required."
            return
        }
        if existingAgents.contains(where: { $0.id == trimmedID && $0.id != originalID }) {
            validationError = "An agent with this identifier already exists."
            return
        }
        let parsedProcessNames = splitList(processNames)
        let profile = AgentProfile(
            id: trimmedID,
            name: trimmedName,
            command: trimmedCommand,
            processNames: parsedProcessNames.isEmpty ? nil : parsedProcessNames,
            resumeTemplate: optionalText(resumeTemplate),
            continueCommand: optionalText(continueCommand),
            waitingMarkers: splitLines(waitingMarkers),
            workingMarkers: splitLines(workingMarkers)
        )
        onSave(profile)
    }

    private func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func splitLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
