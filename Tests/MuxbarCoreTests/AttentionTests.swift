import Foundation
import Testing
@testable import MuxbarCore

// MARK: - Unread transitions (F2)

@Test func hooksFinishOnEveryNewStopEvenWithinOnePoll() {
    var t = Unread.Tracker()
    // App start: an old Stop is not news.
    #expect(Unread.step(&t, prev: nil, next: .idle, source: .hooks, hookEvent: "Stop", hookTS: 100) == nil)
    #expect(Unread.step(&t, prev: .idle, next: .idle, source: .hooks, hookEvent: "Stop", hookTS: 100) == nil)
    // A whole turn happened between two polls: only the new Stop timestamp shows it.
    #expect(Unread.step(&t, prev: .idle, next: .idle, source: .hooks, hookEvent: "Stop", hookTS: 130) == .finished)
    #expect(Unread.step(&t, prev: .idle, next: .working, source: .hooks, hookEvent: "UserPromptSubmit", hookTS: 140) == nil)
    #expect(Unread.step(&t, prev: .working, next: .waiting, source: .hooks, hookEvent: "PermissionRequest", hookTS: 141) == .waiting)
    #expect(Unread.step(&t, prev: .waiting, next: .waiting, source: .hooks, hookEvent: "Notification", hookTS: 147) == nil)
    #expect(Unread.step(&t, prev: .waiting, next: .working, source: .hooks, hookEvent: "PostToolUse", hookTS: 150) == nil)
    #expect(Unread.step(&t, prev: .working, next: .idle, source: .hooks, hookEvent: "Stop", hookTS: 155) == .finished)
    // Codex Interrupt ends a turn too.
    #expect(Unread.step(&t, prev: .working, next: .idle, source: .hooks, hookEvent: "Interrupt", hookTS: 170) == .finished)
}

@Test func claudeInterruptWithoutHookStillFinishes() {
    var t = Unread.Tracker()
    _ = Unread.step(&t, prev: nil, next: .working, source: .hooks, hookEvent: "UserPromptSubmit", hookTS: 10)
    // Esc fires no hook: fusion reports idle while the last hook is still UserPromptSubmit.
    #expect(Unread.step(&t, prev: .working, next: .idle, source: .hooks, hookEvent: "UserPromptSubmit", hookTS: 10) == .finished)
}

@Test func screenOnlyFinishNeedsConfirmation() {
    var t = Unread.Tracker()
    #expect(Unread.step(&t, prev: nil, next: .idle, source: .screen, hookEvent: "", hookTS: nil) == nil)
    #expect(Unread.step(&t, prev: .idle, next: .working, source: .screen, hookEvent: "", hookTS: nil) == nil)
    #expect(Unread.step(&t, prev: .working, next: .idle, source: .screen, hookEvent: "", hookTS: nil) == nil, "one idle poll isn't enough")
    #expect(Unread.step(&t, prev: .idle, next: .idle, source: .screen, hookEvent: "", hookTS: nil) == .finished)
    #expect(Unread.step(&t, prev: .idle, next: .idle, source: .screen, hookEvent: "", hookTS: nil) == nil, "only once")
    // Flapping working → unknown → idle → working doesn't finish.
    _ = Unread.step(&t, prev: .idle, next: .working, source: .screen, hookEvent: "", hookTS: nil)
    _ = Unread.step(&t, prev: .working, next: .unknown, source: .screen, hookEvent: "", hookTS: nil)
    #expect(Unread.step(&t, prev: .unknown, next: .idle, source: .screen, hookEvent: "", hookTS: nil) == nil)
    #expect(Unread.step(&t, prev: .idle, next: .working, source: .screen, hookEvent: "", hookTS: nil) == nil)
    #expect(Unread.step(&t, prev: .working, next: .waiting, source: .screen, hookEvent: "", hookTS: nil) == .waiting)
}

// MARK: - Transcript previews

@Test func lastAssistantTextFromClaudeAndCodexTranscripts() {
    let claude = """
    {"type":"user","message":{"role":"user","content":"fix it"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed the **parser**.\\n\\nAll tests pass."},{"type":"tool_use","name":"Bash","input":{}}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}
    """
    #expect(AgentTranscript.lastAssistantText(claude, agent: .claude) == "Fixed the **parser**.\n\nAll tests pass.")
    #expect(AgentTranscript.oneLine("Fixed the **parser**.\n\nAll tests pass.") == "Fixed the parser. All tests pass.")
    let cut = String(claude.dropFirst(30))   // a tail that starts mid-line
    #expect(AgentTranscript.lastAssistantText(cut, agent: .claude) != nil)
    let codex = """
    {"type":"session_meta","payload":{"id":"t1","cwd":"/p"}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}}
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done: 3 files changed."}]}}
    {"type":"event_msg","payload":{"type":"token_count","info":{}}}
    """
    #expect(AgentTranscript.lastAssistantText(codex, agent: .codex) == "Done: 3 files changed.")
    #expect(AgentTranscript.lastAssistantText("not json\n", agent: .codex) == nil)
    #expect(AgentTranscript.oneLine(String(repeating: "word ", count: 60), limit: 20).count == 20)
    #expect(AgentTranscript.claudeProjectDir(for: "/private/tmp/muxbar-e2e-hooks") == "-private-tmp-muxbar-e2e-hooks")
    #expect(AgentTranscript.claudeProjectDir(for: "/Users/u/my_proj.v2") == "-Users-u-my-proj-v2")
}

@Test func transcriptTailScriptFallsBackToNewestFile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-tail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "old\n".write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    Thread.sleep(forTimeInterval: 1.1)
    try "newest line\n".write(to: dir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
    let viaDir = await shell("/bin/sh", ["-c", AgentTranscript.tailScript(path: dir.path + "/missing.jsonl", dir: dir.path)])
    #expect(viaDir.stdout == "newest line\n")
    let direct = await shell("/bin/sh", ["-c", AgentTranscript.tailScript(path: dir.path + "/a.jsonl", dir: nil, bytes: 3)])
    #expect(direct.stdout == "ld\n")
}
