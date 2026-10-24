import Foundation

/// What an applied update changed, so views can refresh precisely.
enum StoreChange: Equatable, Sendable {
    case authorizationState
    case connectionState
    case myUserID
    case user(Int64)
    case basicGroup(Int64)
    case supergroup(Int64)
    /// Title, photo, last message, read state or notification settings.
    case chat(Int64)
    /// The chat's position in some chat list changed (re-sort lists).
    case chatPositions(Int64)
    case messagesAdded(chatID: Int64, messageIDs: [Int64])
    case messageChanged(chatID: Int64, messageID: Int64)
    /// A temporary outgoing message got its final identifier (sent or failed).
    case messageReplaced(chatID: Int64, oldMessageID: Int64, newMessageID: Int64)
    case messagesRemoved(chatID: Int64, messageIDs: [Int64])
    case file(Int32)
}

/// Loaded messages of one chat, ascending by identifier.
struct ChatTimeline: Equatable {
    private(set) var messageIDs: [Int64] = []
    private(set) var messages: [Int64: Message] = [:]

    var orderedMessages: [Message] { messageIDs.compactMap { messages[$0] } }

    /// Returns true if the message was not present before.
    @discardableResult
    mutating func upsert(_ message: Message) -> Bool {
        let isNew = messages.updateValue(message, forKey: message.id) == nil
        if isNew { messageIDs.insert(message.id, at: insertionIndex(for: message.id)) }
        return isNew
    }

    @discardableResult
    mutating func remove(_ messageID: Int64) -> Bool {
        guard messages.removeValue(forKey: messageID) != nil else { return false }
        messageIDs.remove(at: insertionIndex(for: messageID))
        return true
    }

    mutating func modify(_ messageID: Int64, _ body: (inout Message) -> Void) -> Bool {
        guard var message = messages[messageID] else { return false }
        body(&message)
        messages[messageID] = message
        return true
    }

    private func insertionIndex(for id: Int64) -> Int {
        var low = 0
        var high = messageIDs.count
        while low < high {
            let mid = (low + high) / 2
            if messageIDs[mid] < id { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Single owner of Telegram state. Applies updates in the order TDLib emitted them.
///
/// Messages are kept only for chats whose timeline is tracked (open windows); the rest of the
/// account is represented by chat metadata and `Chat.lastMessage`.
@MainActor
final class TelegramStore {
    private(set) var authorizationState: AuthorizationState?
    private(set) var connectionState: ConnectionState = .connecting
    private(set) var myUserID: Int64?
    private(set) var users: [Int64: User] = [:]
    private(set) var basicGroups: [Int64: BasicGroup] = [:]
    private(set) var supergroups: [Int64: Supergroup] = [:]
    private(set) var chats: [Int64: Chat] = [:]
    private(set) var files: [Int32: TDFile] = [:]
    private var timelines: [Int64: ChatTimeline] = [:]

    private var observers: [UUID: (StoreChange) -> Void] = [:]

    // MARK: Observation

    func observe(_ handler: @escaping (StoreChange) -> Void) -> StoreObservation {
        let id = UUID()
        observers[id] = handler
        return StoreObservation { [weak self] in self?.observers[id] = nil }
    }

    private func emit(_ change: StoreChange) {
        for handler in observers.values { handler(change) }
    }

    // MARK: Queries

    /// Chat identifiers in `list`, in Telegram's display order.
    func chatIDs(in list: ChatList) -> [Int64] {
        chats.values
            .compactMap { chat in chat.position(in: list).map { (chat.id, $0.order) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
            .map(\.0)
    }

    func timeline(for chatID: Int64) -> ChatTimeline? { timelines[chatID] }

    /// The freshest known state of a file embedded in a message or photo.
    func latest(_ file: TDFile) -> TDFile { files[file.id] ?? file }

    // MARK: Message tracking

    func trackMessages(in chatID: Int64) {
        if timelines[chatID] == nil { timelines[chatID] = ChatTimeline() }
    }

    func stopTrackingMessages(in chatID: Int64) {
        timelines[chatID] = nil
    }

    /// Merges a history page; duplicates of live messages are updated in place.
    func merge(_ messages: [Message], into chatID: Int64) {
        guard timelines[chatID] != nil else { return }
        var added: [Int64] = []
        for message in messages where message.chatID == chatID {
            if timelines[chatID]!.upsert(message) { added.append(message.id) }
        }
        if !added.isEmpty { emit(.messagesAdded(chatID: chatID, messageIDs: added.sorted())) }
    }

    // MARK: Reduction

    func apply(_ update: Update) {
        switch update {
        case .authorizationState(let state):
            authorizationState = state
            emit(.authorizationState)
        case .connectionState(let state):
            connectionState = state
            emit(.connectionState)
        case .option(let name, let value):
            if name == "my_id" {
                if case .integer(let id) = value { myUserID = id } else { myUserID = nil }
                emit(.myUserID)
            }

        case .user(let user):
            users[user.id] = user
            emit(.user(user.id))
        case .userStatus(let userID, let status):
            guard users[userID] != nil else { return }
            users[userID]!.status = status
            emit(.user(userID))
        case .basicGroup(let group):
            basicGroups[group.id] = group
            emit(.basicGroup(group.id))
        case .supergroup(let group):
            supergroups[group.id] = group
            emit(.supergroup(group.id))

        case .newChat(let chat):
            chats[chat.id] = chat
            emit(.chat(chat.id))
            emit(.chatPositions(chat.id))
        case .chatTitle(let chatID, let title):
            modifyChat(chatID) { $0.title = title }
        case .chatPhoto(let chatID, let photo):
            modifyChat(chatID) { $0.photo = photo }
        case .chatLastMessage(let chatID, let lastMessage, let positions):
            modifyChat(chatID) { chat in
                chat.lastMessage = lastMessage
                for position in positions { chat.setPosition(position) }
            }
            if !positions.isEmpty, chats[chatID] != nil { emit(.chatPositions(chatID)) }
        case .chatPosition(let chatID, let position):
            guard chats[chatID] != nil else { return }
            chats[chatID]!.setPosition(position)
            emit(.chatPositions(chatID))
        case .chatReadInbox(let chatID, let lastReadInboxMessageID, let unreadCount):
            modifyChat(chatID) {
                $0.lastReadInboxMessageID = lastReadInboxMessageID
                $0.unreadCount = unreadCount
            }
        case .chatReadOutbox(let chatID, let lastReadOutboxMessageID):
            modifyChat(chatID) { $0.lastReadOutboxMessageID = lastReadOutboxMessageID }
        case .chatNotificationSettings(let chatID, let settings):
            modifyChat(chatID) { $0.notificationSettings = settings }
        case .chatPermissions(let chatID, let permissions):
            modifyChat(chatID) { $0.permissions = permissions }

        case .newMessage(let message):
            guard timelines[message.chatID] != nil else { return }
            if timelines[message.chatID]!.upsert(message) {
                emit(.messagesAdded(chatID: message.chatID, messageIDs: [message.id]))
            } else {
                emit(.messageChanged(chatID: message.chatID, messageID: message.id))
            }
        case .messageSendSucceeded(let message, let oldMessageID),
             .messageSendFailed(let message, let oldMessageID, _):
            replaceMessage(oldMessageID, with: message)
        case .messageContent(let chatID, let messageID, let content):
            modifyMessage(chatID, messageID) { $0.content = content }
            if chats[chatID]?.lastMessage?.id == messageID {
                modifyChat(chatID) { $0.lastMessage?.content = content }
            }
        case .messageEdited(let chatID, let messageID, let editDate):
            modifyMessage(chatID, messageID) { $0.editDate = editDate }
        case .deleteMessages(let chatID, let messageIDs, _, let fromCache):
            guard !fromCache, timelines[chatID] != nil else { return }
            let removed = messageIDs.filter { timelines[chatID]!.remove($0) }
            if !removed.isEmpty { emit(.messagesRemoved(chatID: chatID, messageIDs: removed)) }

        case .file(let file):
            files[file.id] = file
            emit(.file(file.id))

        case .unknown:
            break
        }
    }

    private func modifyChat(_ chatID: Int64, _ body: (inout Chat) -> Void) {
        guard chats[chatID] != nil else { return }
        body(&chats[chatID]!)
        emit(.chat(chatID))
    }

    private func modifyMessage(_ chatID: Int64, _ messageID: Int64, _ body: (inout Message) -> Void) {
        guard timelines[chatID]?.modify(messageID, body) == true else { return }
        emit(.messageChanged(chatID: chatID, messageID: messageID))
    }

    private func replaceMessage(_ oldMessageID: Int64, with message: Message) {
        guard timelines[message.chatID] != nil else { return }
        timelines[message.chatID]!.remove(oldMessageID)
        timelines[message.chatID]!.upsert(message)
        emit(.messageReplaced(chatID: message.chatID, oldMessageID: oldMessageID, newMessageID: message.id))
    }
}

/// Keeps a store observer registered until cancelled or deallocated.
final class StoreObservation {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit {
        cancel()
    }
}
