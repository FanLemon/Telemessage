import Foundation
import Testing
@testable import TelemessageCore

@MainActor
struct SelectionStoreTests {
    @Test func replaceKeepsExistingOrderAndAppendsNew() {
        let selection = SelectionStore(url: nil)
        selection.replace(with: [1, 2, 3])
        selection.replace(with: [4, 3, 1])
        #expect(selection.chatIDs == [1, 3, 4])
    }

    @Test func moveReorders() {
        let selection = SelectionStore(url: nil)
        selection.replace(with: [1, 2, 3, 4])
        selection.move(from: [0], to: 3)
        #expect(selection.chatIDs == [2, 3, 1, 4])
        selection.move(from: [3], to: 0)
        #expect(selection.chatIDs == [4, 2, 3, 1])
        selection.move(from: [0, 1], to: 4)
        #expect(selection.chatIDs == [3, 1, 4, 2])
    }

    @Test func migrationKeepsPosition() {
        let selection = SelectionStore(url: nil)
        selection.replace(with: [1, 2, 3])
        selection.replaceChat(2, with: 20)
        #expect(selection.chatIDs == [1, 20, 3])
        // Replacing with an already-picked chat just drops the old one.
        selection.replaceChat(1, with: 3)
        #expect(selection.chatIDs == [20, 3])
    }

    @Test func persistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "selection-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SelectionStore(url: url)
        first.replace(with: [5, 6])
        first.move(from: [1], to: 0)
        #expect(SelectionStore(url: url).chatIDs == [6, 5])
    }

    @Test func observersFireOnlyOnChange() {
        let selection = SelectionStore(url: nil)
        var count = 0
        let observation = selection.observe { count += 1 }
        defer { observation.cancel() }
        selection.replace(with: [1])
        selection.replace(with: [1])
        selection.remove(99)
        #expect(count == 1)
    }
}

@MainActor
struct SelectionPolicyTests {
    private func store(_ updates: [String]) throws -> TelegramStore {
        let store = TelegramStore()
        for json in updates { store.apply(try Fixture.decodeUpdate(json)) }
        return store
    }

    private func chat(_ id: Int64, type: String) -> String {
        Fixture.update("updateNewChat", #""chat":\#(Fixture.chat(id: id).replacingOccurrences(of: #"{"@type":"chatTypePrivate","user_id":2}"#, with: type))"#)
    }

    private func supergroup(_ id: Int64, channel: Bool = false, forum: Bool = false, status: String = #"{"@type":"chatMemberStatusMember","member_until_date":0}"#) -> String {
        Fixture.update("updateSupergroup", #""supergroup":{"@type":"supergroup","id":\#(id),"member_count":3,"status":\#(status),"is_channel":\#(channel),"is_forum":\#(forum)}"#)
    }

    @Test func eligibility() throws {
        let store = try store([
            supergroup(1, channel: true), supergroup(2, forum: true), supergroup(3),
            chat(-1, type: #"{"@type":"chatTypeSupergroup","supergroup_id":1,"is_channel":true}"#),
            chat(-2, type: #"{"@type":"chatTypeSupergroup","supergroup_id":2,"is_channel":false}"#),
            chat(-3, type: #"{"@type":"chatTypeSupergroup","supergroup_id":3,"is_channel":false}"#),
            chat(-4, type: #"{"@type":"chatTypeSecret","secret_chat_id":9,"user_id":2}"#),
            chat(2, type: #"{"@type":"chatTypePrivate","user_id":2}"#),
        ])
        let selection = SelectionStore(url: nil)
        selection.replace(with: [-1, -3, 2])
        let policy = SelectionPolicy(selection: selection, store: store)
        #expect(policy.eligibility(of: store.chats[-1]!) == .unsupported("Channels aren't supported"))
        #expect(policy.eligibility(of: store.chats[-2]!) == .unsupported("Forum groups aren't supported yet"))
        #expect(policy.eligibility(of: store.chats[-3]!) == .eligible)
        #expect(policy.eligibility(of: store.chats[-4]!) == .unsupported("Secret chats aren't supported"))
        #expect(policy.canPresent(-3))
        #expect(policy.canPresent(2))
        #expect(!policy.canPresent(-1))  // picked but a channel
        #expect(!policy.canPresent(-2))  // eligible-looking but not picked
        #expect(!policy.canPresent(77))  // unknown chat
    }

    @Test func sendingPermissions() throws {
        let restricted = #"{"@type":"chatMemberStatusRestricted","is_member":true,"restricted_until_date":0,"permissions":{"@type":"chatPermissions","can_send_basic_messages":false,"can_send_audios":false,"can_send_documents":false,"can_send_photos":false,"can_send_videos":false,"can_send_video_notes":false,"can_send_voice_notes":false,"can_send_polls":false,"can_send_other_messages":false,"can_add_link_previews":false}}"#
        let store = try store([
            supergroup(3), supergroup(4, status: #"{"@type":"chatMemberStatusLeft"}"#), supergroup(5, status: restricted),
            chat(-3, type: #"{"@type":"chatTypeSupergroup","supergroup_id":3,"is_channel":false}"#),
            chat(-4, type: #"{"@type":"chatTypeSupergroup","supergroup_id":4,"is_channel":false}"#),
            chat(-5, type: #"{"@type":"chatTypeSupergroup","supergroup_id":5,"is_channel":false}"#),
        ])
        let policy = SelectionPolicy(selection: SelectionStore(url: nil), store: store)
        #expect(policy.canSendMessages(in: store.chats[-3]!))
        #expect(!policy.canSendMessages(in: store.chats[-4]!))
        #expect(!policy.canSendMessages(in: store.chats[-5]!))
    }
}

@MainActor
struct PresentationTests {
    @Test func summaries() throws {
        #expect(ChatPresentation.summary(of: .text(FormattedText(text: "a\nb"))) == "a b")
        #expect(ChatPresentation.summary(of: .unsupported("messagePoll")) == "Poll")
        #expect(ChatPresentation.summary(of: .unsupported("messageSomethingNew")) == "Unsupported message")
    }

    @Test func outgoingPreviewIsPrefixed() throws {
        let store = TelegramStore()
        var chat = try Fixture.decode(Chat.self, Fixture.chat())
        chat.lastMessage = try Fixture.decode(Message.self, Fixture.message(id: 1, outgoing: true))
        store.apply(.newChat(chat))
        #expect(ChatPresentation(store: store).preview(of: store.chats[100]!) == "You: Message 1")
    }

    @Test func initials() {
        #expect(ChatPresentation.initials("Alex Chen") == "AC")
        #expect(ChatPresentation.initials("design team rocks") == "DT")
        #expect(ChatPresentation.initials("🎉 Party") == "P")
        #expect(ChatPresentation.initials("") == "?")
    }

    @Test func dayTitles() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_761_300_000)
        #expect(RelativeTime.dayTitle(now, now: now, calendar: calendar) == "Today")
        #expect(RelativeTime.dayTitle(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
    }
}
