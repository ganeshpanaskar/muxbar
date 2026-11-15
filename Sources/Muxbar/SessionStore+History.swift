import AppKit
import MuxbarCore

/// F9: search conversation history on one or all hosts; preview; resume in a new session.
extension SessionStore {
    /// One host's hits (newest first, at most 50). Runs on the host; ~10 s at most.
    func historySearch(host: String, query: String, agent: AgentKind?, days: Int,
                       claudeRoot: String? = nil, codexRoot: String? = nil) async throws -> [AgentHistory.Hit] {
        try await historySearchDetailed(host: host, query: query, agent: agent, days: days, claudeRoot: claudeRoot, codexRoot: codexRoot).hits
    }

    /// Hits plus, when the time limit cut the search short, how many conversations were searched.
    func historySearchDetailed(host: String, query: String, agent: AgentKind?, days: Int, claudeRoot: String? = nil,
                               codexRoot: String? = nil) async throws -> (hits: [AgentHistory.Hit], partial: (scanned: Int, total: Int)?) {
        let q = AgentHistory.sanitizeQuery(query)
        guard !q.isEmpty else { return ([], nil) }
        let nonce = HostProbe.makeNonce()
        let script = AgentHistory.searchScript(query: q, agent: agent, days: days, claudeRoot: claudeRoot, codexRoot: codexRoot, nonce: nonce)
        let r = await runner().run(host: host, script: script, timeout: Double(AgentHistory.timeLimit + 6))
        guard r.stdout.contains("@@\(nonce) END") else {
            let e = cleanSSHStderr(r.stderr)
            throw StoreError("Search on \(hostLabel(host)) failed\(r.timedOut ? " (timed out)" : "")\(e.isEmpty ? "" : ": " + e)")
        }
        return (AgentHistory.parseHits(r.stdout, nonce: nonce, host: host), AgentHistory.parsePartial(r.stdout, nonce: nonce))
    }

    /// Every host at once; a host that fails doesn't hide the others' hits. Notes say which hosts
    /// failed or stopped at the time limit.
    func historySearch(hosts: [String], query: String, agent: AgentKind?, days: Int) async -> (hits: [AgentHistory.Hit], errors: [String]) {
        await withTaskGroup(of: ([AgentHistory.Hit], String?).self) { g in
            for h in hosts { g.addTask { @MainActor in
                do {
                    let r = try await self.historySearchDetailed(host: h, query: query, agent: agent, days: days)
                    let note = r.partial.map { "\(self.hostLabel(h)): searched the newest \($0.scanned) of \($0.total) conversations (time limit)" }
                    return (r.hits, note)
                } catch { return ([], error.localizedDescription) }
            } }
            var hits: [AgentHistory.Hit] = [], notes: [String] = []
            for await (h, note) in g {
                hits += h
                if let note { notes.append(note) }
            }
            return (hits.sorted { $0.modified > $1.modified }, notes.sorted())
        }
    }

    func historyPreview(_ hit: AgentHistory.Hit) async -> AgentHistory.Preview? {
        let nonce = HostProbe.makeNonce()
        let r = await runner().run(host: hit.host, script: AgentHistory.previewScript(path: hit.path, nonce: nonce), timeout: 20)
        return AgentHistory.parsePreview(r.stdout, nonce: nonce, agent: hit.agent)
    }

    /// A new session in the conversation's folder, running the agent's resume command.
    func resumeFromHistory(_ hit: AgentHistory.Hit) async throws -> SessionRecord {
        guard !hit.id.isEmpty else { throw StoreError("This conversation has no id to resume") }
        let base = hit.firstPrompt.map { AgentTranscript.oneLine($0, limit: 24) } ?? String(hit.id.prefix(8))
        let rec = try await newSession(host: hit.host, dir: hit.cwd ?? "~", name: sanitizeSessionName(base),
                                       command: AgentAdapter.resumeCommand(hit.agent, sessionID: hit.id, cwd: hit.cwd, flags: []))
        mutate { st in
            st.sessions[rec.key]?.agent = hit.agent
            st.sessions[rec.key]?.agentSessionID = hit.id
            if hit.agent == .claude { st.sessions[rec.key]?.claudeSessionID = hit.id }
        }
        Log.info("resumed \(hit.agent.rawValue) \(hit.id) from history on \(hit.host)")
        return state.sessions[rec.key] ?? rec
    }
}
