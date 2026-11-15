import Foundation
import Testing
@testable import MuxbarCore

/// Fixture transcripts copied to a throwaway HOME (so a search can only ever touch that).
private func seedHistory() throws -> (home: URL, claude: String, codex: String) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-hist-\(UUID().uuidString)")
    let src = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("history")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: src, to: home.appendingPathComponent("history"))
    // Copies keep the fixtures' checkout dates: give each file the age the tests expect.
    let fresh = home.appendingPathComponent("history/claude/-tmp-muxbar-e2e-hist/11111111-aaaa-4aaa-8aaa-111111111111.jsonl")
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.path)
    let old = home.appendingPathComponent("history/claude/-tmp-muxbar-e2e-hist/33333333-cccc-4ccc-8ccc-333333333333.jsonl")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: old.path)
    let codex = home.appendingPathComponent("history/codex/2026/10/14/rollout-2026-10-14T10-00-00-22222222-bbbb-4bbb-8bbb-222222222222.jsonl")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: codex.path)
    return (home, home.appendingPathComponent("history/claude").path, home.appendingPathComponent("history/codex").path)
}

private func search(_ q: String, home: URL, claude: String, codex: String, agent: AgentKind? = nil, days: Int = 0,
                    limit: Int = 50) async -> (hits: [AgentHistory.Hit], r: RunResult) {
    let n = HostProbe.makeNonce()
    let s = AgentHistory.searchScript(query: q, agent: agent, days: days, limit: limit, claudeRoot: claude, codexRoot: codex, nonce: n)
    let r = await runLocalScript(s, timeout: 30, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
    return (AgentHistory.parseHits(r.stdout, nonce: n), r)
}

@Test func historySearchFindsTokensInRepliesAndPromptsWithSnippets() async throws {
    let (home, claude, codex) = try seedHistory()
    defer { try? FileManager.default.removeItem(at: home) }
    let (hits, r) = await search("ZEBRA-quartz-7731", home: home, claude: claude, codex: codex)
    #expect(r.stdout.contains("END"), "\(r.stderr)")
    // Newest first: Codex (1 min old), the reply (just copied), then the 3-day-old prompt.
    #expect(Set(hits.map(\.id)) == ["11111111-aaaa-4aaa-8aaa-111111111111", "22222222-bbbb-4bbb-8bbb-222222222222", "33333333-cccc-4ccc-8ccc-333333333333"])
    #expect(hits.last?.id == "33333333-cccc-4ccc-8ccc-333333333333")
    let a = try #require(hits.first { $0.agent == .claude && $0.id.hasPrefix("1111") })
    #expect(a.role == "assistant" && a.match.lowercased() == "zebra-quartz-7731")
    #expect(a.before.hasPrefix("…") && a.before.hasSuffix("the build id is ") && a.after == " for this run.")
    #expect(hits.first { $0.agent == .codex }?.before == "Add a retry to the uploader; tag it ")   // not cut: no "…"
    #expect(a.firstPrompt == "Explain how the release build works" && a.cwd == "/tmp/muxbar-e2e-hist" && a.messages == 6)
    let b = try #require(hits.first { $0.agent == .codex })
    #expect(b.role == "user" && b.firstPrompt == "Add a retry to the uploader; tag it zebra-quartz-7731" && b.cwd == "/tmp/muxbar-e2e-hist")
    // Last day only: the old file is out.
    let recent = await search("zebra-quartz-7731", home: home, claude: claude, codex: codex, days: 1).hits
    #expect(recent.count == 2 && !recent.contains { $0.id.hasPrefix("3333") })
    // Agent filter, unicode case folding, and a match only in tool output doesn't count.
    #expect(await search("zebra-quartz-7731", home: home, claude: claude, codex: codex, agent: .codex).hits.map(\.agent) == [.codex])
    let cafe = await search("CAFÉ AU", home: home, claude: claude, codex: codex)
    #expect(cafe.hits.map(\.id) == ["11111111-aaaa-4aaa-8aaa-111111111111"], "\(cafe.hits) \(cafe.r.stderr)")
    #expect(await search("appears only in tool output", home: home, claude: claude, codex: codex).hits.isEmpty)
}

@Test func hostileQueriesFindNothingAndDoNothing() async throws {
    let (home, claude, codex) = try seedHistory()
    defer { try? FileManager.default.removeItem(at: home) }
    let canary = home.appendingPathComponent("canary")
    try Data("x".utf8).write(to: canary)
    let hostile = [#"'"; rm -rf ~; echo ""#, "$(touch \(home.path)/pwned)", "`touch \(home.path)/pwned`", #"\"#, "a\nrm -rf ~",
                   "'; touch \(home.path)/pwned; '", #"%s%n%x"#, "\\Q.*\\E", "*", "' OR 1=1 --", "\u{0}\u{1B}[201~"]
    for q in hostile {
        let (hits, r) = await search(q, home: home, claude: claude, codex: codex)
        #expect(r.exitCode == 0 && r.stdout.contains("END"), "\(q.debugDescription): \(r.stderr)")
        #expect(hits.isEmpty, "\(q.debugDescription)")
    }
    #expect(FileManager.default.fileExists(atPath: canary.path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path))
    #expect(FileManager.default.fileExists(atPath: claude))
    #expect(AgentHistory.sanitizeQuery("a\nb\u{1B}c") == "a b c")
}

@Test func historySearchCapsHitsPerHost() async throws {
    let (home, claude, codex) = try seedHistory()
    defer { try? FileManager.default.removeItem(at: home) }
    let src = URL(fileURLWithPath: claude).appendingPathComponent("-tmp-muxbar-e2e-hist/11111111-aaaa-4aaa-8aaa-111111111111.jsonl")
    let dir = URL(fileURLWithPath: claude).appendingPathComponent("many")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<60 { try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(String(format: "%08d-aaaa-4aaa-8aaa-111111111111.jsonl", i))) }
    #expect(await search("zebra-quartz-7731", home: home, claude: claude, codex: codex).hits.count == AgentHistory.maxPerHost)
    #expect(await search("zebra-quartz-7731", home: home, claude: claude, codex: codex, limit: 5).hits.count == 5)
}

@Test func previewShowsFirstPromptLastTurnsBranchAndModel() async throws {
    let (home, claude, codex) = try seedHistory()
    defer { try? FileManager.default.removeItem(at: home) }
    let n = HostProbe.makeNonce()
    let path = claude + "/-tmp-muxbar-e2e-hist/11111111-aaaa-4aaa-8aaa-111111111111.jsonl"
    let r = await runProcess("/bin/sh", ["-c", AgentHistory.previewScript(path: path, nonce: n)], timeout: 20)
    let p = try #require(AgentHistory.parsePreview(r.stdout, nonce: n, agent: .claude))
    #expect(p.firstPrompt == "Explain how the release build works" && p.cwd == "/tmp/muxbar-e2e-hist")
    #expect(p.gitBranch == "main" && p.model == "claude-opus-5-5" && p.id == "11111111-aaaa-4aaa-8aaa-111111111111")
    #expect(p.turns.map(\.role) == ["user", "assistant", "tool", "assistant", "user", "assistant"])
    #expect(p.turns[2].text == "⏺ Bash: make -n release")
    let cpath = codex + "/2026/10/14/rollout-2026-10-14T10-00-00-22222222-bbbb-4bbb-8bbb-222222222222.jsonl"
    let r2 = await runProcess("/bin/sh", ["-c", AgentHistory.previewScript(path: cpath, nonce: n)], timeout: 20)
    let c = try #require(AgentHistory.parsePreview(r2.stdout, nonce: n, agent: .codex))
    #expect(c.id == "22222222-bbbb-4bbb-8bbb-222222222222" && c.gitBranch == "feature/x" && c.model == "gpt-5-codex")
    #expect(c.turns.map(\.text) == ["Add a retry to the uploader; tag it zebra-quartz-7731", "⏺ shell: bash -lc rg uploader", "Added exponential backoff to the uploader."])
    #expect(AgentHistory.parsePreview("@@\(n) NOFILE\n", nonce: n, agent: .claude) == nil)
    #expect(AgentHistory.resumeCommandLine(agent: .claude, id: "abc", cwd: "/tmp/w") == "cd '/tmp/w' && claude --resume 'abc'")
    #expect(AgentHistory.resumeCommandLine(agent: .codex, id: "abc", cwd: "/tmp/w") == "codex resume 'abc' -C '/tmp/w'")
}
