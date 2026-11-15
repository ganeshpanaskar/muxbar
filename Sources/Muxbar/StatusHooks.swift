import Foundation
import MuxbarCore

/// Installs, removes and checks Muxbar's status hooks per host and agent (F1). Every change is the
/// user's own action (Settings → Status, or `--cli hooks-install … --yes`); polling never installs
/// anything. Test instances point it at stub agent CLIs and throwaway folders (environment only).
@MainActor
final class StatusHooks: ObservableObject {
    @Published private(set) var states: [String: [AgentKind: HookInstall.State]] = [:]
    @Published private(set) var details: [String: String] = [:]   // "host|agent" → last output
    @Published private(set) var busy: Set<String> = []

    private let runner: () -> SystemRunner
    init(runner: @escaping () -> SystemRunner) { self.runner = runner }

    // Test overrides: stub `claude`/`codex` folder, Codex home and plugin destination on the host.
    var binDir: String? { TestEnv.value("MUXBAR_TEST_AGENT_BIN") }
    var codexHome: String? { TestEnv.value("MUXBAR_TEST_CODEX_HOME") }
    /// Shell expression for the plugin folder on the host.
    var pluginDir: String { TestEnv.value("MUXBAR_TEST_PLUGIN_DIR").map(shellQuotePath) ?? HookInstall.defaultPluginDir }
    var hookCommand: String {
        (TestEnv.value("MUXBAR_TEST_PLUGIN_DIR") ?? "~/.muxbar/agent-plugin") + "/plugins/muxbar-status/bin/muxbar-hook"
    }

    func state(_ host: String, _ agent: AgentKind) -> HookInstall.State { states[host]?[agent] ?? .unknown }

    func refresh(host: String) async {
        let c = await runner().run(host: host, script: HookInstall.claudeStatusScript(binDir: binDir), timeout: 45)
        let x = await runner().run(host: host, script: HookInstall.codexScript("status", codexHome: codexHome,
                                                                               hookCommand: hookCommand), timeout: 30)
        var s = states[host] ?? [:]
        s[.claude] = c.ok || c.stdout.contains("MBX_") ? HookInstall.claudeState(c.stdout) : .unknown
        s[.codex] = codexAvailable(x) ? HookInstall.codexOutcome(x.stdout).state : .agentMissing
        states[host] = s
    }

    /// Codex hooks can be merged even before Codex is installed, but show "not installed" for the
    /// agent itself when neither the binary nor its home exists.
    private func codexAvailable(_ r: RunResult) -> Bool {
        HookInstall.codexOutcome(r.stdout).state != .unknown
    }

    @discardableResult
    func install(host: String, agent: AgentKind) async throws -> HookInstall.Outcome {
        let key = "\(host)|\(agent.rawValue)"
        busy.insert(key); defer { busy.remove(key) }
        try await uploadPlugin(host: host)
        let outcome: HookInstall.Outcome
        switch agent {
        case .claude:
            let r = await runner().run(host: host, script: HookInstall.claudeInstallScript(binDir: binDir, pluginDir: pluginDir),
                                       timeout: 120)
            outcome = HookInstall.claudeOutcome(r.stdout + "\n" + r.stderr, installing: true)
        case .codex:
            let r = await runner().run(host: host, script: HookInstall.codexScript("install", codexHome: codexHome,
                                                                                   hookCommand: hookCommand), timeout: 45)
            outcome = HookInstall.codexOutcome(r.stdout + "\n" + r.stderr)
        }
        details[key] = outcome.detail
        Log.info("status hooks: install \(agent.rawValue) on \(host) → \(outcome.state.rawValue)")
        await refresh(host: host)
        if agent == .codex, state(host, .codex) == .installed { states[host]?[.codex] = .needsTrust }
        return outcome
    }

    @discardableResult
    func uninstall(host: String, agent: AgentKind) async throws -> HookInstall.Outcome {
        let key = "\(host)|\(agent.rawValue)"
        busy.insert(key); defer { busy.remove(key) }
        let outcome: HookInstall.Outcome
        switch agent {
        case .claude:
            let r = await runner().run(host: host, script: HookInstall.claudeUninstallScript(binDir: binDir), timeout: 120)
            outcome = HookInstall.claudeOutcome(r.stdout + "\n" + r.stderr, installing: false)
        case .codex:
            let r = await runner().run(host: host, script: HookInstall.codexScript("uninstall", codexHome: codexHome,
                                                                                   hookCommand: hookCommand), timeout: 45)
            outcome = HookInstall.codexOutcome(r.stdout + "\n" + r.stderr)
        }
        details[key] = outcome.detail
        Log.info("status hooks: uninstall \(agent.rawValue) on \(host) → \(outcome.state.rawValue)")
        await refresh(host: host)
        return outcome
    }

    /// Copies the bundled agent-plugin/ to the host (text files only, written with here-documents).
    func uploadPlugin(host: String) async throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("agent-plugin"),
              FileManager.default.fileExists(atPath: root.path) else {
            throw StoreError("The status plugin is missing from Muxbar.app (Contents/Resources/agent-plugin)")
        }
        let r = await runner().run(host: host, script: try Self.uploadScript(from: root, to: pluginDir), timeout: 45)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            throw StoreError("Couldn't copy the status plugin to \(host): \(msg.isEmpty ? "exit \(r.exitCode)" : msg)")
        }
    }

    static func uploadScript(from root: URL, to dest: String) throws -> String {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "true" }
        var files: [(String, String, Bool)] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append((rel, text, fm.isExecutableFile(atPath: url.path)))
        }
        var s = "set -e\nD=\(dest)\numask 022\n"
        for (rel, text, exec) in files.sorted(by: { $0.0 < $1.0 }) {
            var tag = "MBX_EOF_\(UUID().uuidString.prefix(8))"
            while text.contains(tag) { tag += "X" }
            let q = shellQuote(rel)
            s += "mkdir -p \"$D\"/\"$(dirname \(q))\"\ncat > \"$D\"/\(q) <<'\(tag)'\n\(text)\(text.hasSuffix("\n") ? "" : "\n")\(tag)\n"
            s += "chmod \(exec ? "755" : "644") \"$D\"/\(q)\n"
        }
        return s + "echo MBX_UPLOADED\n"
    }
}
