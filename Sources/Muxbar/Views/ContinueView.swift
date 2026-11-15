import MuxbarCore
import SwiftUI

/// Lists Claude Code conversations on a host — including ones started in a plain terminal outside
/// Muxbar — and continues one in a new session (`claude --resume <id>` in its original folder).
struct ContinueView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = ContinueModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Host", selection: $m.host) {
                    ForEach(store.state.hosts, id: \.self) { h in Text(h == localHost ? "This Mac" : h).tag(h) }
                }
                .frame(maxWidth: 260)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                Spacer()
                if m.loading { ProgressView().controlSize(.small) }
            }
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Folder").frame(width: 120, alignment: .leading)
                        FolderField(host: m.host, path: $m.folder, extra: m.items.compactMap(\.cwd))
                    }
                    HStack {
                        Text("Claude session ID").frame(width: 120, alignment: .leading)
                        TextField("e.g. 66666666-ffff-4fff-8fff-666666666666", text: $m.sessionID)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Runs `claude --resume <id>` in that folder on \(m.host == localHost ? "this Mac" : m.host). Pick a conversation below to fill these in, or paste your own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }
            Text("Recent conversations on this host").font(.caption).foregroundStyle(.secondary)
            List(m.items, selection: $m.selected) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.firstPrompt ?? "(no prompt)").lineLimit(2)
                    HStack(spacing: 6) {
                        Text(c.cwd ?? "?").lineLimit(1).truncationMode(.head)
                        Text("· \(relativeAge(c.modified).replacingOccurrences(of: "active ", with: ""))")
                        if Int(Date().timeIntervalSince1970) - c.modified < 120 { Text("· may still be open elsewhere").foregroundStyle(.orange) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(c.id)
            }
            .frame(minHeight: 220)
            .onChange(of: m.selected) { _, id in
                if let id, let c = m.items.first(where: { $0.id == id }) {
                    m.sessionID = c.id
                    m.folder = c.cwd ?? m.folder
                }
            }
            if !m.loading && m.items.isEmpty && m.error == nil {
                Text("No Claude conversations found on this host.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Search All History… (⌘⇧H)") { WindowOpener.open?("history") }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Session") { resume() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ClaudeConversations.isValidSessionID(m.sessionID) || m.folder.trimmingCharacters(in: .whitespaces).isEmpty || m.loading)
            }
        }
        .padding(16)
        .onAppear { load() }
        .onChange(of: m.host) { _, _ in load() }
    }

    private func load() {
        m.loading = true; m.error = nil; m.items = []; m.selected = nil
        let host = m.host
        Task {
            do { m.items = try await store.conversations(host: host) } catch { m.error = error.localizedDescription }
            m.loading = false
        }
    }

    private func resume() {
        let id = m.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = m.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeConversations.isValidSessionID(id), !folder.isEmpty else { return }
        let c = ClaudeConversation(id: id, cwd: folder, firstPrompt: nil, modified: 0)
        m.loading = true
        Task {
            do { _ = try await store.resume(host: m.host, conversation: c); dismiss() } catch { m.error = error.localizedDescription }
            m.loading = false
        }
    }
}

@MainActor
final class ContinueModel: ObservableObject {
    @Published var host = localHost
    @Published var items: [ClaudeConversation] = []
    @Published var selected: String?
    @Published var folder = ""
    @Published var sessionID = ""
    @Published var loading = false
    @Published var error: String?
}
