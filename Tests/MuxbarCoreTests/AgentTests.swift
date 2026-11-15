import Foundation
import Testing
@testable import MuxbarCore

// MARK: - Helpers

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let hookScript = repoRoot.appendingPathComponent("agent-plugin/plugins/muxbar-status/bin/muxbar-hook").path

func fixtureText(_ rel: String) throws -> String {
    let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(rel)
    return try String(contentsOf: url, encoding: .utf8)
}

/// Runs a process with `input` on stdin (runProcess always passes /dev/null).
func runWithStdin(_ path: String, _ args: [String], input: String, env: [String: String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = env
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = outPipe
    try? p.run()
    inPipe.fileHandleForWriting.write(Data(input.utf8))
    try? inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, out)
}

/// Runs the hook as an agent would (payload on stdin, inside a tmux pane) and reads what it wrote.
func runHook(_ agent: String, _ event: String, payload: String, pane: String? = "%7",
             tmux: String = "/tmp/muxbar-unit-sock,123,0") throws -> (HookState?, String, Double) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-hook-\(UUID().uuidString)")
    var env = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "MUXBAR_STATE_DIR": dir.path, "TMUX": tmux]
    if let pane { env["TMUX_PANE"] = pane }
    let t0 = Date()
    let (code, out) = runWithStdin("/bin/sh", [hookScript, agent, event], input: payload, env: env)
    let dt = Date().timeIntervalSince(t0)
    #expect(code == 0, "hook must always exit 0")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".json") } ?? []
    let line = files.first.flatMap { try? String(contentsOfFile: dir.appendingPathComponent($0).path, encoding: .utf8) }
    try? FileManager.default.removeItem(at: dir)
    return (line.flatMap(HookState.parse), out, dt)
}

// MARK: - The hook script, fed real captured payloads (Claude Code 2.1.296) and Codex's schema

@Test(arguments: [
    ("claude", "SessionStart", "claude/SessionStart.json", HookState.State.idle, "startup"),
    ("claude", "UserPromptSubmit", "claude/UserPromptSubmit.json", .working, ""),
    ("claude", "PreToolUse", "claude/PreToolUse.json", .working, ""),
    ("claude", "PermissionRequest", "claude/PermissionRequest.json", .waiting, "permission"),
    ("claude", "Notification", "claude/Notification.json", .waiting, "permission"),
    ("claude", "PostToolUse", "claude/PostToolUse.json", .working, ""),
    ("claude", "Stop", "claude/Stop.json", .idle, "done"),
    ("claude", "SessionEnd", "claude/SessionEnd.json", .ended, ""),
    ("codex", "SessionStart", "codex/SessionStart-synthetic.json", .idle, "startup"),
    ("codex", "UserPromptSubmit", "codex/UserPromptSubmit-synthetic.json", .working, ""),
    ("codex", "PermissionRequest", "codex/PermissionRequest-synthetic.json", .waiting, "permission"),
    ("codex", "Stop", "codex/Stop-synthetic.json", .idle, "done"),
    ("codex", "Interrupt", "codex/Interrupt-synthetic.json", .idle, "interrupted"),
    ("codex", "SessionEnd", "codex/SessionEnd-synthetic.json", .ended, ""),
])
func hookScriptMapsEvents(_ c: (String, String, String, HookState.State, String)) throws {
    let payload = try fixtureText("hooks/" + c.2)
    let (h, out, _) = try runHook(c.0, c.1, payload: payload)
    let sid = (try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])?["session_id"] as? String
    #expect(h?.state == c.3, "\(c.2)")
    #expect(h?.reason == c.4, "\(c.2)")
    #expect(h?.agent.rawValue == c.0 && h?.pane == "%7" && h?.event == c.1)
    #expect(h?.sessionID == sid && !(h?.cwd.isEmpty ?? true))
    #expect(out.isEmpty, "the hook must print nothing")
}

@Test func hookScriptIsFast() throws {
    // Agents run hooks around every tool call, so the hook must be cheap: one awk pass. Measured as
    // CPU time (user + sys of the hook and its children): wall time swings with the other tests
    // running in parallel.
    let payload = try fixtureText("hooks/claude/PostToolUse.json")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-hookcpu-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var cpu: [Double] = []
    for _ in 0..<5 {
        let (_, out) = runWithStdin("/usr/bin/time", ["-p", "/bin/sh", hookScript, "claude", "PostToolUse"], input: payload,
                                    env: ["PATH": "/usr/bin:/bin", "MUXBAR_STATE_DIR": dir.path, "TMUX": "/tmp/s,1,0", "TMUX_PANE": "%7"])
        func val(_ k: String) -> Double {
            out.split(separator: "\n").first { $0.hasPrefix(k + " ") }.flatMap { Double($0.split(separator: " ").last ?? "") } ?? 9
        }
        cpu.append(val("user") + val("sys"))
    }
    let best = cpu.min() ?? 9
    #expect(best <= 0.05, "CPU \(cpu)")
}

@Test func hookScriptKeepsAShortSafeReply() throws {
    let (claude, _, _) = try runHook("claude", "Stop", payload: try fixtureText("hooks/claude/Stop.json"))
    #expect(claude?.reply == "OK")
    let (after, _, _) = try runHook("claude", "Stop", payload: try fixtureText("hooks/claude/Stop-after-tool.json"))
    #expect(after?.reply == "Wed Oct 14 14:00:48 PDT 2026")
    let (codex, _, _) = try runHook("codex", "Stop", payload: try fixtureText("hooks/codex/Stop-synthetic.json"))
    #expect(codex?.reply == "All 12 tests pass. I fixed the 'off by one' in parse().")
    let long = #"{"session_id":"s1","cwd":"/x","last_assistant_message":""# + String(repeating: "é\\\"x", count: 400) + #""}"#
    let (h, _, _) = try runHook("codex", "Stop", payload: long)
    #expect(h != nil && h!.reply.count <= 300 && !h!.reply.contains("\""))
}

@Test func hookScriptQuestionsIdleAndIgnoredEvents() throws {
    let ask = #"{"session_id":"s1","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#
    #expect(try runHook("claude", "PreToolUse", payload: ask).0.map { ($0.state, $0.reason) } ?? (.ended, "") == (.waiting, "question"))
    let idle = #"{"session_id":"s1","cwd":"/x","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
    #expect(try runHook("claude", "Notification", payload: idle).0?.state == .idle)
    let auth = #"{"session_id":"s1","cwd":"/x","message":"Signed in","notification_type":"auth_success"}"#
    #expect(try runHook("claude", "Notification", payload: auth).0 == nil, "unrelated notifications change nothing")
    #expect(try runHook("claude", "SubagentStop", payload: "{}").0 == nil)
    // Outside tmux there's no pane to report for.
    #expect(try runHook("claude", "Stop", payload: try fixtureText("hooks/claude/Stop.json"), pane: nil).0 == nil)
}

@Test func hookStateFileIsPrivateAndPerServer() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-hook-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for (sock, pane) in [("/tmp/srv-a", "%1"), ("/tmp/srv-b", "%1")] {
        _ = runWithStdin("/bin/sh", [hookScript, "claude", "UserPromptSubmit"], input: "{\"session_id\":\"s\"}",
                         env: ["PATH": "/usr/bin:/bin", "MUXBAR_STATE_DIR": dir.path, "TMUX": sock + ",1,0", "TMUX_PANE": pane])
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(files.count == 2, "same pane number on two tmux servers must not collide: \(files)")
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(files[0]).path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
}

// MARK: - Hook state, fusion, adapters

@Test func hookStateParses() {
    let h = HookState.parse(#"{"v":1,"agent":"codex","pane":"%3","event":"Stop","state":"idle","reason":"done","sid":"t1","transcript":"/t","cwd":"/c","reply":"hi","ts":1700000000}"#)
    #expect(h == HookState(agent: .codex, pane: "%3", event: "Stop", state: .idle, reason: "done", sessionID: "t1",
                           transcript: "/t", cwd: "/c", reply: "hi", ts: 1_700_000_000))
    #expect(HookState.parse("not json") == nil)
    #expect(HookState.parse(#"{"agent":"gemini","pane":"%1","state":"idle","ts":1}"#) == nil)
    #expect(HookState.parse(#"{"agent":"claude","pane":"1","state":"idle","ts":1}"#) == nil)
}

@Test func statusFusionRules() {
    func h(_ s: HookState.State, ts: Int = 100) -> HookState { HookState(agent: .claude, pane: "%1", event: "", state: s, ts: ts) }
    typealias R = (SessionStatus, StatusSource)
    func c(_ hook: HookState?, _ heur: SessionStatus, age: Int? = 1, alive: Bool = true, started: Int? = 50) -> R {
        StatusFusion.combine(hook: hook, heuristic: heur, outputAge: age, agentAlive: alive, agentStartedAt: started, now: 200)
    }
    #expect(c(nil, .idle) == (.idle, .screen))
    #expect(c(h(.waiting), .unknown, alive: false) == (.unknown, .screen), "no live agent → hooks ignored")
    #expect(c(h(.waiting, ts: 100), .unknown, started: 150) == (.unknown, .screen), "hook older than the agent → stale")
    #expect(c(h(.waiting), .idle) == (.waiting, .hooks))
    #expect(c(h(.working), .idle, age: 25) == (.idle, .hooks), "Esc interrupt: idle screen, quiet 20s+")
    #expect(c(h(.working), .idle, age: 5) == (.working, .hooks))
    #expect(c(h(.working), .unknown, age: 600) == (.working, .hooks), "long tool run stays working")
    #expect(c(h(.working), .waiting) == (.waiting, .hooks))
    #expect(c(h(.idle), .waiting) == (.waiting, .hooks))
    #expect(c(h(.idle), .working) == (.idle, .hooks))
    #expect(c(h(.ended), .notClaude) == (.notClaude, .screen))
    #expect(StatusFusion.sessionStatus([(.idle, .hooks), (.waiting, .screen), (.working, .hooks)])! == (.waiting, .screen))
    #expect(StatusFusion.sessionStatus([(.idle, .screen), (.idle, .hooks)])! == (.idle, .hooks))
}

@Test func agentKindFromProcess() {
    #expect(AgentAdapter.kind(argv0: "claude", args: "claude --model opus") == .claude)
    #expect(AgentAdapter.kind(argv0: "/home/u/.local/share/claude/versions/2.1.295/claude", args: "") == .claude)
    #expect(AgentAdapter.kind(argv0: "2.1.296", args: "2.1.296") == .claude)
    #expect(AgentAdapter.kind(argv0: "codex", args: "codex resume x") == .codex)
    #expect(AgentAdapter.kind(argv0: "codex-aarch64-apple-darwin", args: "") == .codex)
    #expect(AgentAdapter.kind(argv0: "node", args: "node /usr/local/bin/claude --resume x") == .claude)
    #expect(AgentAdapter.kind(argv0: "node", args: "node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js") == .codex)
    #expect(AgentAdapter.kind(argv0: "/usr/bin/python3", args: "/usr/bin/python3 /tmp/muxbar-e2e-fake/bin/codex resume a") == .codex)
    #expect(AgentAdapter.kind(argv0: "node", args: "node server.js") == nil)
    #expect(AgentAdapter.kind(argv0: "python3", args: "python3 build_index.py 1 92 13") == nil)
    #expect(AgentAdapter.kind(argv0: "claude-helper", args: "") == nil)
}

@Test func keptFlagsAndResumeCommands() {
    // A wrapper that injects --settings JSON: that is dropped, the user's own flags are kept.
    let wrapped = ["/home/u/.local/share/claude/versions/2.1.295/claude", "--settings", #"{"modelPicker":{}}"#,
                "--model", "opus", "--dangerously-skip-permissions", "--resume", "old"]
    #expect(AgentAdapter.keptFlags(.claude, argv: wrapped) == ["--model", "opus", "--dangerously-skip-permissions"])
    #expect(AgentAdapter.keptFlags(.claude, argv: ["claude", "--permission-mode=plan", "--weird"]) == ["--permission-mode=plan"])
    #expect(AgentAdapter.keptFlags(.claude, argv: ["claude", "--plugin-dir", "/p/muxbar-status"]) == ["--plugin-dir", "/p/muxbar-status"])
    #expect(AgentAdapter.keptFlags(.codex, argv: ["codex", "resume", "x", "-m", "gpt-6", "--yolo", "-C", "/p"]) == ["-m", "gpt-6", "--yolo"])
    #expect(AgentAdapter.resumeCommand(.claude, sessionID: "ab-12", cwd: "/x", flags: ["--model", "opus"])
            == "claude --resume 'ab-12' '--model' 'opus'")
    #expect(AgentAdapter.resumeCommand(.codex, sessionID: "thr_1", cwd: "~/p q", flags: [])
            == "codex resume 'thr_1' -C \"$HOME\"/'p q'")
}

@Test func elapsedTimes() {
    #expect(parseElapsed("42") == 42)
    #expect(parseElapsed("05:07") == 307)
    #expect(parseElapsed("01:02:03") == 3723)
    #expect(parseElapsed("2-00:00:10") == 172_810)
    #expect(parseElapsed("x") == nil)
}

// MARK: - Probe v2

@Test func probeV2ParsesPanesAgentsHooksAndMemory() throws {
    let n = "v2"
    let hook = #"{"v":1,"agent":"claude","pane":"%5","event":"PermissionRequest","state":"waiting","reason":"permission","sid":"s-9","transcript":"/t.jsonl","cwd":"/w","reply":"","ts":990}"#
    let out = probeOutput(n, [
        "@@VER tmux 3.6a", "@@NOW 1000", "@@SOCK 12345",
        "@@S~|~$2~|~900~|~990~|~1~|~agent",
        "@@P~|~$2~|~1~|~1~|~zsh~|~995~|~%5~|~200~|~/w",
        "@@P~|~$2~|~0~|~1~|~bash~|~950~|~%6~|~201~|~/w",
        "@@C2~|~%5~|~$2~|~409600~|~6~|~zsh\u{1F}claude\u{1F}node\u{1F}",
        "@@C2~|~%6~|~$2~|~1024~|~1~|~bash\u{1F}",
        "@@AG~|~%5~|~4242~|~claude~|~03:20~|~400000~|~claude --model opus",
        "@@XA~|~%6~|~777", "@@XR~|~777~|~2097152",
        "@@H~|~" + hook,
        "@@MEM~|~Linux~|~32000000~|~8000000~|~0~|~0~|~1.5 1.2 0.9~|~16",
    ])
    let r = try HostProbe.parse(out, nonce: n)
    #expect(r.serverHash == "12345")
    #expect(r.panes.map(\.id) == ["%5", "%6"])
    let p5 = r.panes[0], p6 = r.panes[1]
    #expect(p5.active && !p6.active && p5.pid == 200)
    #expect(p5.agents == [AgentProcess(kind: .claude, pid: 4242, ageSeconds: 200, rssKB: 400_000, args: "claude --model opus")])
    #expect(p5.hook?.state == .waiting && p5.hook?.sessionID == "s-9")
    #expect(p6.memoryKB == 1024 + 2_097_152 && p6.escapedKB == 2_097_152)
    #expect(r.sessions[0].memoryKB == 409_600 + 1024 + 2_097_152)
    #expect(r.sessions[0].processes == ["zsh", "claude", "node"] && r.sessions[0].activePane == "%5")
    #expect(r.memory == HostMemory(os: "Linux", totalKB: 32_000_000, availableKB: 8_000_000, load: [1.5, 1.2, 0.9], cpus: 16))
    #expect(Int(r.memory!.usedPercent) == 75)
}

@Test func reconcilerUsesHooksAndRemembersTheConversation() throws {
    let n = "rc"
    func probe(_ hookState: String, agentAge: String = "03:20") throws -> ProbeResult {
        let hook = #"{"v":1,"agent":"claude","pane":"%5","event":"x","state":""# + hookState + #"","reason":"permission","sid":"conv-1","transcript":"/t","cwd":"/w","reply":"","ts":990}"#
        return try HostProbe.parse(probeOutput(n, [
            "@@VER tmux 3.6a", "@@NOW 1000",
            "@@S~|~$2~|~900~|~990~|~1~|~agent",
            "@@P~|~$2~|~1~|~1~|~zsh~|~999~|~%5~|~200~|~/w",
            "@@C2~|~%5~|~$2~|~4096~|~2~|~zsh\u{1F}claude\u{1F}",
            "@@AG~|~%5~|~4242~|~claude~|~" + agentAge + "~|~4000~|~claude",
            "@@H~|~" + hook,
            "@@CAP $2", "some text",
        ]), nonce: n)
    }
    var st = AppState()
    let live = Reconciler.apply(try probe("waiting"), host: "h", to: &st)
    let key = sessionKey(host: "h", tmuxID: "$2", created: 900)
    #expect(live[key]?.status == .waiting && live[key]?.source == .hooks && live[key]?.reason == "permission")
    #expect(st.sessions[key]?.agent == .claude && st.sessions[key]?.agentSessionID == "conv-1")
    #expect(st.sessions[key]?.claudeSessionID == "conv-1")
    // A hook written before this claude process started (plugin not loaded in it) is ignored.
    let stale = Reconciler.apply(try probe("waiting", agentAge: "1"), host: "h", to: &st)
    #expect(stale[key]?.source == .screen)
    // ... and so is its conversation: a fresh session in a pane with that id (tmux restarted, e.g.
    // after a reboot) keeps the conversation it really has.
    var fresh = AppState()
    _ = Reconciler.apply(try probe("waiting", agentAge: "1"), host: "h", to: &fresh)
    #expect(fresh.sessions[key]?.agentSessionID == nil && fresh.sessions[key]?.claudeSessionID == nil)
}

@Test func probeV2ScriptRunsAgainstRealTmux() async throws {
    guard let tmux = findLocalTmux() else { return }
    let sock = "muxbar-unit-\(UUID().uuidString.prefix(8))"
    let hookDir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-hd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
    defer {
        _ = runWithStdin(tmux, ["-L", sock, "kill-server"], input: "", env: [:])
        try? FileManager.default.removeItem(at: hookDir)
    }
    _ = runWithStdin(tmux, ["-L", sock, "new-session", "-d", "-s", "u1", "sleep 30"], input: "", env: ["PATH": "/usr/bin:/bin"])
    // A stale file for a pane that doesn't exist must be cleaned up; a current one is read.
    let pane = runWithStdin(tmux, ["-L", sock, "display-message", "-p", "#{pane_id}"], input: "", env: [:]).1
        .trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
    try #"{"v":1,"agent":"claude","pane":"%\#(pane)","event":"Stop","state":"idle","reason":"done","sid":"x","transcript":"","cwd":"/","reply":"","ts":1}"#
        .write(toFile: hookDir.appendingPathComponent("\(sock)@\(pane).json").path, atomically: true, encoding: .utf8)
    try "{}".write(toFile: hookDir.appendingPathComponent("\(sock)@999.json").path, atomically: true, encoding: .utf8)
    try "{}".write(toFile: hookDir.appendingPathComponent("other-server@999.json").path, atomically: true, encoding: .utf8)
    let nonce = HostProbe.makeNonce()
    let script = HostProbe.script(mode: .status, nonce: nonce, tmux: shellQuote(tmux), socket: sock,
                                  hookDir: shellQuote(hookDir.path))
    let r = await shell("/bin/sh", ["-c", script])
    let p = try HostProbe.parse(r.stdout, nonce: nonce)
    #expect(p.sessions.map(\.name) == ["u1"])
    #expect(p.panes.count == 1 && p.panes[0].hook?.state == .idle)
    #expect(p.sessions[0].memoryKB > 0, "sleep's RSS is counted")
    #expect(p.memory.map { $0.totalKB > 1_000_000 && $0.availableKB > 0 && $0.availableKB <= $0.totalKB } == true)
    #expect(!FileManager.default.fileExists(atPath: hookDir.appendingPathComponent("\(sock)@999.json").path), "stale pane file removed")
    #expect(FileManager.default.fileExists(atPath: hookDir.appendingPathComponent("other-server@999.json").path),
            "another tmux server's files are left alone")
}

@Test func oldSessionRecordsDecodeWithDefaults() throws {
    let old = #"{"key":"h|$1|1","host":"h","tmuxID":"$1","created":1,"name":"a","ended":false,"tags":[],"archived":false,"claudeSessionID":"c-1"}"#
    let r = try JSONDecoder().decode(SessionRecord.self, from: Data(old.utf8))
    #expect(r.agentSessionID == "c-1" && r.resumeID == "c-1" && !r.unread && r.sleep == nil && !r.neverSleep)
    let again = try JSONDecoder().decode(SessionRecord.self, from: try JSONEncoder().encode(r))
    #expect(again == r)
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminal":"embedded"}"#.utf8))
    #expect(settings.notifyOnFinish && settings.memCritPct == 90 && settings.autoSleepMinutes == nil && settings.wakeOnOpen)
}

// MARK: - Hook install scripts

@Test func codexHooksMergeKeepsOtherHandlersAndRemovesExactlyOurs() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-cx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify"}]}]},"description":"mine"}"#
    let path = home.appendingPathComponent("hooks.json").path
    try original.write(toFile: path, atomically: true, encoding: .utf8)
    func run(_ mode: String) async -> HookInstall.Outcome {
        let r = await shell("/bin/sh", ["-c", HookInstall.codexScript(mode, codexHome: home.path, hookCommand: "~/.muxbar/h")])
        return HookInstall.codexOutcome(r.stdout)
    }
    #expect(await run("status").state == .notInstalled)
    #expect(await run("install").state == .installed)
    let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    let hooks = installed["hooks"] as! [String: [[String: Any]]]
    let all = hooks.values.flatMap { $0 }.flatMap { $0["hooks"] as! [[String: Any]] }
    #expect(all.filter { ($0["statusMessage"] as? String) == "muxbar-status" }.count == HookInstall.codexEvents.count)
    #expect(all.contains { ($0["command"] as? String) == "/usr/local/bin/notify" })
    let ours = all.first { ($0["statusMessage"] as? String) == "muxbar-status" }!["command"] as! String
    #expect(ours.hasPrefix("\"" + NSHomeDirectory() + "/.muxbar/h\" codex "), "absolute path: \(ours)")
    #expect(installed["description"] as? String == "mine")
    #expect(await run("status").state == .installed)
    #expect(await run("install").state == .installed, "installing twice doesn't duplicate")
    let twice = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    #expect(((twice["hooks"] as! [String: [[String: Any]]])["Stop"]?.count) == 2)
    #expect(await run("uninstall").state == .notInstalled)
    let after = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! NSDictionary
    #expect(after == (try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary))
    let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.contains("muxbar-backup") }
    #expect(backups.count >= 1)
    try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(await run("install").state == .unknown, "a broken hooks.json is left alone")
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "{ not json")
}

@Test func claudeInstallOutcomes() {
    #expect(HookInstall.claudeOutcome("Added\nMBX_RC_MARKET 0\nInstalled\nMBX_RC_INSTALL 0\n", installing: true).state == .installed)
    #expect(HookInstall.claudeOutcome("MBX_RC_MARKET 1\nPlugin already installed\nMBX_RC_INSTALL 1\n", installing: true).state == .installed)
    #expect(HookInstall.claudeOutcome("Error: blocked by managed policy\nMBX_RC_INSTALL 1\n", installing: true).state == .blocked)
    #expect(HookInstall.claudeOutcome("MBX_NOAGENT\n", installing: true).state == .agentMissing)
    #expect(HookInstall.claudeOutcome("Uninstalled\nMBX_RC_UNINSTALL 0\n", installing: false).state == .notInstalled)
    #expect(HookInstall.claudeState("rc stuff\nMBX_JSON_BEGIN\n[{\"id\":\"muxbar-status@muxbar\",\"enabled\":true}]\nMBX_JSON_END") == .installed)
    #expect(HookInstall.claudeState("MBX_JSON_BEGIN\n[{\"id\":\"other@example\",\"enabled\":true}]\nMBX_JSON_END") == .notInstalled)
    #expect(HookInstall.claudeState("MBX_JSON_BEGIN\n[{\"id\":\"muxbar-status@muxbar\",\"enabled\":false}]\nMBX_JSON_END") == .notInstalled)
    // Real installs run in the user's login shell (PATH from ~/.zshrc); tests use a fixed folder.
    #expect(HookInstall.claudeInstallScript(binDir: nil).hasPrefix("\"${SHELL:-/bin/sh}\" -lic "))
    #expect(HookInstall.claudeInstallScript(binDir: "/tmp/stub").contains("'/tmp/stub/claude' plugin install muxbar-status@muxbar"))
}

@Test func anInterruptedTurnEndsAStaleWorkingHookStateAtOnce() {
    let now = 1_800_000_000
    let h = HookState(agent: .claude, pane: "%1", event: "PreToolUse", state: .working, ts: now - 30)
    // Esc fires no hook: the last state says working. Fresh output (a status line redraw) used to
    // keep it working; the Interrupted line on screen ends it.
    #expect(StatusFusion.combine(hook: h, heuristic: .idle, outputAge: 1, agentAlive: true, agentStartedAt: now - 600,
                                 now: now, interrupted: true) == (.idle, .hooks))
    #expect(StatusFusion.combine(hook: h, heuristic: .idle, outputAge: 1, agentAlive: true, agentStartedAt: now - 600,
                                 now: now) == (.working, .hooks))
    let screen = ["❯ fix the build", "⏺ Bash(make)", "  ⎿  Interrupted · What should Claude do instead?", "", "────", "❯ ", "────"]
    #expect(StatusClassifier.interruptedLatestTurn(screen))
    // A new prompt after the interruption: no longer interrupted.
    #expect(!StatusClassifier.interruptedLatestTurn(screen + ["❯ try again"]))
    #expect(!StatusClassifier.interruptedLatestTurn(nil))
    // The real screen captured after Esc (Claude Code 2.1.296).
    let real = (try? fixtureText("status/idle-after-interrupt.txt"))?.components(separatedBy: "\n")
    #expect(StatusClassifier.interruptedLatestTurn(real))
}

