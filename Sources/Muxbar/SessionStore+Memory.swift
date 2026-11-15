import AppKit
import MuxbarCore

/// F3: host memory in the sidebar, alerts before a host runs out, and the processes behind it.
extension SessionStore {
    static let fastMemoryInterval: TimeInterval = 5
    static let sampleWindow: Double = 300

    var memWarn: Int { memThresholdOverride?.warn ?? settings.memWarnPct }
    var memCrit: Int { memThresholdOverride?.crit ?? settings.memCritPct }

    func memoryLevel(_ host: String) -> MemoryLevel {
        guard let m = hostMemory[host] else { return .normal }
        return MemoryAlerts.level(usedPercent: m.usedPercent, warn: memWarn, crit: memCrit)
    }

    /// Called with every probe's memory line (full polls and the fast memory-only polls).
    func recordMemory(host: String, _ mem: HostMemory, at now: Double = Date().timeIntervalSince1970) {
        hostMemory[host] = mem
        var s = memSamples[host] ?? []
        s.append(MemorySample(t: now, availableKB: mem.availableKB))
        s.removeAll { now - $0.t > Self.sampleWindow }
        memSamples[host] = s
        evaluateMemoryAlerts(host: host, now: now)
        // Under pressure, watch this host closely (memory only, every 5 s) until it eases.
        if mem.usedPercent >= Double(memWarn) { startFastMemoryPoll(host) }
        else if mem.usedPercent < Double(memWarn - 5) { memPollers[host]?.cancel(); memPollers[host] = nil }
    }

    func evaluateMemoryAlerts(host: String, now: Double) {
        guard let mem = hostMemory[host] else { return }
        let left = MemoryTrend.secondsToExhaustion(memSamples[host] ?? [], now: now)
        var a = memAlerts[host] ?? MemoryAlerts()
        let fired = a.step(usedPercent: mem.usedPercent, crit: memCrit, secondsToExhaustion: left)
        memAlerts[host] = a
        guard settings.memAlerts else { return }
        for alert in fired {
            var who = biggestSessionSummary(host) ?? "Stop a large process or session to avoid a freeze."
            let cand = sleepCandidates(host: host)
            if cand.count > 0 { who += " — open to sleep \(cand.count) idle agent\(cand.count == 1 ? "" : "s") (~\(formatKB(cand.kb)))" }
            switch alert {
            case .critical(let pct):
                Attention.shared.postMemoryAlert(title: "\(hostLabel(host)) memory \(Int(pct))%", body: who, host: host)
            case .runningOut(let secs):
                Attention.shared.postMemoryAlert(title: "\(hostLabel(host)) may run out of memory in ~\(max(1, Int(secs / 60))) min",
                                                 body: who, host: host)
            }
            Log.info("memory alert on \(host): \(alert) — \(who)")
        }
    }

    private func startFastMemoryPoll(_ host: String) {
        guard memPollers[host] == nil else { return }
        memPollers[host] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.fastMemoryInterval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.pollingActive else { continue }
                let nonce = HostProbe.makeNonce()
                let r = await self.runner().run(host: host, script: HostProbe.script(mode: .memory, nonce: nonce), timeout: 10)
                if r.ok, let p = try? HostProbe.parse(r.stdout, nonce: nonce), let m = p.memory {
                    self.recordMemory(host: host, m)
                }
            }
        }
    }

    /// "web-app uses 24 GB (python × 13)" for the session using the most memory on `host`.
    func biggestSessionSummary(_ host: String) -> String? {
        let recs = sessions(for: host).filter { !$0.ended }
        guard let big = recs.max(by: { (live[$0.key]?.memoryKB ?? 0) < (live[$1.key]?.memoryKB ?? 0) }),
              let kb = live[big.key]?.memoryKB, kb > 0 else { return nil }
        var detail = ""
        if let sid = big.tmuxID {
            let names = (lastPanes[host] ?? []).filter { $0.sessionID == sid }.flatMap(\.processes)
            let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
            if let (name, n) = counts.filter({ !["zsh", "bash", "sh", "fish", "tmux", "login"].contains($0.key) })
                .max(by: { $0.value < $1.value }), n > 1 {
                detail = " (\(name) × \(n))"
            }
        }
        return "\(big.name) uses \(formatKB(kb))\(detail)"
    }

    /// Session that owns a tmux pane on `host`, from the last probe.
    func session(host: String, pane: String) -> SessionRecord? {
        guard let sid = (lastPanes[host] ?? []).first(where: { $0.id == pane })?.sessionID else { return nil }
        return state.sessions.values.first { $0.host == host && $0.tmuxID == sid && !$0.ended }
    }

    /// The host's biggest processes right now (on demand: the popover and `--cli memory`).
    @discardableResult
    func fetchTopProcesses(_ host: String, limit: Int = 12) async -> [ProcessUsage] {
        let tmux = host == localHost ? (localTmux.map(shellQuote) ?? "tmux") : "tmux"
        let nonce = HostProbe.makeNonce()
        let r = await runner().run(host: host, script: MemoryDetail.script(nonce: nonce, tmux: tmux, socket: tmuxSocket, limit: limit),
                                   timeout: 20)
        let top = MemoryDetail.parse(r.stdout, nonce: nonce)
        topProcesses[host] = top
        return top
    }

    /// SIGTERM, after the UI or `--yes` confirmed it (never SIGKILL from Muxbar).
    func stopProcess(host: String, pid: Int) async throws {
        guard pid > 1 else { throw StoreError("Refusing to signal pid \(pid)") }
        let r = await runner().run(host: host, script: "kill -TERM \(pid)", timeout: 15)
        guard r.ok else {
            let msg = cleanSSHStderr(r.stderr)
            throw StoreError("Couldn't stop \(pid) on \(hostLabel(host)): \(msg.isEmpty ? "exit \(r.exitCode)" : msg)")
        }
        Log.info("stopped pid \(pid) on \(host) (SIGTERM)")
        await fetchTopProcesses(host)
    }
}
