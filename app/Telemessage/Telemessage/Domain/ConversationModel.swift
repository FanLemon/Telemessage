import Foundation
import os

/// History, sending and read reporting for one open chat window.
///
/// Opening loads recent history but never marks anything read; only `markViewed` does, and the
/// window calls it only for messages actually on screen while it is key and the app is active.
final class ConversationModel {
    let chatID: Int64
    private let services: AccountServices
    private(set) var isLoadingOlder = false
    private(set) var reachedStart = false
    private(set) var didLoadInitial = false
    /// Replied-to messages outside the loaded history; nil when unavailable (deleted, inaccessible).
    private var replyCache: [Int64: Message?] = [:]
    private var replyFetches: Set<Int64> = []
    private var reported: Set<Int64> = []

    /// Called when a replied-to message outside the loaded history arrives.
    var onReplyLoaded: (() -> Void)?

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Conversation")

    init(chatID: Int64, services: AccountServices) {
        self.chatID = chatID
        self.services = services
    }

    var chat: Chat? { services.store.chats[chatID] }
    var messages: [Message] { services.store.timeline(for: chatID)?.orderedMessages ?? [] }

    func message(_ id: Int64) -> Message? { services.store.timeline(for: chatID)?.messages[id] }

    // MARK: Lifecycle

    func open() {
        services.store.trackMessages(in: chatID)
        services.session.post(OpenChat(chatID: chatID))
    }

    func close() {
        services.session.post(CloseChat(chatID: chatID))
        services.store.stopTrackingMessages(in: chatID)
    }

    // MARK: History

    /// Loads recent messages. TDLib may answer from its local cache with only a few messages at
    /// first, so keep paging until there is a screenful or the history ends.
    func loadInitial() async {
        var fromID: Int64 = 0
        for _ in 0..<5 {
            guard let added = await loadPage(from: fromID, limit: 50) else { break }
            if added == 0 {
                reachedStart = true
                break
            }
            guard messages.count < 40, let oldest = messages.first?.id else { break }
            fromID = oldest
        }
        didLoadInitial = true
    }

    /// Loads the page before the oldest loaded message. Returns whether anything was added.
    @discardableResult
    func loadOlder() async -> Bool {
        guard !isLoadingOlder, !reachedStart, let oldest = messages.first?.id else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        guard let added = await loadPage(from: oldest, limit: 50) else { return false }
        if added == 0 { reachedStart = true }
        return added > 0
    }

    /// Returns how many messages older than `fromID` arrived, or nil on failure.
    private func loadPage(from fromID: Int64, limit: Int32) async -> Int? {
        do {
            let page = try await services.session.send(GetChatHistory(chatID: chatID, fromMessageID: fromID, limit: limit))
            services.store.merge(page.messages, into: chatID)
            // `fromMessageID` itself is included in the result; it does not count as progress.
            return page.messages.filter { fromID == 0 || $0.id < fromID }.count
        } catch {
            Self.logger.error("getChatHistory failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Replies

    enum Reply {
        case loaded(Message)
        case loading
        case unavailable
    }

    /// The message `message` replies to; fetches it once when it isn't loaded. Nil when not a reply.
    func reply(for message: Message) -> Reply? {
        guard case .message(let replyChatID, let replyID)? = message.replyTo else { return nil }
        if replyChatID == chatID, let loaded = self.message(replyID) { return .loaded(loaded) }
        if let cached = replyCache[replyID] { return cached.map(Reply.loaded) ?? .unavailable }
        if replyFetches.insert(replyID).inserted {
            // Holds the model only for the duration of one short request.
            Task { [services] in
                let replied = try? await services.session.send(GetMessage(chatID: replyChatID, messageID: replyID))
                self.replyCache[replyID] = .some(replied)
                self.onReplyLoaded?()
            }
        }
        return .loading
    }

    // MARK: Sending

    func sendText(_ text: String, replyTo replyID: Int64?) async throws {
        _ = try await services.session.send(SendMessage(chatID: chatID, text: FormattedText(text: text), replyToMessageID: replyID))
    }

    /// Sends prepared attachments in order: photos/videos as albums of up to 10, documents likewise.
    /// The caption goes on the first item; text too long for a caption follows as its own message.
    func sendAttachments(_ attachments: [PreparedAttachment], text: String, asFiles: Bool, replyTo replyID: Int64?) async throws {
        let captionLimit = 1_024
        let caption = text.count <= captionLimit ? text : ""
        var reply = replyID
        for (groupIndex, group) in AlbumGrouping.groups(attachments, asFiles: asFiles).enumerated() {
            let contents = group.enumerated().map { index, attachment in
                attachment.content(asFile: asFiles,
                                   caption: FormattedText(text: groupIndex == 0 && index == 0 ? caption : ""))
            }
            let sent: [Message]
            if contents.count == 1 {
                sent = [try await services.session.send(SendMessage(chatID: chatID, content: contents[0], replyToMessageID: reply))]
            } else {
                sent = try await services.session.send(SendMessageAlbum(chatID: chatID, contents: contents, replyToMessageID: reply)).messages
            }
            reply = nil
            for (attachment, message) in zip(group, sent) {
                let uploads = attachment.uploadPaths(asFile: asFiles)
                services.staging.register(paths: uploads, chatID: chatID, messageID: message.id)
                services.staging.discard(attachment.allPaths.filter { !uploads.contains($0) })
            }
        }
        if caption.isEmpty, !text.isEmpty {
            try await sendText(text, replyTo: nil)
        }
    }

    /// Retries a message in the failed state. TDLib replaces it with a new message, so its staged
    /// files are carried over to the new id.
    func retry(_ messageID: Int64) {
        let staging = services.staging
        staging.beginRetry(chatID: chatID, messageID: messageID)
        Task { [chatID, services] in
            let result = try? await services.session.send(ResendMessages(chatID: chatID, messageIDs: [messageID]))
            staging.finishRetry(chatID: chatID, oldMessageID: messageID, newMessageID: result?.messages.first?.id)
        }
    }

    /// Cancels an upload in progress by deleting the pending message.
    func cancelSending(_ messageID: Int64) {
        services.session.post(DeleteMessages(chatID: chatID, messageIDs: [messageID], revoke: true))
    }

    func deleteLocally(_ messageID: Int64) {
        services.session.post(DeleteMessages(chatID: chatID, messageIDs: [messageID], revoke: false))
    }

    // MARK: Read state

    /// Reports messages that are visible to the user. Only unread incoming messages are sent.
    func markViewed(_ messageIDs: [Int64]) {
        guard let chat else { return }
        let unread = messageIDs.filter { id in
            id > chat.lastReadInboxMessageID && !reported.contains(id) && message(id)?.isOutgoing == false
        }
        guard !unread.isEmpty else { return }
        reported.formUnion(unread)
        services.session.post(ViewMessages(chatID: chatID, messageIDs: unread.sorted()))
    }
}

/// Rows of a conversation: day separators between messages from different days.
enum TimelineItem: Hashable {
    case day(Date)
    case message(Int64)
}

enum TimelineBuilder {
    static func items(for messages: [Message], calendar: Calendar = .current) -> [TimelineItem] {
        var items: [TimelineItem] = []
        items.reserveCapacity(messages.count + 8)
        var currentDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: date(of: message))
            if day != currentDay {
                items.append(.day(day))
                currentDay = day
            }
            items.append(.message(message.id))
        }
        return items
    }

    /// Consecutive messages from one sender within five minutes share a visual group.
    static func continuesGroup(_ message: Message, after previous: Message?, calendar: Calendar = .current) -> Bool {
        guard let previous, previous.senderID == message.senderID, previous.isOutgoing == message.isOutgoing else { return false }
        guard !isService(previous), !isService(message) else { return false }
        guard calendar.isDate(date(of: previous), inSameDayAs: date(of: message)) else { return false }
        return message.date - previous.date < 300
    }

    static func isService(_ message: Message) -> Bool {
        if case .unsupported(let type) = message.content { return ServiceText.isServiceMessage(type) }
        return false
    }

    static func date(of message: Message) -> Date {
        Date(timeIntervalSince1970: TimeInterval(message.date))
    }
}
