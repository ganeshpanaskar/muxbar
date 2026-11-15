import AppKit
import MuxbarCore
import SwiftUI

/// Checks an address over SSH before it's added (setup window and Settings).
@MainActor
final class HostAdder: ObservableObject {
    @Published var input = ""
    @Published var checking = false
    /// The last failed check (a passing host is added straight away).
    @Published var failed: (host: String, result: HostCheck.Result)?
    @Published var error: String?

    func reset() { input = ""; failed = nil; error = nil }

    /// Validates and checks `input`; a host that answers (with tmux) is added, one that doesn't is
    /// kept in `failed` so the user can read why and Add Anyway.
    func checkAndAdd(_ store: SessionStore, existing: [String], onAdd: @escaping (String, HostCheck.Result?) -> Void) {
        error = nil; failed = nil
        let h: String
        do { h = try HostAddress.normalize(input) } catch { self.error = error.localizedDescription; return }
        guard !existing.contains(h) else { error = "\(h) is already added"; return }
        checking = true
        Task {
            defer { checking = false }
            guard let c = try? await store.checkHost(h) else { return }
            if c.result.ok { onAdd(c.host, c.result); reset() } else { failed = c }
        }
    }
}

/// An address field with Check & Add. A failed check says why and offers Add Anyway (e.g. the
/// VPN is off right now).
struct HostAddRow: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var adder: HostAdder
    var existing: [String]
    var onAdd: (String, HostCheck.Result?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Prompt, not title: inside a Form a title becomes a wrapped label on the left.
                TextField("Address", text: $adder.input, prompt: Text("devbox.example.com, user@host or an ssh alias"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                    .disabled(adder.checking)
                Button(adder.checking ? "Checking…" : "Check & Add") { add() }
                    .disabled(adder.checking || adder.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if adder.checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting over SSH…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = adder.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if let f = adder.failed {
                HStack(alignment: .top) {
                    Label(f.result.message(host: f.host), systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Anyway") { onAdd(f.host, f.result); adder.reset() }
                }
            }
        }
    }

    private func add() { adder.checkAndAdd(store, existing: existing, onAdd: onAdd) }
}

@MainActor
final class SetupModel: ObservableObject {
    struct Pending: Identifiable {
        var host: String
        var root: String
        var ok: Bool
        var status: String
        var id: String { host }
    }

    @Published var localRoot = ""
    @Published var hosts: [Pending] = []
    @Published var error: String?

    func add(_ h: String, _ r: HostCheck.Result?) {
        guard !hosts.contains(where: { $0.host == h }) else { return }
        hosts.append(Pending(host: h, root: Workspace.defaultRemoteRoot, ok: r?.ok ?? false,
                             status: r?.message(host: h) ?? "Not checked"))
    }

    func remove(_ h: String) { hosts.removeAll { $0.host == h } }
}

/// First launch: where session folders go, and which remote hosts Muxbar manages.
struct SetupView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = SetupModel()
    @StateObject private var adder = HostAdder()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Muxbar").font(.title2).bold()
            Text("Each new session gets its own folder, <root>/<group>/<session>, on the host it runs on. You can change all of this later in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("This Mac") {
                HStack {
                    Text("Root folder")
                    TextField(Workspace.defaultLocalRoot, text: $m.localRoot).textFieldStyle(.roundedBorder)
                    Button("Choose…") { pick() }
                }
                .padding(4)
            }

            GroupBox("Remote hosts") {
                VStack(alignment: .leading, spacing: 8) {
                    HostAddRow(adder: adder, existing: m.hosts.map(\.host)) { h, r in m.add(h, r) }
                    ForEach($m.hosts) { $p in
                        HStack {
                            Image(systemName: p.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(p.ok ? Color.green : .orange)
                                .help(p.status)
                            Text(p.host).lineLimit(1).truncationMode(.middle).help(p.status)
                            Spacer()
                            Text("root").foregroundStyle(.secondary)
                            TextField(Workspace.defaultRemoteRoot, text: $p.root).textFieldStyle(.roundedBorder).frame(width: 170)
                            Button { m.remove(p.host) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Don't add \(p.host)")
                        }
                    }
                    // Git servers in ~/.ssh/config are never remote hosts.
                    let suggestions = store.availableSSHHosts().filter { h in
                        !m.hosts.contains { $0.host == h }
                            && h.range(of: #"^(git|github|gitlab|bitbucket)([.-]|$)"#, options: [.regularExpression, .caseInsensitive]) == nil
                    }
                    if !suggestions.isEmpty {
                        Text("From ~/.ssh/config (click to check and add)").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                                ForEach(suggestions, id: \.self) { h in
                                    Button { adder.input = h; adder.checkAndAdd(store, existing: m.hosts.map(\.host)) { h, r in m.add(h, r) } }
                                        label: { Label(h, systemImage: "plus").lineLimit(1) }
                                        .buttonStyle(.borderless)
                                        .disabled(adder.checking)
                                }
                            }
                        }
                        .frame(maxHeight: 96)
                    }
                }
                .padding(4)
            }

            if let e = m.error { Text(e).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Nothing is created until you start a session.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { store.finishSetup() }
                Button("Done") { done() }.keyboardShortcut(.defaultAction).disabled(adder.checking)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { if m.localRoot.isEmpty { m.localRoot = store.workspaceRoot(localHost) } }
    }

    private func done() {
        let typed = adder.input.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { m.error = "Click Check & Add for \(typed), or clear it"; return }
        do { try store.applySetup(localRoot: m.localRoot, hosts: m.hosts.map { ($0.host, $0.root) }) }
        catch { m.error = error.localizedDescription }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use as Root"
        if panel.runModal() == .OK, let url = panel.url {
            let home = NSHomeDirectory()
            m.localRoot = url.path.hasPrefix(home + "/") ? "~/" + url.path.dropFirst(home.count + 1) : url.path
        }
    }
}

/// Opens the setup window on a fresh install (once SwiftUI's openWindow is available).
@MainActor
enum SetupPresenter {
    static func showIfNeeded(attempt: Int = 0) {
        let store = AppModel.shared.store
        guard store.needsSetup, !store.setupWindowOpen else { return }
        guard let open = WindowOpener.open else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showIfNeeded(attempt: attempt + 1) } }
            return
        }
        open("setup")
        activateApp()
    }
}
