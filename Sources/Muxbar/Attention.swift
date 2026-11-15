import AppKit
import MuxbarCore
import UserNotifications

/// Tells the user when a session starts waiting for input: Dock badge (count) and one bounce,
/// plus a notification that opens the session when clicked. The sidebar highlight and the
/// menu-bar shuffle read the same status.
@MainActor
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()
    private var authorized: Bool?
    private(set) var notified: [String] = []   // test hook: names notified (waiting), most recent last
    /// Test hook: every notification sent (or recorded, on test instances), oldest first.
    private(set) var sent: [(title: String, body: String, key: String)] = []
    private var lastFinishNotice: [String: Date] = [:]
    private var pendingFinished: [String] = []
    private var flushScheduled = false
    /// Finish notifications wait this long, so a burst becomes one notification.
    static let finishDebounce: TimeInterval = 2
    static let perSessionQuiet: TimeInterval = 60

    func waitingKeys(_ store: SessionStore) -> [String] {
        store.state.sessions.values.filter { store.status(of: $0) == .waiting }.map(\.key)
    }

    /// Dock badge: waiting sessions, plus unread finished ones unless Settings says waiting only.
    func refreshBadge(_ store: SessionStore) {
        let unread = store.settings.dockBadgeMode == .needsInputAndFinished ? store.unreadFinished.count : 0
        let count = waitingKeys(store).count + unread
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func update(store: SessionStore, before: [String: LiveInfo], after: [String: LiveInfo],
                events: [(SessionRecord, Unread.Event)] = []) {
        refreshBadge(store)
        queueFinished(store, events.filter { $0.1 == .finished }.map(\.0))
        let newlyWaiting = after.filter { k, v in v.status == .waiting && before[k]?.status != .waiting && before[k] != nil }
        guard !newlyWaiting.isEmpty else { return }
        if !NSApp.isActive && !TestEnv.isTest { NSApp.requestUserAttention(.informationalRequest) }
        for (key, _) in newlyWaiting {
            guard let rec = store.state.sessions[key] else { continue }
            notified.append(rec.name)
            post(title: "\(rec.name) needs your input", body: rec.host == localHost ? "On this Mac" : "On \(rec.host)",
                 key: rec.key, id: "waiting-\(rec.key)")
        }
    }

    /// "<name> finished" (with the start of the reply), at most once a minute per session, never for
    /// the session you're looking at (those aren't events). More than 3 at once → one notification.
    private func queueFinished(_ store: SessionStore, _ recs: [SessionRecord]) {
        guard store.settings.notifyOnFinish, !recs.isEmpty else { return }
        let now = Date()
        for r in recs {
            if let last = lastFinishNotice[r.key], now.timeIntervalSince(last) < Self.perSessionQuiet { continue }
            lastFinishNotice[r.key] = now
            if !pendingFinished.contains(r.key) { pendingFinished.append(r.key) }
        }
        guard !pendingFinished.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishDebounce) { [weak self, weak store] in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.flushScheduled = false
                let keys = self.pendingFinished
                self.pendingFinished = []
                let recs = keys.compactMap { store.state.sessions[$0] }
                if recs.count > 3 {
                    self.post(title: "\(recs.count) sessions finished", body: recs.map(\.name).joined(separator: ", "),
                              key: recs[0].key, id: "finished-batch-\(Int(Date().timeIntervalSince1970))")
                } else {
                    for r in recs {
                        let body = r.lastReply ?? (r.host == localHost ? "On this Mac" : "On \(r.host)")
                        self.post(title: "\(r.name) finished", body: body, key: r.key, id: "finished-\(r.key)")
                    }
                }
            }
        }
    }

    /// A host is running low on memory; clicking opens that host's memory popover.
    func postMemoryAlert(title: String, body: String, host: String) {
        post(title: title, body: body, key: "mem:" + host, id: "memory-\(host)-\(Int(Date().timeIntervalSince1970))")
    }

    private func post(title: String, body: String, key: String, id: String) {
        sent.append((title, body, key))
        // Test instances only record notifications (no permission prompt, nothing on screen).
        if TestEnv.isTest { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let send = {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.userInfo = ["key": key]
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { err in
                if let err { Log.error("notification failed: \(err)") }
            }
        }
        if authorized == true { send(); return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            Task { @MainActor in
                self.authorized = granted
                if let err { Log.error("notification permission: \(err)") }
                if granted { send() }
            }
        }
    }

    // Clicking the notification opens that session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String
        Task { @MainActor in
            let store = AppModel.shared.store
            if let key, key.hasPrefix("mem:") {
                MainWindowPresenter.show()
                store.memoryPopoverHost = String(key.dropFirst(4))
            } else if let key {
                _ = try? await store.focus(key: key)
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
