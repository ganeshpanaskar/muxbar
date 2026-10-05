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
    private(set) var notified: [String] = []   // test hook: names notified, most recent last

    func waitingKeys(_ store: SessionStore) -> [String] {
        store.state.sessions.values.filter { store.status(of: $0) == .waiting }.map(\.key)
    }

    func update(store: SessionStore, before: [String: LiveInfo], after: [String: LiveInfo]) {
        let count = waitingKeys(store).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        let newlyWaiting = after.filter { k, v in v.status == .waiting && before[k]?.status != .waiting && before[k] != nil }
        guard !newlyWaiting.isEmpty else { return }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        for (key, _) in newlyWaiting {
            guard let rec = store.state.sessions[key] else { continue }
            notify(rec)
        }
    }

    private func notify(_ rec: SessionRecord) {
        notified.append(rec.name)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let send = {
            let c = UNMutableNotificationContent()
            c.title = "\(rec.name) needs your input"
            c.body = rec.host == localHost ? "On this Mac" : "On \(rec.host)"
            c.userInfo = ["key": rec.key]
            center.add(UNNotificationRequest(identifier: "waiting-\(rec.key)", content: c, trigger: nil)) { err in
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
            if let key { _ = try? await AppModel.shared.store.focus(key: key) }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
