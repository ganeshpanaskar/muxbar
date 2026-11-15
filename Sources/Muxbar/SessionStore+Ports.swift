import AppKit
import MuxbarCore

/// F8: a remote host's listening ports, forwarded to localhost on this Mac through the ssh master
/// Muxbar already keeps open. Loopback only; forwards persist and come back after a reconnect.
extension SessionStore {
    struct PortRow: Identifiable {
        var remote: Int
        var port: ListeningPort?
        var forward: PortForward?
        var owner: SessionRecord?
        /// False for a forward whose port stopped listening (shown greyed; kept until stopped).
        var listening: Bool
        var id: Int { remote }
    }

    func portRows(_ host: String) -> [PortRow] {
        let ports = hostPorts[host] ?? []
        let fwd = state.forwards[host] ?? []
        var rows = ports.map { p in
            PortRow(remote: p.port, port: p, forward: fwd.first { $0.remote == p.port },
                    owner: p.pane.flatMap { session(host: host, pane: $0) }, listening: true)
        }
        for f in fwd where !ports.contains(where: { $0.port == f.remote }) {
            rows.append(PortRow(remote: f.remote, port: nil, forward: f, owner: nil, listening: false))
        }
        return rows.sorted { $0.remote < $1.remote }
    }

    /// After each probe of a Linux host. With auto-forward on, ports that appear while Muxbar runs
    /// and belong to one of your sessions are forwarded (not the ones already there at launch).
    func updatePorts(host: String, _ ports: [ListeningPort]) {
        let old = hostPorts[host]
        if old != ports { hostPorts[host] = ports }
        guard settings.autoForward, let old else { return }
        let before = Set(old.map(\.port))
        for p in ports where !before.contains(p.port) && p.pane != nil
            && !(state.forwards[host] ?? []).contains(where: { $0.remote == p.port }) {
            Task {
                do { let f = try await forward(host: host, port: p.port); Log.info("auto-forwarded \(host):\(p.port) → localhost:\(f.local)") }
                catch { Log.error("auto-forward \(host):\(p.port): \(error.localizedDescription)") }
            }
        }
    }

    /// Opens localhost:<same port, or the next free one> → host:port. Below 1024 → 10000 + port.
    @discardableResult
    func forward(host: String, port: Int, local: Int? = nil) async throws -> PortForward {
        guard host != localHost else { throw StoreError("Ports on this Mac are already local") }
        guard state.hosts.contains(host) else { throw StoreError("Unknown host \(host)") }
        guard (1...65535).contains(port) else { throw StoreError("A port is 1–65535") }
        if let f = state.forwards[host]?.first(where: { $0.remote == port }) {
            if PortScan.isFreeLocal(f.local) { try await establish(host, f, allowRefresh: true) }
            return f
        }
        let lp: Int
        if let local {
            guard (1024...65535).contains(local), PortScan.isFreeLocal(local) else { throw StoreError("localhost:\(local) isn't free") }
            lp = local
        } else {
            guard let p = PortScan.localPort(for: port, isFree: PortScan.isFreeLocal) else { throw StoreError("No free local port near \(port)") }
            lp = p
        }
        let target = hostPorts[host]?.first { $0.port == port }?.target ?? "127.0.0.1"
        let f = PortForward(remote: port, local: lp, createdAt: Int(Date().timeIntervalSince1970), target: target)
        try await establish(host, f, allowRefresh: true)
        mutate { $0.forwards[host, default: []].append(f) }
        Log.info("forwarded localhost:\(lp) → \(host):\(port)")
        return f
    }

    func unforward(host: String, port: Int) async throws {
        guard let f = state.forwards[host]?.first(where: { $0.remote == port }) else { throw StoreError("\(host):\(port) isn't forwarded") }
        mutate { st in
            st.forwards[host]?.removeAll { $0.remote == port }
            if st.forwards[host]?.isEmpty == true { st.forwards[host] = nil }
        }
        await cancel(host, f)
        Log.info("stopped forward localhost:\(f.local) → \(host):\(port)")
    }

    /// Cancels every forward of a host (it's being removed).
    func dropForwards(host: String) {
        let fs = state.forwards[host] ?? []
        guard !fs.isEmpty else { return }
        mutate { $0.forwards[host] = nil }
        Task { for f in fs { await cancel(host, f) } }
    }

    private func cancel(_ host: String, _ f: PortForward) async {
        let r = await runProcess("/usr/bin/ssh", PortScan.controlArguments("cancel", host: host, local: f.local, target: f.target ?? "127.0.0.1",
                                                                         remote: f.remote, sshConfigFile: state.settings.sshConfigFile), timeout: 10)
        // The master may be gone already, taking the forward with it.
        if !r.ok { Log.info("cancel \(host):\(f.remote): \(cleanSSHStderr(r.stderr))") }
    }

    /// Asks the existing master to listen on 127.0.0.1:local. A probe opens the master if needed.
    private func establish(_ host: String, _ f: PortForward, allowRefresh: Bool) async throws {
        if !(await masterAlive(host)) {
            guard allowRefresh else { throw StoreError("no ssh connection to \(host)") }
            await refresh(host: host)
            guard await masterAlive(host) else { throw StoreError("Can't connect to \(host)") }
        }
        let r = await runProcess("/usr/bin/ssh", PortScan.controlArguments("forward", host: host, local: f.local, target: f.target ?? "127.0.0.1",
                                                                         remote: f.remote, sshConfigFile: state.settings.sshConfigFile), timeout: 10)
        guard r.ok else {
            let e = cleanSSHStderr(r.stderr)
            throw StoreError("Couldn't forward \(host):\(f.remote)\(e.isEmpty ? "" : ": " + e)")
        }
    }

    func masterAlive(_ host: String) async -> Bool {
        var a: [String] = []
        if let cfg = state.settings.sshConfigFile { a += ["-F", cfg] }
        a += ["-o", "ControlPath=\(MuxbarPaths.controlPath)", "-O", "check", "--", host]
        return await runProcess("/usr/bin/ssh", a, timeout: 5).ok
    }

    /// After every successful probe: forwards whose local port is free again (a new master after a
    /// drop, or a restart of Muxbar) are set up again.
    func ensureForwards(host: String) {
        guard host != localHost, let fs = state.forwards[host], !fs.isEmpty, !forwardingInFlight.contains(host) else { return }
        let missing = fs.filter { PortScan.isFreeLocal($0.local) }
        guard !missing.isEmpty else { return }
        forwardingInFlight.insert(host)
        Task {
            defer { forwardingInFlight.remove(host) }
            for f in missing {
                do {
                    try await establish(host, f, allowRefresh: false)
                    Log.info("re-established localhost:\(f.local) → \(host):\(f.remote)")
                } catch {
                    Log.error("re-establish \(host):\(f.remote): \(error.localizedDescription)")
                }
            }
        }
    }
}
