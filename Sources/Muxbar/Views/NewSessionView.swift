import MuxbarCore
import SwiftUI

struct NewSessionView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    // @State is a macro in the macOS 27 SDK whose plugin ships only with Xcode, so view-local
    // state lives in an ObservableObject (builds with Command Line Tools alone).
    @StateObject private var m = NewSessionModel()

    var body: some View {
        Form {
            Picker("Host", selection: $m.host) {
                ForEach(store.state.hosts, id: \.self) { h in
                    Text(h == localHost ? "This Mac" : h).tag(h)
                }
            }
            LabeledContent("Folder") { FolderField(host: m.host, path: $m.dir) }
            TextField("Name", text: $m.name, prompt: Text("e.g. api-refactor"))
            Picker("Start", selection: $m.start) {
                Text("Shell").tag("shell")
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
                Text("Other").tag("other")
            }
            .pickerStyle(.segmented)
            if m.start == "other" {
                TextField("Command", text: $m.command, prompt: Text("e.g. gemini, grok, aider"))
            }
            Picker("Group", selection: $m.group) {
                Text("None").tag(String?.none)
                ForEach(store.state.groups(for: m.host), id: \.self) { g in Text(g).tag(String?.some(g)) }
            }
            Text(folderNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if m.host == localHost && store.localTmux == nil {
                Text("tmux isn't installed on this Mac, so this opens a plain window that won't survive being closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = m.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(m.busy ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.busy || m.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || m.start == "other" && m.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            m.dir = ""   // default: the session's workspace folder
            m.start = ["shell", "claude", "codex", "other"].contains(store.settings.newSessionStart) ? store.settings.newSessionStart : "claude"
            m.command = store.settings.otherCommand
            if let p = store.newSessionPrefill {
                m.host = p.host
                DispatchQueue.main.async { m.group = p.group }   // after onChange(host) resets it
                store.newSessionPrefill = nil
            }
        }
        .onChange(of: m.host) { _, h in
            m.dir = ""
            m.group = nil   // groups belong to one host
        }
        .onChange(of: m.dir) { _, _ in checkFolder() }
    }

    private var folderNote: String {
        let d = m.dir.trimmingCharacters(in: .whitespaces)
        let what: String
        switch m.start {
        case "claude": what = "Starts Claude Code there; when it exits, the session is a shell."
        case "codex": what = "Starts Codex there; when it exits, the session is a shell."
        case "other":
            let c = m.command.trimmingCharacters(in: .whitespaces)
            what = c.isEmpty ? "Type the command to start (any CLI agent)." : "Runs `\(c)` there; when it exits, the session is a shell."
        default: what = "Opens a shell there — run `claude` or anything else."
        }
        if d.isEmpty {
            return "Folder empty → workspace folder \(Workspace.path(root: store.workspaceRoot(m.host), group: m.group, session: m.name.isEmpty ? "<name>" : sanitizeSessionName(m.name))) is created. " + what
        }
        switch m.folderExists {
        case false?: return "New folder: \(d) will be created. " + what
        default: return what
        }
    }

    /// Checks whether the typed folder exists (on the session's host), shortly after typing stops.
    private func checkFolder() {
        m.folderExists = nil
        let d = m.dir.trimmingCharacters(in: .whitespaces), host = m.host
        guard !d.isEmpty else { return }
        m.checkTask?.cancel()
        m.checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let e = await store.folderExists(host: host, path: d)
            if !Task.isCancelled, m.dir.trimmingCharacters(in: .whitespaces) == d, m.host == host { m.folderExists = e }
        }
    }

    private func create() {
        m.busy = true
        m.error = nil
        let start = m.start
        let other = m.command.trimmingCharacters(in: .whitespaces)
        store.mutate { s in   // offered again next time
            s.settings.newSessionStart = start
            if start == "other" { s.settings.otherCommand = other }
        }
        let command = store.settings.startCommand(start)
        Task {
            do {
                // A typed folder is created if it doesn't exist yet (the note says so).
                _ = try await store.newSession(host: m.host, dir: m.dir.trimmingCharacters(in: .whitespaces), name: m.name,
                                               command: command, group: m.group, createFolder: true)
                m.busy = false
                m.name = ""
                dismiss()
            } catch {
                m.busy = false
                m.error = error.localizedDescription
            }
        }
    }
}

@MainActor
final class NewSessionModel: ObservableObject {
    @Published var host = localHost
    @Published var dir = ""
    @Published var name = ""
    @Published var group: String?
    /// "shell", "claude", "codex" or "other" (then `command`).
    @Published var start = "claude"
    @Published var command = ""
    @Published var busy = false
    @Published var error: String?
    /// The typed folder exists on the host (nil = not checked yet / couldn't tell).
    @Published var folderExists: Bool?
    var checkTask: Task<Void, Never>?
}
