import UserNotifications

/// System notification center adapter; clicks are routed back through `onOpenChat`.
final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    var onOpenChat: (Int64) -> Void = { _ in }
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(identifier: String, threadIdentifier: String, title: String, subtitle: String?, body: String, chatID: Int64) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = ["chatID": chatID]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func removeDelivered(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeAllDelivered() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Filtering already happened before posting (e.g. the viewed chat never notifies).
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chatID = response.notification.request.content.userInfo["chatID"] as? Int64 else { return }
        await MainActor.run { self.onOpenChat(chatID) }
    }
}
