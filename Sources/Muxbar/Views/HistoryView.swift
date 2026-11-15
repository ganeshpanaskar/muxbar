import AppKit
import MuxbarCore
import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    @Published var query = ""
    @Published var host = "*"            // "*" = all hosts
    @Published var agent = "both"
    @Published var days = 30
    @Published var folder = ""
    @Published var hits: [AgentHistory.Hit] = []
    @Published var selected: String?
    @Published var preview: AgentHistory.Preview?
    @Published var searching = false
    @Published var errors: [String] = []
    @Published var message: String?
    var generation = 0

    var shown: [AgentHistory.Hit] {
        let f = folder.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? hits : hits.filter { ($0.cwd ?? "").lowercased().contains(f) }
    }

    func key(_ h: AgentHistory.Hit) -> String { h.key }
}

/// ⌘⇧H: find a conversation by what was said in it, on this Mac or a remote host.
struct HistoryView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search what you or the agent said", text: $m.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button(m.searching ? "Searching…" : "Search") { search() }.disabled(m.searching || m.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Picker("", selection: $m.host) {
                    Text("All hosts").tag("*")
                    ForEach(store.state.hosts, id: \.self) { h in Text(store.hostLabel(h)).tag(h) }
                }
                .labelsHidden().frame(width: 170)
                Picker("", selection: $m.agent) {
                    Text("Both").tag("both"); Text("Claude").tag("claude"); Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Picker("", selection: $m.days) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("All").tag(0)
                }
                .labelsHidden().frame(width: 100)
                TextField("Folder contains…", text: $m.folder).textFieldStyle(.roundedBorder).frame(width: 170)
                Spacer()
                if m.searching { ProgressView().controlSize(.small) }
            }
            ForEach(m.errors, id: \.self) { e in Text(e).font(.caption).foregroundStyle(.orange) }
            HSplitView {
                List(m.shown, id: \.key, selection: Binding(get: { m.selected }, set: { k in m.selected = k; loadPreview() })) { h in
                    HitRow(hit: h).tag(m.key(h))
                }
                .frame(minWidth: 320)
                PreviewPane(m: m)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 520)
        .onReceive(store.$historyRequest) { req in
            guard let req else { return }
            store.historyRequest = nil
            m.query = req.query; m.host = req.host; m.days = 0
            search(claudeRoot: req.claudeRoot, codexRoot: req.codexRoot)
        }
    }

    private func search(claudeRoot: String? = nil, codexRoot: String? = nil) {
        let q = m.query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        m.generation += 1
        let gen = m.generation
        m.searching = true; m.errors = []; m.hits = []; m.selected = nil; m.preview = nil; m.message = nil
        let hosts = m.host == "*" ? store.state.hosts : [m.host]
        let agent = AgentKind(rawValue: m.agent)
        Task {
            var (hits, errors) = ([AgentHistory.Hit](), [String]())
            if claudeRoot != nil || codexRoot != nil, hosts.count == 1 {
                do { hits = try await store.historySearch(host: hosts[0], query: q, agent: agent, days: m.days, claudeRoot: claudeRoot, codexRoot: codexRoot) }
                catch { errors = [error.localizedDescription] }
            } else {
                (hits, errors) = await store.historySearch(hosts: hosts, query: q, agent: agent, days: m.days)
            }
            guard gen == m.generation else { return }   // a newer search replaced this one
            m.hits = hits; m.errors = errors; m.searching = false
            m.message = hits.isEmpty ? "No conversations mention “\(q)”." : "\(hits.count) conversation\(hits.count == 1 ? "" : "s")"
        }
    }

    private func loadPreview() {
        guard let k = m.selected, let hit = m.shown.first(where: { m.key($0) == k }) else { m.preview = nil; return }
        m.preview = nil
        Task {
            let p = await store.historyPreview(hit)
            if m.selected == k { m.preview = p }
        }
    }
}

struct HitRow: View {
    @EnvironmentObject var store: SessionStore
    var hit: AgentHistory.Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title).lineLimit(1)
            HStack(spacing: 4) {
                Text(hit.agent.displayName).font(.caption2).padding(.horizontal, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                Text([store.hostLabel(hit.host), hit.cwd.map { ($0 as NSString).lastPathComponent }, timeAgo(hit.modified), "\(hit.messages) msgs"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(snippet).font(.caption).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    /// "…before **match** after…", the match highlighted.
    var snippet: AttributedString {
        var a = AttributedString(hit.before)
        var mt = AttributedString(hit.match)
        mt.font = .caption.bold()
        mt.backgroundColor = Color.yellow.opacity(0.35)
        a += mt
        a += AttributedString(hit.after)
        return a
    }
}

struct PreviewPane: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var m: HistoryModel

    var body: some View {
        if let k = m.selected, let hit = m.shown.first(where: { m.key($0) == k }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(m.preview?.firstPrompt ?? hit.title).font(.headline).lineLimit(3)
                Text([hit.cwd, m.preview?.gitBranch.map { "⎇ " + $0 }, m.preview?.model].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let p = m.preview {
                            ForEach(Array(p.turns.enumerated()), id: \.offset) { _, t in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(t.role == "user" ? "You" : (t.role == "tool" ? "" : hit.agent.displayName))
                                        .font(.caption).bold().frame(width: 52, alignment: .leading)
                                    Text(t.text).font(t.role == "tool" ? .caption.monospaced() : .callout)
                                        .foregroundStyle(t.role == "tool" ? .secondary : .primary).textSelection(.enabled)
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Resume in New Session") {
                        Task { do { let rec = try await store.resumeFromHistory(hit); Actions.focus(store, rec) } catch { m.errors = [error.localizedDescription] } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hit.id.isEmpty)
                    Button("Copy Resume Command") { copy(AgentHistory.resumeCommandLine(agent: hit.agent, id: hit.id, cwd: hit.cwd)) }
                    Button("Copy Session ID") { copy(hit.id) }
                    if hit.host == localHost {
                        Button("Reveal Transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
        } else {
            Text("Select a conversation").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        m.message = "Copied: \(s)"
    }
}
