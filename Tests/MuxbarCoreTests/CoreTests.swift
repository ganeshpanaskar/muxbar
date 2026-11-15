import Foundation
import Testing
@testable import MuxbarCore

// MARK: - Quoting (three layers: Swift → login shell of ssh → sh -c → command)

let hostileNames = [
    "plain", "with space", "it's", "q'uo\"te", "$HOME", "`id`", "a;b", "semi; rm -rf /tmp/nope",
    "back\\slash", "uni-😀-名前", "muxbar-e2e-'q $x;y", "-leading-dash", "*glob?", "new\nline",
]

func shell(_ path: String, _ args: [String], env: [String: String]? = nil) async -> RunResult {
    await runProcess(path, args, timeout: 10, environment: env)
}

@Test(arguments: hostileNames)
func quotingSurvivesSh(_ name: String) async {
    let r = await shell("/bin/sh", ["-c", "printf %s " + shellQuote(name)])
    #expect(r.stdout == name)
}

@Test(arguments: hostileNames)
func quotingSurvivesSshStyleDoubleLayer(_ name: String) async {
    // ssh hands the remote login shell one string; we wrap our script in `sh -c '<script>'`.
    let script = "printf %s " + shellQuote(name)
    let remote = "sh -c " + shellQuote(script)
    for loginShell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
        let r = await shell(loginShell, ["-c", remote])
        #expect(r.stdout == name, "via \(loginShell)")
    }
}

@Test(arguments: hostileNames)
func paneCommandRunsUserCommandThenShell(_ name: String) async {
    // tmux runs the pane command via the user's shell; SHELL=/bin/sh with stdin closed exits at once.
    let cmd = TmuxCommands.paneCommand("printf %s " + shellQuote(name))
    let r = await shell("/bin/zsh", ["-c", cmd], env: ["SHELL": "/bin/sh", "HOME": NSHomeDirectory()])
    #expect(r.stdout.hasPrefix(name))
}

@Test func pathQuotingKeepsTilde() async {
    let r = await shell("/bin/sh", ["-c", "printf %s " + shellQuotePath("~/a b")], env: ["HOME": "/h"])
    #expect(r.stdout == "/h/a b")
    #expect(shellQuotePath("/x/'y") == "'/x/'\\''y'")
}

@Test func sanitize() {
    #expect(sanitizeSessionName("My Session.v2:x") == "My-Session-v2-x")
    #expect(sanitizeSessionName("  ") == "session")
    #expect(sanitizeSessionName("ok_name-1") == "ok_name-1")
    #expect(sanitizeSessionName("a'b\"c;d") == "a-b-c-d")
}

@Test func commandsTargetByIDNotName() {
    #expect(TmuxCommands.rename(id: "$3", newName: "x y") == "tmux rename-session -t '$3' 'x y'")
    #expect(TmuxCommands.kill(id: "$12") == "tmux kill-session -t '$12'")
    #expect(TmuxCommands.attachRemote(host: "devbox", id: "$3", sshConfigFile: nil)
            == "ssh -t 'devbox' 'tmux attach-session -t '\\''$3'\\'''")
    #expect(!TmuxCommands.newSession(name: "n", dir: "~", command: "claude").contains(" -e "))
}

// MARK: - tmux versions

@Test func tmuxVersions() {
    #expect(tmuxVersionSupported("tmux 3.6a"))
    #expect(tmuxVersionSupported("tmux 2.6"))
    #expect(tmuxVersionSupported("tmux next-3.4"))
    #expect(tmuxVersionSupported("tmux master"))
    #expect(!tmuxVersionSupported("tmux 1.8"))
    #expect(!tmuxVersionSupported("tmux 2.5"))
    #expect(!tmuxVersionSupported("garbage"))
}

// MARK: - Probe parsing

func probeOutput(_ nonce: String, _ body: [String]) -> String {
    // Only tag lines like "@@VER …" (uppercase tag); other "@@…" lines are pane text.
    (body.map { l in
        guard l.hasPrefix("@@"), let c = l.dropFirst(2).first, c.isUppercase else { return l }
        return "@@\(nonce) " + l.dropFirst(2)
    } + ["@@\(nonce) END"]).joined(separator: "\n")
}

@Test func parsesProbe() throws {
    let n = "abc123"
    let out = probeOutput(n, [
        "@@VER tmux 3.6a",
        "@@NOW 1000",
        "@@S~|~$0~|~900~|~990~|~1~|~main",
        "@@S~|~$1~|~901~|~950~|~0~|~name~|~with\ttab",
        "@@P~|~$0~|~1~|~1~|~zsh~|~995~|~%0~|~100~|~/home/u/proj",
        "@@P~|~$0~|~0~|~1~|~vim~|~990~|~%1~|~101~|~/elsewhere",
        "@@P~|~$1~|~1~|~1~|~bash~|~950~|~%2~|~102~|~/tmp/x y",
        "@@C2~|~%0~|~$0~|~2048~|~3~|~zsh\u{1F}claude\u{1F}<defunct>\u{1F}",
        "@@CAP $0",
        "line one",
        "@@zzz-not-a-marker",
        "",
        "",
        "@@CAP $1",
    ])
    let r = try HostProbe.parse(out, nonce: n)
    #expect(r.tmuxVersion == "tmux 3.6a")
    #expect(r.hostNow == 1000)
    #expect(r.sessions.count == 2)
    #expect(r.sessions[0].path == "/home/u/proj")
    #expect(r.sessions[0].windowActivity == 995)
    #expect(r.sessions[0].processes == ["zsh", "claude"])
    #expect(r.sessions[0].capture == ["line one", "@@zzz-not-a-marker"])
    #expect(r.sessions[1].name == "name~|~with\ttab")
    #expect(r.sessions[1].path == "/tmp/x y")
    #expect(r.sessions[1].capture == [])
}

@Test func probeNoServerIsEmptyNotError() throws {
    let r = try HostProbe.parse(probeOutput("n", ["@@VER tmux 3.2a", "@@NOW 5"]), nonce: "n")
    #expect(r.sessions.isEmpty && !r.tmuxMissing)
}

@Test func probeNoTmux() throws {
    let r = try HostProbe.parse("@@n NOTMUX\n", nonce: "n")
    #expect(r.tmuxMissing)
}

@Test func probeTruncatedThrows() {
    #expect(throws: HostProbe.ParseError.truncated) {
        try HostProbe.parse("@@n VER tmux 3.2\n@@n S~|~$0~|~1~|~1~|~0~|~x", nonce: "n")
    }
}

@Test func probeScriptRunsAgainstRealSh() async throws {
    // No tmux on PATH → NOTMUX, proving the script is valid sh end to end.
    let n = HostProbe.makeNonce()
    let script = HostProbe.script(mode: .status, nonce: n, tmux: "muxbar-no-such-tmux")
    let r = await shell("/bin/sh", ["-c", script])
    #expect(try HostProbe.parse(r.stdout, nonce: n).tmuxMissing)
}

@Test func lastNonBlank() {
    #expect(HostProbe.lastNonBlank(["a", "b", " ", ""], count: 1) == ["b"])
    #expect(HostProbe.lastNonBlank([], count: 3) == [])
}

// MARK: - SSH error classification

@Test func sshErrors() {
    let dns = """
    \u{1B}[31mssh: Could not resolve hostname devbox: nodename nor servname provided, or not known
    \u{1B}[0mConnection closed by UNKNOWN port 65535
    """
    #expect(classifySSHFailure(stderr: dns, exitCode: 255, timedOut: false) == .unreachable)
    #expect(classifySSHFailure(stderr: "Connection timed out during banner exchange", exitCode: 255, timedOut: false) == .unreachable)
    #expect(classifySSHFailure(stderr: "user@host: Permission denied (publickey).", exitCode: 255, timedOut: false) == .authExpired)
    #expect(classifySSHFailure(stderr: "Authentication failed.", exitCode: 255, timedOut: false) == .authExpired)
    #expect(classifySSHFailure(stderr: "", exitCode: 0, timedOut: true) == .unreachable)
    #expect(classifySSHFailure(stderr: "sh: 1: oops", exitCode: 2, timedOut: false) == .other)
    let cleaned = cleanSSHStderr("** WARNING: connection is not using a post-quantum key exchange algorithm.\n** This session may be vulnerable to \"store now, decrypt later\" attacks.\n** The server may need to be upgraded. See https://openssh.com/pq.html\nreal error")
    #expect(cleaned == "real error")
}

// MARK: - SSH config parsing

@Test func sshConfigHosts() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let inc = dir.appendingPathComponent("extra.conf")
    try "Host incl-host\n  HostName x\n".write(to: inc, atomically: true, encoding: .utf8)
    let main = dir.appendingPathComponent("config")
    try """
    # comment
    Host box-a box-b
      HostName a
    Host *.example.com !bad
    Host=eq-host
    Include \(inc.path)
    Host box-a
    """.write(to: main, atomically: true, encoding: .utf8)
    #expect(parseSSHHosts(configPath: main.path) == ["box-a", "box-b", "eq-host", "incl-host"])
}

@Test func controlSocketPathFitsMacOSLimit() {
    #expect(MuxbarPaths.worstCaseSocketPathLength < 104)
}

// MARK: - Reconciler

@Test func reconcileRenameRecycleAndEnd() {
    var st = AppState()
    let p1 = ProbeResult(tmuxVersion: "tmux 3.6a", tmuxMissing: false, sessions: [
        ProbedSession(id: "$0", name: "a", created: 100, activity: 110, attached: 0, path: "/p"),
        ProbedSession(id: "$1", name: "b", created: 101, activity: 111, attached: 1),
    ], hostNow: 200)
    Reconciler.apply(p1, host: "h", to: &st)
    #expect(st.sessions.count == 2)
    st.sessions[sessionKey(host: "h", tmuxID: "$0", created: 100)]?.note = "keep me"

    // Rename $0, $1 disappears, server restart recycles $1 with new created time.
    let p2 = ProbeResult(tmuxVersion: "tmux 3.6a", tmuxMissing: false, sessions: [
        ProbedSession(id: "$0", name: "a-renamed", created: 100, activity: 120, attached: 0),
        ProbedSession(id: "$1", name: "new", created: 300, activity: 301, attached: 0),
    ], hostNow: 400)
    Reconciler.apply(p2, host: "h", to: &st)
    let a = st.sessions[sessionKey(host: "h", tmuxID: "$0", created: 100)]!
    #expect(a.name == "a-renamed" && a.note == "keep me" && a.path == "/p" && !a.ended)
    #expect(st.sessions[sessionKey(host: "h", tmuxID: "$1", created: 101)]!.ended)
    #expect(st.sessions[sessionKey(host: "h", tmuxID: "$1", created: 300)]!.name == "new")

    // Other hosts untouched; dismiss removes only ended.
    st.sessions["other|$0|1"] = SessionRecord(key: "other|$0|1", host: "other", tmuxID: "$0", created: 1, name: "o")
    Reconciler.apply(ProbeResult(tmuxVersion: nil, tmuxMissing: false, sessions: [], hostNow: nil), host: "h2", to: &st)
    #expect(st.sessions["other|$0|1"]?.ended == false)
    Reconciler.dismissEnded(host: "h", in: &st)
    #expect(st.sessions.count == 3)
}

// MARK: - Persistence

@Test func persistenceRoundTripAndCorruptRecovery() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-p-\(UUID().uuidString)")
    let path = dir.appendingPathComponent("state.json").path
    var st = AppState()
    st.hosts.append("devbox")
    st.rememberDir("~/a", host: "devbox")
    st.settings.terminal = .iterm
    try Persistence.save(st, path: path)
    let (loaded, outcome) = Persistence.load(path: path)
    #expect(outcome == .loaded && loaded == st)

    try "{not json".write(toFile: path, atomically: true, encoding: .utf8)
    let (recovered, outcome2) = Persistence.load(path: path)
    #expect(recovered == AppState())
    guard case .recoveredFromCorrupt(let moved) = outcome2 else { Issue.record("expected recovery"); return }
    #expect(FileManager.default.fileExists(atPath: moved))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func recentDirsAreMRUAndCapped() {
    var st = AppState()
    for i in 0..<15 { st.rememberDir("/d\(i)", host: "h") }
    st.rememberDir("/d3", host: "h")
    #expect(st.recentDirs["h"]!.first == "/d3")
    #expect(st.recentDirs["h"]!.count == 10)
}

// MARK: - Reattach policy

@Test func reattachSafety() {
    #expect(isSafeToReattach(lastLine: "user@mac ~ % "))
    #expect(isSafeToReattach(lastLine: "[user@host ~]$ "))
    #expect(isSafeToReattach(lastLine: "[Process completed]"))
    #expect(isSafeToReattach(lastLine: "Connection to devbox.example.com closed."))
    #expect(isSafeToReattach(lastLine: "[detached (from session muxbar-e2e-a)]"))
    #expect(!isSafeToReattach(lastLine: "-- INSERT --"))
    #expect(!isSafeToReattach(lastLine: "  /private/tmp  ·  Opus (1M context)"))
}

@Test func liveAttachDetection() {
    let ps = """
    /usr/bin/ssh -o BatchMode=yes -T -- devbox sh -c 'tmux list-sessions'
    ssh -t devbox tmux attach-session -t '$3'
    /opt/homebrew/bin/tmux attach-session -t $12
    vim notes-attach-session -t $4
    """
    #expect(hasLiveAttachClient(psOutput: ps, host: "devbox", tmuxID: "$3"))
    #expect(!hasLiveAttachClient(psOutput: ps, host: "devbox", tmuxID: "$1"))
    #expect(!hasLiveAttachClient(psOutput: ps, host: "other", tmuxID: "$3"))
    #expect(hasLiveAttachClient(psOutput: ps, host: localHost, tmuxID: "$12"))
    #expect(!hasLiveAttachClient(psOutput: ps, host: localHost, tmuxID: "$1"))
    #expect(!hasLiveAttachClient(psOutput: ps, host: localHost, tmuxID: "$4"))
}

// MARK: - v1.1: shell-only sessions, groups, Claude conversations

@Test func paneCommandWithoutCommandIsLoginShell() async {
    #expect(TmuxCommands.paneCommand(nil) == "env CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 \"${SHELL:-/bin/sh}\" -l")
    #expect(TmuxCommands.paneCommand("  ") == TmuxCommands.paneCommand(nil))
    // The shell starts and, with stdin closed, exits cleanly.
    let r = await shell("/bin/zsh", ["-c", TmuxCommands.paneCommand(nil)], env: ["SHELL": "/bin/sh", "HOME": NSHomeDirectory()])
    #expect(r.exitCode == 0)
}

@Test func oldStateFilesStillLoad() throws {
    // A v1 state.json has no "groups" and records without "group".
    let v1 = """
    {"schemaVersion":1,"hosts":["local","devbox"],"recentDirs":{},
     "settings":{"terminal":"terminal","defaultCommand":"claude","disableLocalTmux":false},
     "sessions":{"local|$0|1":{"key":"local|$0|1","host":"local","tmuxID":"$0","created":1,"name":"a",
       "ended":false,"tags":[],"archived":false}}}
    """
    let st = try JSONDecoder().decode(AppState.self, from: Data(v1.utf8))
    #expect(st.groups.isEmpty && st.hosts == ["local", "devbox"])
    #expect(st.sessions["local|$0|1"]?.group == nil)
    #expect(try JSONDecoder().decode(AppState.self, from: Data("{}".utf8)).hosts == [localHost])
}

@Test func parsesClaudeConversations() {
    let n = "cc"
    let out = """
    @@cc F 66666666-ffff-4fff-8fff-666666666666 1791100000
    "cwd":"/private/tmp/muxbar e2e"
    {"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: local commands"}}
    {"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}
    {"type":"user","message":{"role":"user","content":"Fix the \\"probe\\" parser\\nplease \\u00e9"}}
    @@cc F 2f000000-0000-0000-0000-000000000000 1791100500
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"array style prompt"}]}}
    @@cc F 3f000000-0000-0000-0000-000000000000 1791100600
    {"type":"user","message":{"role":"user","content":"truncated line that never closes its quo
    @@cc END
    """
    let c = ClaudeConversations.parse(out, nonce: n)
    #expect(c.count == 3)
    #expect(c[0].cwd == "/private/tmp/muxbar e2e")
    #expect(c[0].firstPrompt == "Fix the \"probe\" parser please é")
    #expect(c[0].modified == 1791100000)
    #expect(c[1].firstPrompt == "array style prompt")
    #expect(c[2].firstPrompt == "truncated line that never closes its quo")
    #expect(ClaudeConversations.sessionName(for: c[0]) == "muxbar-e2e")
    #expect(ClaudeConversations.resumeCommand(c[0]) == "claude --resume '66666666-ffff-4fff-8fff-666666666666'")
    #expect(ClaudeConversations.parse("@@cc END\n", nonce: n).isEmpty)
}

@Test func conversationScriptRunsWithoutClaudeDir() async {
    let n = HostProbe.makeNonce()
    let r = await shell("/bin/sh", ["-c", ClaudeConversations.script(nonce: n)], env: ["HOME": "/nonexistent-muxbar"])
    #expect(r.exitCode == 0 && ClaudeConversations.parse(r.stdout, nonce: n).isEmpty)
}

@Test func conversationScriptReadsRealTranscripts() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-h-\(UUID().uuidString)")
    let proj = home.appendingPathComponent(".claude/projects/-tmp-x")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    try """
    {"type":"summary"}
    {"cwd":"/tmp/x","type":"user","message":{"role":"user","content":"hello from outside"}}
    """.write(to: proj.appendingPathComponent("abc-123.jsonl"), atomically: true, encoding: .utf8)
    let n = HostProbe.makeNonce()
    let r = await shell("/bin/sh", ["-c", ClaudeConversations.script(nonce: n)], env: ["HOME": home.path])
    let c = ClaudeConversations.parse(r.stdout, nonce: n)
    #expect(c.map(\.id) == ["abc-123"])
    #expect(c.first?.cwd == "/tmp/x" && c.first?.firstPrompt == "hello from outside")
    #expect((c.first?.modified ?? 0) > 1_700_000_000)
}

@Test func hostlessGroupsMigrateUnderTheirSessionsHost() throws {
    // An earlier build stored groups as a flat list; each moves under the host of its sessions.
    let old = """
    {"hosts":["local","devbox"],"groups":["API","Empty","Mixed"],
     "sessions":{
      "local|$0|1":{"key":"local|$0|1","host":"local","tmuxID":"$0","created":1,"name":"a","ended":false,"tags":[],"archived":false,"group":"API"},
      "devbox|$0|2":{"key":"devbox|$0|2","host":"devbox","tmuxID":"$0","created":2,"name":"b","ended":false,"tags":[],"archived":false,"group":"Mixed"},
      "local|$1|3":{"key":"local|$1|3","host":"local","tmuxID":"$1","created":3,"name":"c","ended":false,"tags":[],"archived":false,"group":"Mixed"}}}
    """
    let st = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
    #expect(st.groups(for: "local") == ["API", "Mixed"])
    #expect(st.groups(for: "devbox") == ["Mixed"])
    #expect(!st.hasGroup("Empty", host: "local"))
    // And the new shape round-trips.
    let again = try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(st))
    #expect(again.groups == st.groups)
}

@Test func claudeSessionIDValidation() {
    #expect(ClaudeConversations.isValidSessionID("66666666-ffff-4fff-8fff-666666666666"))
    #expect(ClaudeConversations.isValidSessionID("  abcdef12  "))
    #expect(!ClaudeConversations.isValidSessionID("abc"))
    #expect(!ClaudeConversations.isValidSessionID("x'; rm -rf / #"))
    #expect(!ClaudeConversations.isValidSessionID("$(id)-12345678"))
}

// MARK: - Workspace folders

@Test func workspacePaths() {
    #expect(Workspace.path(root: "~/Muxbar", group: "API", session: "index") == "~/Muxbar/API/index")
    #expect(Workspace.path(root: "~/Muxbar/", group: nil, session: "index") == "~/Muxbar/index")
    #expect(Workspace.path(root: "/w", group: "a/b:c", session: "..hidden") == "/w/a-b-c/hidden")
    #expect(Workspace.folderName("  ") == "untitled")
    #expect(Workspace.rebase("~/M/Old/s1", from: "~/M/Old", to: "~/M/New") == "~/M/New/s1")
    #expect(Workspace.rebase("~/M/Older/s1", from: "~/M/Old", to: "~/M/New") == nil)
    #expect(Workspace.installRoot(conf: "# muxbar\nroot=~/work/mux\n") == "~/work/mux")
    #expect(Workspace.installRoot(conf: "root=\n") == nil)
}

@Test func workspaceMoveScriptIsSafe() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-ws-\(UUID().uuidString)").path
    let a = base + "/G 1/sess's", b = base + "/G2/renamed"
    #expect(await shell("/bin/sh", ["-c", Workspace.mkdirScript(a)]).ok)
    try "keep me".write(toFile: a + "/file.txt", atomically: true, encoding: .utf8)
    #expect(await shell("/bin/sh", ["-c", Workspace.moveScript(from: a, to: b)]).ok)
    #expect(FileManager.default.fileExists(atPath: b + "/file.txt") && !FileManager.default.fileExists(atPath: a))
    // Target exists → refuses, nothing moved.
    #expect(await shell("/bin/sh", ["-c", Workspace.mkdirScript(a)]).ok)
    let r = await shell("/bin/sh", ["-c", Workspace.moveScript(from: a, to: b)])
    #expect(r.exitCode == 5 && FileManager.default.fileExists(atPath: b + "/file.txt"))
    // Missing source → creates the target.
    #expect(await shell("/bin/sh", ["-c", Workspace.moveScript(from: base + "/nope", to: base + "/made")]).ok)
    #expect(FileManager.default.fileExists(atPath: base + "/made"))
    // rmdir only removes empty folders.
    _ = await shell("/bin/sh", ["-c", Workspace.rmdirIfEmptyScript(base + "/G2")])
    #expect(FileManager.default.fileExists(atPath: b + "/file.txt"))
    _ = await shell("/bin/sh", ["-c", Workspace.rmdirIfEmptyScript(base + "/made")])
    #expect(!FileManager.default.fileExists(atPath: base + "/made"))
}

@Test func oldSettingsWithoutWorkspaceRootsLoad() throws {
    let st = try JSONDecoder().decode(AppState.self, from: Data(#"{"settings":{"terminal":"iterm"}}"#.utf8))
    #expect(st.settings.terminal == .iterm && st.settings.workspaceRoots.isEmpty)
}

@Test func outsideSessionsStayInOthers() {
    var st = AppState()
    var outside = SessionRecord(key: "local|$0|1", host: "local", tmuxID: "$0", created: 1, name: "hemant")
    outside.group = "Product Graph"                       // older record: no origin, no workspace folder
    var mine = SessionRecord(key: "local|$1|2", host: "local", tmuxID: "$1", created: 2, name: "mine")
    mine.origin = .muxbar; mine.group = "API"
    var managed = SessionRecord(key: "local|$2|3", host: "local", tmuxID: "$2", created: 3, name: "ws")
    managed.managedDir = "~/Muxbar/API/ws"; managed.group = "API"   // older record with a workspace folder
    st.sessions = [outside.key: outside, mine.key: mine, managed.key: managed]
    #expect(outside.isOutside && !mine.isOutside && !managed.isOutside)
    #expect(st.ejectOutsideFromGroups() == 1)
    #expect(st.sessions[outside.key]?.group == nil)
    #expect(st.sessions[mine.key]?.group == "API" && st.sessions[managed.key]?.group == "API")
    // A probe-discovered session is marked outside.
    var st2 = AppState()
    Reconciler.apply(ProbeResult(tmuxVersion: "tmux 3.6a", tmuxMissing: false,
                                 sessions: [ProbedSession(id: "$5", name: "x", created: 9, activity: 9, attached: 0)], hostNow: 10),
                     host: "local", to: &st2)
    #expect(st2.sessions.values.first?.origin == .outside)
}

@Test func resumeEndedCommandAndRestoreFields() throws {
    #expect(ClaudeConversations.resumeEndedCommand(claudeSessionID: "66666666-ffff-4fff-8fff-666666666666")
            == "claude --resume '66666666-ffff-4fff-8fff-666666666666'")
    #expect(ClaudeConversations.resumeEndedCommand(claudeSessionID: nil) == "claude --continue")
    #expect(ClaudeConversations.resumeEndedCommand(claudeSessionID: "bad; id") == "claude --continue")
    var st = AppState(); st.openPanes = ["a", "b"]; st.lastSelected = "b"
    let back = try JSONDecoder().decode(AppState.self, from: try JSONEncoder().encode(st))
    #expect(back.openPanes == ["a", "b"] && back.lastSelected == "b")
}

@Test func tmuxScrollMath() {
    let live = TmuxScroll.parse("281 0  20\n")!
    #expect(live == TmuxScrollInfo(history: 281, inMode: false, position: 0, height: 20))
    #expect(live.atLive && abs(live.thumbTop - 281.0 / 301.0) < 1e-9)
    let top = TmuxScrollInfo(history: 281, inMode: true, position: 281, height: 20)
    #expect(top.thumbTop == 0 && !top.atLive)
    #expect(top.position(forThumbTop: 0) == 281)
    #expect(top.position(forThumbTop: top.thumbTop + 1) == 0)   // dragged past the bottom
    #expect(TmuxScroll.parse("garbage") == nil)
    #expect(TmuxScroll.gotoScript(id: "$3", position: 0).contains("-X cancel"))
    #expect(TmuxScroll.scrollScript(id: "$3", lines: 5) == "tmux copy-mode -e -t '$3' && tmux send-keys -t '$3' -X -N 5 scroll-up")
}

@Test func tmuxScrollScriptsAgainstRealTmux() async throws {
    guard let tmux = findLocalTmux() else { return }
    let name = "muxbar-unit-scroll-\(UUID().uuidString.prefix(6))"
    // A tmux server of its own (`-L`): never the user's default server. Killed before returning
    // (a cleanup Task in `defer` can be cut off when the test process exits).
    let q = "\(shellQuote(tmux)) -L \(name)"
    _ = await shell("/bin/sh", ["-c", "\(q) new-session -d -s \(name) -x 80 -y 20 'seq 1 300; exec sleep 60'"])
    try await Task.sleep(nanoseconds: 700_000_000)
    let id = (await shell("/bin/sh", ["-c", "\(q) display -p -t '=\(name):' '#{session_id}'"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    func info() async -> TmuxScrollInfo? { TmuxScroll.parse((await shell("/bin/sh", ["-c", TmuxScroll.infoScript(tmux: q, id: id)])).stdout) }
    #expect((await info())?.atLive == true)
    _ = await shell("/bin/sh", ["-c", TmuxScroll.scrollScript(tmux: q, id: id, lines: 30)])
    #expect((await info())?.position == 30)
    _ = await shell("/bin/sh", ["-c", TmuxScroll.gotoScript(tmux: q, id: id, position: 200)])
    #expect((await info())?.position == 200)
    _ = await shell("/bin/sh", ["-c", TmuxScroll.gotoScript(tmux: q, id: id, position: 0)])
    #expect((await info())?.atLive == true)
    _ = await shell("/bin/sh", ["-c", "\(q) kill-server"])
}

@Test func fullScreenAppsPageInsteadOfTmuxHistory() {
    let claude = TmuxScroll.parse("0 0  68 1")!
    #expect(claude.alternate && !claude.usesTmuxHistory)
    let shell = TmuxScroll.parse("281 0  20 0")!
    #expect(!shell.alternate && shell.usesTmuxHistory)
    let empty = TmuxScroll.parse("0 0  20 0")!
    #expect(!empty.usesTmuxHistory)          // nothing to scroll: never enter copy mode
    #expect(TmuxScroll.pageKeysScript(id: "$3", pages: 2) == "tmux send-keys -t '$3' PPage PPage")
    #expect(TmuxScroll.pageKeysScript(id: "$3", pages: -1) == "tmux send-keys -t '$3' NPage")
    #expect(TmuxScroll.pageKeysScript(id: "$3", pages: 0) == "true")
}

@Test func mouseSettingDefaultsOffAndLoadsFromOldFiles() throws {
    #expect(AppSettings().passMouseToApps == false)
    let st = try JSONDecoder().decode(AppState.self, from: Data(#"{"settings":{"terminal":"embedded"}}"#.utf8))
    #expect(st.settings.passMouseToApps == false)
    var s = AppSettings(); s.passMouseToApps = true
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)).passMouseToApps)
}

@Test func testFoldersNeverBecomeRecent() {
    var st = AppState()
    st.rememberDir("/tmp/muxbar-e2e-dir", host: "devbox")
    st.rememberDir("~/src/real", host: "devbox")
    #expect(st.recentDirs["devbox"] == ["~/src/real"])
    st.recentDirs["devbox"] = ["/tmp/muxbar-e2e-ws2/x", "~/src/real", "/tmp/muxbar-unit-1"]
    #expect(st.forgetTestDirs() == 2 && st.recentDirs["devbox"] == ["~/src/real"])
}

@Test func paneCommandUsesInteractiveLoginShell() {
    #expect(TmuxCommands.paneCommand("claude").contains("\" -lic '"))
}

@Test func paneCommandSurvivesCtrlC() async {
    // Regression: Ctrl-C in the agent also reached the wrapper shell, which then skipped
    // `exec "$SHELL" -l` — the tmux session died instead of returning to a shell.
    let cmd = TmuxCommands.paneCommand("kill -INT $$; echo still-here")
    let r = await shell("/bin/sh", ["-c", cmd], env: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": "/tmp"])
    #expect(r.stdout.contains("still-here"), "out=\(r.stdout) err=\(r.stderr)")
}

@Test func runProcessSurvivesManyShortCommands() async {
    // Regression: availableData raised (abort) when the drain raced a readability callback.
    // 4 × 100 concurrent processes: enough to hit the race, below the per-user process limit while
    // the other tests run in parallel.
    var failures: [String] = []
    for batch in 0..<4 {
        let bad = await withTaskGroup(of: String?.self) { g in
            for i in 0..<100 {
                g.addTask {
                    let n = batch * 100 + i
                    let r = await runProcess("/bin/sh", ["-c", "printf 'x%.0s' $(seq 1 \(n % 50)); echo; echo err >&2"], timeout: 30)
                    return r.exitCode == 0 && r.stderr.contains("err") ? nil : "#\(n): exit \(r.exitCode) \(r.stderr.prefix(80))"
                }
            }
            var out: [String] = []
            for await b in g { if let b { out.append(b) } }
            return out
        }
        failures += bad
    }
    #expect(failures.isEmpty, "\(failures.prefix(5))")
}

@Test func nonASCIIScriptsReachTheShellUnchanged() async throws {
    // Process would send "É" decomposed (E + U+0301); scripts must arrive byte for byte.
    let r = await SystemRunner().run(host: localHost, script: "printf %s 'É café' | od -An -tx1 | tr -s ' \\n' ' '", timeout: 10)
    #expect(r.stdout.trimmingCharacters(in: .whitespaces) == "c3 89 20 63 61 66 c3 a9", "\(r.stdout) \(r.stderr)")
    let up = await SystemRunner().run(host: localHost, script: "cat; printf ' ü'", timeout: 10, stdin: Data("in".utf8))
    #expect(up.stdout == "in ü")
    #expect(asciiSafeScript("echo hi") == "echo hi")
}


@Test func wheelEventsForAppsWithMouseReporting() {
    let claude = TmuxScroll.parse("0 0  68 1 100 1")!
    #expect(claude.alternate && claude.mouse == .sgr && !claude.usesTmuxHistory)
    #expect(TmuxScroll.parse("0 0  68 1 000 0")!.mouse == .off)
    #expect(TmuxScroll.parse("0 0  68 1 100 0")!.mouse == .legacy)
    // A script's own output before the info line is skipped.
    #expect(TmuxScroll.parse("noise\n281 0  20 0 000 0\n")?.history == 281)
    // ESC [ < 64 ; 2 ; 34 M, twice: two wheel-up reports in one call.
    let up = TmuxScroll.wheelScript(id: "$3", events: 2, mouse: .sgr, col: 2, row: 34)
    let one = "1b 5b 3c 36 34 3b 32 3b 33 34 4d"
    #expect(up == "tmux send-keys -t '$3' -H \(one) \(one)")
    #expect(TmuxScroll.wheelScript(id: "$3", events: -1, mouse: .sgr, col: 2, row: 34).contains("36 35"))   // 65 = down
    #expect(TmuxScroll.wheelScript(id: "$3", events: -1, mouse: .legacy, col: 2, row: 34).hasSuffix("1b 5b 4d 61 22 42"))
    #expect(TmuxScroll.wheelScript(id: "$3", events: 3, mouse: .off, col: 2, row: 34) == "true")
}

@Test func wheelEventsReachTheAppThroughRealTmux() async throws {
    guard let tmux = findLocalTmux() else { return }
    let name = "muxbar-unit-wheel-\(UUID().uuidString.prefix(6))"
    let q = "\(shellQuote(tmux)) -L \(name)"
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).bytes").path
    defer { try? FileManager.default.removeItem(atPath: out) }
    // An app that turns on SGR mouse reporting on the alternate screen and records its input.
    let app = "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; stty raw -echo; exec dd bs=1 count=22 of=\(out) 2>/dev/null"
    _ = await shell("/bin/sh", ["-c", "\(q) new-session -d -s \(name) -x 80 -y 20 \(shellQuote(app))"])
    try await Task.sleep(nanoseconds: 700_000_000)
    let id = (await shell("/bin/sh", ["-c", "\(q) display -p -t '=\(name):' '#{session_id}'"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let info = TmuxScroll.parse((await shell("/bin/sh", ["-c", TmuxScroll.infoScript(tmux: q, id: id)])).stdout)
    #expect(info?.alternate == true && info?.mouse == .sgr)
    _ = await shell("/bin/sh", ["-c", TmuxScroll.wheelScript(tmux: q, id: id, events: 2, mouse: .sgr, col: 2, row: 10)])
    try await Task.sleep(nanoseconds: 500_000_000)
    _ = await shell("/bin/sh", ["-c", "\(q) kill-server"])
    #expect((try? String(contentsOfFile: out, encoding: .utf8)) == "\u{1B}[<64;2;10M\u{1B}[<64;2;10M")
}

@Test func clientInputForWheelAndPages() {
    #expect(TmuxScroll.clientWheelBytes(events: 2, col: 40, row: 12) == Array("\u{1B}[<64;40;12M\u{1B}[<64;40;12M".utf8))
    #expect(TmuxScroll.clientWheelBytes(events: -1, col: 1, row: 1) == Array("\u{1B}[<65;1;1M".utf8))
    #expect(TmuxScroll.clientWheelBytes(events: 0, col: 1, row: 1).isEmpty)
    #expect(TmuxScroll.clientPageBytes(pages: -2) == Array("\u{1B}[6~\u{1B}[6~".utf8))
}

@Test func agentShellKeepsSessionAfterCommandExits() {
    let cmd = TmuxCommands.paneCommand("claude")
    #expect(cmd.hasPrefix("env CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 "))
    #expect(cmd.contains("trap : INT; claude; exec"))
}

@Test func newSessionStartIsRememberedAndDefaultsToClaude() throws {
    var s = AppSettings()
    #expect(s.newSessionStart == "claude" && s.checkForUpdates)
    s.newSessionStart = "other"
    s.otherCommand = "gemini --yolo"
    let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
    #expect(back.newSessionStart == "other" && back.otherCommand == "gemini --yolo")
    // Settings saved by an older version have no such keys.
    let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(old.newSessionStart == "claude" && old.otherCommand == "" && old.checkForUpdates)
}

@Test func startCommandsForAnyAgent() {
    var s = AppSettings()
    #expect(s.startCommand("shell") == nil)
    #expect(s.startCommand("claude") == "claude" && s.startCommand("codex") == "codex")
    #expect(s.startCommand("other") == nil, "no command typed yet: a shell")
    s.otherCommand = "  /opt/bin/grok -m fast "
    #expect(s.startCommand("other") == "/opt/bin/grok -m fast")
    #expect(s.otherAgentNames.contains("grok") && s.otherAgentNames.contains("gemini"))
    s.otherCommand = "env FOO=1 mycli"
    #expect(s.otherAgentNames.last == "mycli")
}

@Test func classifiesOtherAgentScreens() {
    let gem = ["gemini"]
    #expect(StatusClassifier.classify(processes: ["zsh", "node"], lines: ["x"], otherAgents: gem) == .notClaude)
    #expect(StatusClassifier.isOtherAgentProcess("node /opt/homebrew/bin/gemini", gem))
    #expect(StatusClassifier.isOtherAgentProcess("/usr/local/bin/gemini", gem))
    #expect(!StatusClassifier.isOtherAgentProcess("gemini-helper", gem))
    let working = ["⠏ Reading files (esc to cancel, 12s)", "", "> Type your message"]
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: working, outputAge: 0, otherAgents: gem) == .working)
    let asking = ["Allow execution of: 'npm test'?", "● 1. Yes, allow once", "  2. No"]
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: asking, outputAge: 30, otherAgents: gem) == .waiting)
    let idle = ["✦ Done. All tests pass.", "", "> Type your message or @path/to/file"]
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: idle, outputAge: 30, otherAgents: gem) == .idle)
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: idle, outputAge: 1, otherAgents: gem) == .unknown)
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: working, outputAge: 40, otherAgents: gem) == .idle,
            "a busy line on a screen that stopped changing is stale")
    // An answered question stays on screen above the new input line: no longer waiting.
    #expect(StatusClassifier.classify(processes: ["zsh", "gemini"], lines: asking + idle, outputAge: 30, otherAgents: gem) == .idle)
    // Claude and Codex keep their own rules.
    #expect(StatusClassifier.classify(processes: ["zsh", "claude"], lines: ["❯ 1. Yes"], otherAgents: gem) == .waiting)
}

@Test func updateDecisions() {
    #expect(SemVer("v1.2.3") == SemVer(1, 2, 3) && SemVer("1.4") == SemVer(1, 4, 0) && SemVer("2.0.0-beta") == SemVer(2, 0, 0))
    #expect(SemVer("") == nil && SemVer("v1.x") == nil && SemVer("1.2.3.4") == nil)
    let cur = SemVer(0, 1, 0)
    func rel(_ t: String) -> ReleaseInfo { ReleaseInfo(tag: t, version: SemVer(t)!, notes: "", url: "") }
    #expect(Updates.decide(current: cur, latest: nil) == .upToDate)
    #expect(Updates.decide(current: cur, latest: rel("v0.1.0")) == .upToDate)
    #expect(Updates.decide(current: SemVer(0, 2, 0), latest: rel("v0.1.9")) == .upToDate)
    #expect(Updates.decide(current: cur, latest: rel("v0.1.1")) == .automatic(rel("v0.1.1")))
    #expect(Updates.decide(current: cur, latest: rel("v0.9.0")) == .automatic(rel("v0.9.0")))
    #expect(Updates.decide(current: cur, latest: rel("v1.0.0")) == .askFirst(rel("v1.0.0")))

    let json = #"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"body":"Notes","html_url":"https://x/r"}"#
    #expect(Updates.parseRelease(Data(json.utf8)) == ReleaseInfo(tag: "v1.2.0", version: SemVer(1, 2, 0), notes: "Notes", url: "https://x/r"))
    #expect(Updates.parseRelease(Data(#"{"tag_name":"v2.0.0","prerelease":true}"#.utf8)) == nil)
    #expect(Updates.parseRelease(Data(#"{"tag_name":"nightly"}"#.utf8)) == nil)
    #expect(Updates.parseRelease(Data("not json".utf8)) == nil)

    #expect(Updates.isSafeTag("v1.2.3") && Updates.isSafeTag("1.0") && Updates.isSafeTag("v2.0.0-rc.1"))
    #expect(!Updates.isSafeTag("v1; rm -rf ~") && !Updates.isSafeTag("$(id)") && !Updates.isSafeTag("v1.2 x"))
    #expect(Updates.sourceDir(conf: "# x\nroot=~/m\nsrc=/Users/u/src/muxbar\n") == "/Users/u/src/muxbar")
    #expect(Updates.sourceDir(conf: "root=~/m\n") == nil)
    #expect(Updates.updateScript(sourceDir: "/tmp/it's", tag: "v1.0.0").contains("cd '/tmp/it'\\''s'"))
}

@Test func updateScriptAgainstRealGit() async throws {
    // A checkout at v0.1.0 fast-forwards to a local "release" tag; local changes block it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-upd-\(UUID().uuidString)")
    let up = root.appendingPathComponent("up").path, co = root.appendingPathComponent("co").path
    let setup = """
    set -e
    git init -q -b main \(up) && cd \(up) && git config user.email t@t && git config user.name t
    printf '#!/bin/sh\\necho installed > installed.txt\\n' > install.sh && chmod +x install.sh
    git add . && git commit -qm one && git tag v0.1.0
    git clone -q \(up) \(co)
    echo 2 > two && git add two && git commit -qm two && git tag v0.2.0
    """
    #expect(await shell("/bin/sh", ["-c", setup]).exitCode == 0)
    // Point the script at the local "upstream" instead of GitHub.
    func script(_ dir: String) -> String {
        Updates.updateScript(sourceDir: dir, tag: "v0.2.0").replacingOccurrences(of: shellQuote(Updates.repoURL), with: shellQuote(up))
    }
    try "dirty".write(toFile: co + "/install.sh", atomically: true, encoding: .utf8)
    #expect(await shell("/bin/bash", ["-c", script(co)]).exitCode == 4)
    #expect(await shell("/bin/sh", ["-c", "cd \(co) && git checkout -q -- install.sh"]).exitCode == 0)
    let r = await shell("/bin/bash", ["-c", script(co)])
    #expect(r.exitCode == 0, "\(r.stderr)")
    #expect(FileManager.default.fileExists(atPath: co + "/two") && FileManager.default.fileExists(atPath: co + "/installed.txt"))
}

