import AppKit
import MuxbarCore

/// F11: the first-launch setup (root folder, remote hosts) and adding or removing remote hosts later.
extension SessionStore {
    /// One ssh round trip: can Muxbar use this host? The address is validated first.
    func checkHost(_ raw: String) async throws -> (host: String, result: HostCheck.Result) {
        let h = try HostAddress.normalize(raw)
        let r = await runner().run(host: h, script: HostCheck.script, timeout: 25)
        return (h, HostCheck.parse(r))
    }

    /// Adds a remote host (validated) with an optional root folder, and starts polling it.
    @discardableResult
    func addRemoteHost(_ raw: String, root: String? = nil) throws -> String {
        let h = try HostAddress.normalize(raw)
        guard !state.hosts.contains(h) else { throw StoreError("\(h) is already added") }
        let r = root?.trimmingCharacters(in: .whitespaces) ?? ""
        if !r.isEmpty {
            guard Workspace.isValidRoot(r) else { throw StoreError("A root folder must start with / or ~/") }
            updateSettings { $0.workspaceRoots[h] = r }
        }
        addHost(h)
        Log.info("added remote host \(h)\(r.isEmpty ? "" : " (root \(r))")")
        return h
    }

    /// Saves the setup window's choices. Hosts that are already added keep their settings.
    func applySetup(localRoot: String?, hosts: [(host: String, root: String?)]) throws {
        let lr = localRoot?.trimmingCharacters(in: .whitespaces) ?? ""
        if !lr.isEmpty && !Workspace.isValidRoot(lr) { throw StoreError("The root folder must start with / or ~/") }
        let picked = try hosts.map { (host: try HostAddress.normalize($0.host), root: $0.root) }
        for p in picked {
            if let r = p.root?.trimmingCharacters(in: .whitespaces), !r.isEmpty, !Workspace.isValidRoot(r) {
                throw StoreError("\(p.host): a root folder must start with / or ~/")
            }
        }
        if !lr.isEmpty { updateSettings { $0.workspaceRoots[localHost] = lr } }
        for p in picked where !state.hosts.contains(p.host) { try addRemoteHost(p.host, root: p.root) }
        finishSetup()
        Log.info("setup done: root \(workspaceRoot(localHost)), remote hosts \(picked.map(\.host))")
    }

    /// Done or skipped: never shown again (everything is in Settings).
    func finishSetup() {
        updateSettings { $0.setupDone = true }
        needsSetup = false
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("setup") == true }.forEach { $0.close() }
    }

    var setupWindowOpen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("setup") == true && $0.isVisible }
    }
}
