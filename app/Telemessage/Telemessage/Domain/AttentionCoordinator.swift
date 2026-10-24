import Foundation

/// What the attention layer needs from the system notification center.
protocol NotificationPosting: AnyObject {
    func requestAuthorization() async -> Bool
    func post(identifier: String, threadIdentifier: String, title: String, subtitle: String?, body: String, chatID: Int64)
    func removeDelivered(identifiers: [String])
    func removeAllDelivered()
}

/// Local notifications and the Dock badge, restricted to picked chats.
///
/// A notification is posted for a new incoming message only when notifications are on, the chat
/// is picked and presentable, not muted, unread, not the conversation the user is looking at, and
/// recent (no backlog flood after reconnecting).
final class AttentionCoordinator {
    private let services: AccountServices
    private let settings: AppSettings
    private let poster: NotificationPosting
    /// Whether the user is currently looking at this chat (its window is key in the active app).
    private let isViewing: (Int64) -> Bool
    private let setBadge: (String?) -> Void
    private let startedAt: Date
    private var posted: [Int64: [(messageID: Int64, identifier: String)]] = [:]
    private var observations: [StoreObservation] = []

    init(services: AccountServices, settings: AppSettings, poster: NotificationPosting,
         isViewing: @escaping (Int64) -> Bool, setBadge: @escaping (String?) -> Void, now: Date = .now) {
        self.services = services
        self.settings = settings
        self.poster = poster
        self.isViewing = isViewing
        self.setBadge = setBadge
        startedAt = now
    }

    func start() {
        observations.append(services.session.observeUpdates { [weak self] update in self?.handle(update) })
        observations.append(services.selection.observe { [weak self] in self?.selectionChanged() })
        observations.append(settings.observe { [weak self] in self?.settingsChanged() })
        updateBadge()
    }

    /// Account ending (logout, revocation, quit): clear everything this account showed.
    func end() {
        observations.removeAll()
        poster.removeAllDelivered()
        posted.removeAll()
        setBadge(nil)
    }

    func handle(_ update: Update, now: Date = .now) {
        switch update {
        case .newMessage(let message):
            notifyIfNeeded(message, now: now)
        case .chatReadInbox(let chatID, let lastRead, _):
            withdraw(chatID: chatID, upTo: lastRead)
        case .deleteMessages(let chatID, let ids, _, let fromCache) where !fromCache:
            let removed = Set(ids)
            let identifiers = posted[chatID, default: []].filter { removed.contains($0.messageID) }.map(\.identifier)
            posted[chatID]?.removeAll { removed.contains($0.messageID) }
            poster.removeDelivered(identifiers: identifiers)
        default:
            break
        }
        // Unread counts change through updateChatReadInbox (also for new messages).
        let badgeChat: Int64? = switch update {
        case .chatReadInbox(let chatID, _, _), .chatNotificationSettings(let chatID, _): chatID
        case .newChat(let chat): chat.id
        default: nil
        }
        if let badgeChat, services.policy.isSelected(badgeChat) { updateBadge() }
    }

    private func notifyIfNeeded(_ message: Message, now: Date) {
        guard settings.notificationsEnabled, !message.isOutgoing else { return }
        let chatID = message.chatID
        guard services.policy.canPresent(chatID), let chat = services.store.chats[chatID] else { return }
        let presentation = services.presentation
        guard !presentation.isMuted(chat), message.id > chat.lastReadInboxMessageID else { return }
        guard !isViewing(chatID) else { return }
        // TDLib replays missed messages after reconnecting; only alert for recent ones.
        let sent = Date(timeIntervalSince1970: TimeInterval(message.date))
        guard sent >= startedAt.addingTimeInterval(-60), now.timeIntervalSince(sent) < 600 else { return }
        if case .unsupported(let type) = message.content, ServiceText.isServiceMessage(type) { return }

        let title = presentation.title(of: chat)
        let subtitle = presentation.isGroup(chat) ? presentation.senderName(message.senderID) : nil
        let body = settings.notificationPreviews ? ChatPresentation.summary(of: message.content) : "New message"
        let identifier = "msg-\(chatID)-\(message.id)"
        posted[chatID, default: []].append((message.id, identifier))
        poster.post(identifier: identifier, threadIdentifier: "chat-\(chatID)", title: title, subtitle: subtitle,
                    body: body, chatID: chatID)
    }

    /// Removes notifications for messages that have been read (on any device).
    private func withdraw(chatID: Int64, upTo lastRead: Int64) {
        guard let entries = posted[chatID] else { return }
        let read = entries.filter { $0.messageID <= lastRead }
        posted[chatID] = entries.filter { $0.messageID > lastRead }
        poster.removeDelivered(identifiers: read.map(\.identifier))
    }

    private func selectionChanged() {
        for chatID in posted.keys where !services.policy.isSelected(chatID) {
            poster.removeDelivered(identifiers: posted[chatID]?.map(\.identifier) ?? [])
            posted[chatID] = nil
        }
        updateBadge()
    }

    private func settingsChanged() {
        if !settings.notificationsEnabled {
            poster.removeAllDelivered()
            posted.removeAll()
        }
    }

    /// Unread messages across picked, unmuted chats.
    var unreadTotal: Int {
        let presentation = services.presentation
        return services.selection.chatIDs.reduce(0) { total, chatID in
            guard services.policy.canPresent(chatID), let chat = services.store.chats[chatID], !presentation.isMuted(chat) else { return total }
            return total + Int(chat.unreadCount)
        }
    }

    func updateBadge() {
        let total = unreadTotal
        setBadge(total > 0 ? (total > 999 ? "999+" : String(total)) : nil)
    }
}
