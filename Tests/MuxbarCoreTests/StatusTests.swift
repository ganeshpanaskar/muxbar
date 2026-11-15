import Foundation
import Testing
@testable import MuxbarCore

/// Fixtures are real `tmux capture-pane -p -J` output from Claude Code. The filename prefix is the
/// expected status: working-*, waiting-*, idle-*, notclaude-*, unknown-*.
/// Optional sidecar `<name>.procs` holds the pane's process names (one per line); the default is a
/// live Claude process, except for notclaude-* which defaults to a plain shell. Optional
/// `<name>.age` holds seconds since the pane's last output (default: unknown).
struct StatusFixture: CustomStringConvertible, Sendable {
    let name: String
    let lines: [String]
    let processes: [String]
    let expected: SessionStatus
    let outputAge: Int?
    var description: String { name }
}

func loadStatusFixtures() -> [StatusFixture] {
    guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?.appendingPathComponent("status"),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.pathExtension == "txt" }.sorted { $0.path < $1.path }.compactMap { url in
        let base = url.deletingPathExtension().lastPathComponent
        let prefix = String(base.split(separator: "-").first ?? "")
        let expected: SessionStatus? = ["working": .working, "waiting": .waiting, "idle": .idle,
                                        "notclaude": .notClaude, "unknown": .unknown][prefix]
        guard let expected, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let procURL = url.deletingPathExtension().appendingPathExtension("procs")
        let procs = (try? String(contentsOf: procURL, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) }
            ?? (expected == .notClaude ? ["zsh"] : ["zsh", "claude"])
        let age = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("age"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let lines = HostProbe.lastNonBlank(text.components(separatedBy: "\n"), count: 60)
        return StatusFixture(name: base, lines: lines, processes: procs, expected: expected, outputAge: age)
    }
}

@Test func fixturesExist() {
    let f = loadStatusFixtures()
    #expect(f.count >= 6)
    for s in [SessionStatus.working, .waiting, .idle, .notClaude] {
        #expect(f.contains { $0.expected == s }, "missing fixture for \(s)")
    }
}

@Test(arguments: loadStatusFixtures())
func classifiesFixture(_ f: StatusFixture) {
    #expect(StatusClassifier.classify(processes: f.processes, lines: f.lines, outputAge: f.outputAge) == f.expected)
}

@Test func processNames() {
    #expect(StatusClassifier.isClaudeProcess("claude"))
    #expect(StatusClassifier.isClaudeProcess("/Users/u/.local/share/claude/versions/2.1.288/bin/claude"))
    #expect(StatusClassifier.isClaudeProcess("2.1.3"))
    #expect(!StatusClassifier.isClaudeProcess("zsh"))
    #expect(!StatusClassifier.isClaudeProcess("zsh (shell-wrapper)"))
    #expect(!StatusClassifier.isClaudeProcess("claude-helper-not"))
}

@Test func degradesToUnknownNotWrong() {
    #expect(StatusClassifier.classify(processes: ["claude"], lines: []) == .unknown)
    #expect(StatusClassifier.classify(processes: ["claude"], lines: ["random output", "more"]) == .unknown)
    #expect(StatusClassifier.classify(processes: nil, lines: nil) == .unknown)
    // node alone, no Claude screen → not Claude; node + Claude screen → classified.
    #expect(StatusClassifier.classify(processes: ["node"], lines: ["server listening"]) == .notClaude)
}

@Test func legacyEscToInterrupt() {
    #expect(StatusClassifier.classify(processes: ["claude"],
                                      lines: ["✻ Thinking… (3s · esc to interrupt)", "───", "❯ ", "───"]) == .working)
    #expect(StatusClassifier.classify(processes: ["claude"],
                                      lines: ["· Pondering (esc to interrupt)"]) == .working)
}

@Test func idleRedrawIsNotWorking() {
    // Idle Claude redraws every few seconds; a completion line means idle even with fresh output.
    let lines = ["⏺ Done.", "✻ Sautéed for 25s · done 7:03 AM", "────", "❯ ", "────", "  ⏵⏵ auto mode on"]
    #expect(StatusClassifier.classify(processes: ["claude"], lines: lines, outputAge: 0) == .idle)
    let fresh = ["▐▛███▛█   Claude Code v2.1.288", "────", "❯ ", "────", "  ⏵⏵ auto mode on"]
    #expect(StatusClassifier.classify(processes: ["claude"], lines: fresh, outputAge: 0) == .unknown)
    #expect(StatusClassifier.classify(processes: ["claude"], lines: fresh, outputAge: 9) == .idle)
}
