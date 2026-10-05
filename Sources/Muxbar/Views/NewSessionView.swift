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
            TextField("Name", text: $m.name, prompt: Text("e.g. khoj-index"))
            TextField("Command", text: $m.command, prompt: Text("empty = plain shell"))
                .font(.system(.body, design: .monospaced))
            Picker("Group", selection: $m.group) {
                Text("None").tag(String?.none)
                ForEach(store.state.groups(for: m.host), id: \.self) { g in Text(g).tag(String?.some(g)) }
            }
            Text(m.dir.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Folder empty → workspace folder \(Workspace.path(root: store.workspaceRoot(m.host), group: m.group, session: m.name.isEmpty ? "<name>" : sanitizeSessionName(m.name))) is created. \(runHint)"
                 : "Opens a terminal in the folder. \(runHint)")
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
                    .disabled(m.busy || m.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            m.dir = ""   // default: the session's workspace folder
            m.command = store.settings.defaultCommand
        }
        .onChange(of: m.host) { _, h in
            m.dir = ""
            m.group = nil   // groups belong to one host
        }
    }

    private var runHint: String {
        let c = m.command.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "Just a shell — run any agent CLI or anything else." : "Runs `\(c)`, then leaves a shell."
    }

    private func create() {
        m.busy = true
        m.error = nil
        Task {
            do {
                _ = try await store.newSession(host: m.host, dir: m.dir, name: m.name, command: m.command, group: m.group)
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
    @Published var command = ""
    @Published var group: String?
    @Published var busy = false
    @Published var error: String?
}
