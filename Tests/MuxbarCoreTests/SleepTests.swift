import Foundation
import Testing
@testable import MuxbarCore

/// Descendants as "args" (direct children of the agent, pid 42) or "parentIndex>args" (child of
/// the earlier entry at that index).
func procs(_ desc: [String]) -> [ProcessUsage] {
    desc.enumerated().map { i, d in
        let parts = d.split(separator: ">", maxSplits: 1).map(String.init)
        if parts.count == 2, let pi = Int(parts[0]) { return ProcessUsage(pid: 100 + i, rssKB: 1000, pane: nil, args: parts[1], ppid: 100 + pi) }
        return ProcessUsage(pid: 100 + i, rssKB: 1000, pane: nil, args: d, ppid: 42)
    }
}

func sleepInputs(status: SessionStatus = .idle, prompt: Bool? = true, desc: [String] = [], attached: Int = 1, muxbar: Int = 1,
                 viewing: Bool = false, input: Bool = false, never: Bool = false, idle: Int? = 45, id: String? = "conv") -> SleepPolicy.Inputs {
    SleepPolicy.Inputs(status: status, agent: .claude, agentPID: 42, conversationID: id, promptEmpty: prompt,
                       descendants: procs(desc),
                       attachedClients: attached, muxbarClients: muxbar, viewing: viewing, inputSinceIdle: input,
                       neverSleep: never, idleMinutes: idle, sleeping: false)
}

// Argv of typical descendants of a Claude Code process: telemetry and MCP servers.
let claudeHelpers = [
    "/usr/local/bin/otelcol-contrib --config /home/u/.config/otel/config.yaml",
    "/home/u/.local/bin/github-mcp",
    "/home/u/.local/bin/github-mcp --include-tools search_code,get_issue",
    "node /home/u/.npm/_npx/1a2b3c/node_modules/slack-mcp-server/dist/index.js",
    "/home/u/.local/bin/uvx slack-mcp-server",
]

@Test func sleepPolicyAllowsIdleAgentsWithOnlyHelpers() {
    #expect(SleepPolicy.check(sleepInputs(desc: claudeHelpers), auto: false).isEmpty)
    #expect(SleepPolicy.check(sleepInputs(desc: claudeHelpers), auto: true, autoMinutes: 30).isEmpty)
}

@Test func sleepPolicyRefusals() {
    #expect(SleepPolicy.check(sleepInputs(status: .working), auto: false) == [.notIdle(.working)])
    #expect(SleepPolicy.check(sleepInputs(status: .waiting), auto: false) == [.notIdle(.waiting)])
    #expect(SleepPolicy.check(sleepInputs(prompt: false), auto: false) == [.typedInput])
    // A job started by the agent's Bash tool lives under a shell; MCP servers (even Python ones
    // whose args don't say "mcp" early) are started directly.
    let shell = "/bin/zsh -c source /Users/u/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'python build_index.py'"
    #expect(SleepPolicy.check(sleepInputs(desc: claudeHelpers + [shell, "5>/home/u/.venv/bin/python build_index.py 1 92 13"]), auto: false)
            == [.backgroundJob("python build_index.py")])
    #expect(SleepPolicy.check(sleepInputs(desc: [shell]), auto: false) == [.backgroundJob("zsh")], "a running shell alone counts")
    let pythonServers = ["/opt/homebrew/Cellar/python@3.14/3.14.8/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python /Users/u/src/mock-benchmark/server.py",
                         "/opt/homebrew/bin/uv tool uvx mcp-proxy@latest https://mcp.example.com/mcp",
                         "1>/opt/homebrew/Cellar/python@3.14/3.14.8/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python /Users/u/.cache/uv/archive-v0/x/bin/proxy"]
    #expect(SleepPolicy.check(sleepInputs(desc: pythonServers), auto: false).isEmpty)
    #expect(SleepPolicy.check(sleepInputs(id: nil), auto: false) == [.noConversationID])
    #expect(SleepPolicy.check(sleepInputs(desc: ["<defunct>", "/bin/zsh -c x", "1>[sleep] <defunct>"]), auto: false)
            == [.backgroundJob("zsh")], "zombies aren't jobs")
    #expect(SleepPolicy.check(sleepInputs(desc: ["sh -c 'exec node my-mcp-server'"]), auto: false).isEmpty, "shell-launched MCP server")
    var none = sleepInputs(); none.agent = nil; none.agentPID = nil
    #expect(SleepPolicy.check(none, auto: false) == [.noAgent])
    // Auto-sleep only: on screen, typed since finishing, another terminal, never-sleep, too soon.
    #expect(SleepPolicy.check(sleepInputs(viewing: true), auto: false).isEmpty)
    #expect(SleepPolicy.check(sleepInputs(viewing: true), auto: true) == [.beingViewed])
    #expect(SleepPolicy.check(sleepInputs(input: true), auto: true) == [.recentInput])
    #expect(SleepPolicy.check(sleepInputs(attached: 2, muxbar: 1), auto: true) == [.otherClientAttached])
    #expect(SleepPolicy.check(sleepInputs(attached: 1, muxbar: 0), auto: true) == [.otherClientAttached])
    #expect(SleepPolicy.check(sleepInputs(never: true), auto: true) == [.neverSleep])
    #expect(SleepPolicy.check(sleepInputs(idle: 10), auto: true, autoMinutes: 30) == [.idleTooShort(minutes: 30)])
}

@Test func emptyPromptDetection() {
    let claudeEmpty = ["⏺ done", "────", "❯\u{00A0} ", "────", "  ? for shortcuts"]
    #expect(SleepPolicy.promptEmpty(claudeEmpty, agent: .claude) == true)
    #expect(SleepPolicy.promptEmpty(["────", "❯ half-typed thought", "────"], agent: .claude) == false)
    #expect(SleepPolicy.promptEmpty(["› ", "  ? for help"], agent: .codex) == true)
    #expect(SleepPolicy.promptEmpty(["› fix the", "esc"], agent: .codex) == false)
    #expect(SleepPolicy.promptEmpty(["no prompt here"], agent: .claude) == nil)
}

@Test func sleepCheckScriptFindsDescendantsArgvAndScreen() async throws {
    guard let tmux = findLocalTmux() else { return }
    let sock = "muxbar-unit-sl-\(UUID().uuidString.prefix(6))"
    defer { _ = runWithStdin(tmux, ["-L", sock, "kill-server"], input: "", env: [:]) }
    _ = runWithStdin(tmux, ["-L", sock, "new-session", "-d", "-s", "s1", "sh -c 'sleep 77 & sleep 88; wait'"], input: "", env: ["PATH": "/usr/bin:/bin"])
    var panePID = 0
    for _ in 0..<50 {   // until both children exist (slow under parallel test load)
        try await Task.sleep(nanoseconds: 100_000_000)
        panePID = Int(runWithStdin(tmux, ["-L", sock, "display-message", "-p", "#{pane_pid}"], input: "", env: [:]).1
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let kids = runWithStdin("/usr/bin/pgrep", ["-P", "\(panePID)"], input: "", env: [:]).1.split(separator: "\n")
        if kids.count >= 2 { break }
    }
    let pane = runWithStdin(tmux, ["-L", sock, "display-message", "-p", "#{pane_id}"], input: "", env: [:]).1
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let n = HostProbe.makeNonce()
    let r = await shell("/bin/sh", ["-c", SleepPolicy.checkScript(nonce: n, agentPID: panePID, tmux: TmuxCommands.invocation(shellQuote(tmux), socket: sock), pane: pane)])
    let c = SleepPolicy.parseCheck(r.stdout, nonce: n)
    #expect(c.alive)
    #expect(Set(c.descendants.map(\.args)).isSuperset(of: ["sleep 77", "sleep 88"]), "\(c.descendants)")
    #expect(c.descendants.allSatisfy { $0.ppid == panePID } && c.topPID == panePID)
    #expect(c.argv.first?.hasSuffix("sh") == true && c.argv.contains("-c"), "\(c.argv)")
    #expect(c.freedKB > 0)
    let gone = SleepPolicy.parseCheck(await shell("/bin/sh", ["-c", SleepPolicy.checkScript(nonce: n, agentPID: 999_999, tmux: "true", pane: "%0")]).stdout, nonce: n)
    #expect(!gone.alive)
}
