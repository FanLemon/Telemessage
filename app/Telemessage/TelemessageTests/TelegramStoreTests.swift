import Foundation
import Testing
@testable import TelemessageCore

@MainActor
struct TelegramStoreTests {
    private func chat(_ id: Int64, order: Int64?, list: String = "chatListMain", unread: Int32 = 0) throws -> Chat {
        try Fixture.decode(Chat.self, Fixture.chat(id: id, title: "Chat \(id)", order: order, list: list, unreadCount: unread))
    }

    private func message(_ id: Int64, chatID: Int64 = 100, outgoing: Bool = false, pending: Bool = false) throws -> Message {
        try Fixture.decode(Message.self, Fixture.message(id: id, chatID: chatID, outgoing: outgoing, pending: pending))
    }

    private func position(order: Int64, list: String = "chatListMain") throws -> ChatPosition {
        try Fixture.decode(ChatPosition.self,
                           #"{"@type":"chatPosition","list":{"@type":"\#(list)"},"order":"\#(order)","is_pinned":false}"#)
    }

    @Test func chatListOrderFollowsPositions() throws {
        let store = TelegramStore()
        store.apply(.newChat(try chat(1, order: 10)))
        store.apply(.newChat(try chat(2, order: 30)))
        store.apply(.newChat(try chat(3, order: 20)))
        store.apply(.newChat(try chat(4, order: 99, list: "chatListArchive")))
        store.apply(.newChat(try chat(5, order: nil)))
        #expect(store.chatIDs(in: .main) == [2, 3, 1])
        #expect(store.chatIDs(in: .archive) == [4])

        store.apply(.chatPosition(chatID: 1, position: try position(order: 40)))
        #expect(store.chatIDs(in: .main) == [1, 2, 3])

        // Order 0 removes the chat from the list.
        store.apply(.chatPosition(chatID: 2, position: try position(order: 0)))
        #expect(store.chatIDs(in: .main) == [1, 3])
    }

    @Test func lastMessageUpdateCarriesPositions() throws {
        let store = TelegramStore()
        store.apply(.newChat(try chat(1, order: 10)))
        store.apply(.newChat(try chat(2, order: 20)))
        store.apply(.chatLastMessage(chatID: 1, lastMessage: try message(9, chatID: 1), positions: [try position(order: 50)]))
        #expect(store.chats[1]?.lastMessage?.id == 9)
        #expect(store.chatIDs(in: .main) == [1, 2])
    }

    @Test func readInboxUpdatesUnreadCount() throws {
        let store = TelegramStore()
        store.apply(.newChat(try chat(1, order: 10, unread: 4)))
        store.apply(.chatReadInbox(chatID: 1, lastReadInboxMessageID: 77, unreadCount: 0))
        #expect(store.chats[1]?.unreadCount == 0)
        #expect(store.chats[1]?.lastReadInboxMessageID == 77)
    }

    @Test func messagesOnlyKeptForTrackedChats() throws {
        let store = TelegramStore()
        store.apply(.newMessage(try message(1, chatID: 100)))
        #expect(store.timeline(for: 100) == nil)

        store.trackMessages(in: 100)
        store.apply(.newMessage(try message(2, chatID: 100)))
        #expect(store.timeline(for: 100)?.messageIDs == [2])

        store.stopTrackingMessages(in: 100)
        #expect(store.timeline(for: 100) == nil)
    }

    @Test func historyMergesWithoutDuplicatesInOrder() throws {
        let store = TelegramStore()
        store.trackMessages(in: 100)
        store.apply(.newMessage(try message(30)))
        var changes: [StoreChange] = []
        let observation = store.observe { changes.append($0) }
        defer { observation.cancel() }

        // getChatHistory returns newest first; the live message 30 is already present.
        store.merge([try message(30), try message(20), try message(10)], into: 100)
        #expect(store.timeline(for: 100)?.messageIDs == [10, 20, 30])
        #expect(changes == [.messagesAdded(chatID: 100, messageIDs: [10, 20])])
    }

    @Test func sendSucceededReplacesTemporaryMessage() throws {
        let store = TelegramStore()
        store.trackMessages(in: 100)
        store.apply(.newMessage(try message(1_000_001, outgoing: true, pending: true)))
        var changes: [StoreChange] = []
        let observation = store.observe { changes.append($0) }
        defer { observation.cancel() }

        store.apply(.messageSendSucceeded(try message(500, outgoing: true), oldMessageID: 1_000_001))
        #expect(store.timeline(for: 100)?.messageIDs == [500])
        #expect(store.timeline(for: 100)?.messages[500]?.sendingState == nil)
        #expect(changes == [.messageReplaced(chatID: 100, oldMessageID: 1_000_001, newMessageID: 500)])
    }

    @Test func sendFailedAlsoReplacesTemporaryMessage() throws {
        let store = TelegramStore()
        store.trackMessages(in: 100)
        store.apply(.newMessage(try message(1_000_001, outgoing: true, pending: true)))
        let failed = try message(1_000_002, outgoing: true)
        store.apply(.messageSendFailed(failed, oldMessageID: 1_000_001, error: TDError(code: 400, message: "x")))
        #expect(store.timeline(for: 100)?.messageIDs == [1_000_002])
    }

    @Test func cacheEvictionDoesNotDeleteMessages() throws {
        let store = TelegramStore()
        store.trackMessages(in: 100)
        store.merge([try message(1), try message(2), try message(3)], into: 100)

        store.apply(.deleteMessages(chatID: 100, messageIDs: [1], isPermanent: false, fromCache: true))
        #expect(store.timeline(for: 100)?.messageIDs == [1, 2, 3])

        store.apply(.deleteMessages(chatID: 100, messageIDs: [1, 3, 99], isPermanent: true, fromCache: false))
        #expect(store.timeline(for: 100)?.messageIDs == [2])
    }

    @Test func contentAndEditUpdates() throws {
        let store = TelegramStore()
        store.apply(.newChat(try chat(100, order: 1)))
        store.apply(.chatLastMessage(chatID: 100, lastMessage: try message(5), positions: []))
        store.trackMessages(in: 100)
        store.merge([try message(5)], into: 100)

        let edited = MessageContent.text(FormattedText(text: "edited"))
        store.apply(.messageContent(chatID: 100, messageID: 5, content: edited))
        store.apply(.messageEdited(chatID: 100, messageID: 5, editDate: 1_761_300_100))
        #expect(store.timeline(for: 100)?.messages[5]?.content == edited)
        #expect(store.timeline(for: 100)?.messages[5]?.editDate == 1_761_300_100)
        #expect(store.chats[100]?.lastMessage?.content == edited)
    }

    @Test func fileUpdatesSupersedeEmbeddedSnapshots() throws {
        let store = TelegramStore()
        let embedded = try Fixture.decode(TDFile.self, Fixture.file(id: 7))
        #expect(store.latest(embedded).completedPath == nil)
        store.apply(.file(try Fixture.decode(TDFile.self, Fixture.file(id: 7, completed: true, path: "/tmp/a.jpg"))))
        #expect(store.latest(embedded).completedPath == "/tmp/a.jpg")
    }

    @Test func updatesForUnknownChatsAreIgnored() {
        let store = TelegramStore()
        var changes: [StoreChange] = []
        let observation = store.observe { changes.append($0) }
        defer { observation.cancel() }
        store.apply(.chatTitle(chatID: 1, title: "x"))
        store.apply(.userStatus(userID: 1, status: .recently))
        #expect(changes.isEmpty)
        #expect(store.chats.isEmpty)
    }

    @Test func myUserIDFromOption() {
        let store = TelegramStore()
        store.apply(.option(name: "my_id", value: .integer(777)))
        #expect(store.myUserID == 777)
    }

    @Test func cancelledObservationStopsDelivery() {
        let store = TelegramStore()
        var count = 0
        let observation = store.observe { _ in count += 1 }
        store.apply(.connectionState(.ready))
        observation.cancel()
        store.apply(.connectionState(.updating))
        #expect(count == 1)
    }
}
