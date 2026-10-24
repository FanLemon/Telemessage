import Foundation
import Testing
@testable import TelemessageCore

struct DecodingTests {
    @Test func newChatWithInt64Order() throws {
        let update = try Fixture.decodeUpdate(Fixture.update("updateNewChat", #""chat":\#(Fixture.chat(order: 9_007_199_254_740_993))"#))
        guard case .newChat(let chat) = update else { Issue.record("got \(update)"); return }
        #expect(chat.id == 100)
        #expect(chat.type == .private(userID: 2))
        #expect(chat.title == "Alex")
        #expect(chat.position(in: .main)?.order == TDInt64(9_007_199_254_740_993))
        #expect(chat.photo == nil)
        #expect(chat.lastMessage == nil)
        #expect(chat.notificationSettings.showPreview == false)
    }

    @Test func textMessageWithEntities() throws {
        let content = #"""
        {"@type":"messageText","text":{"@type":"formattedText","text":"see https://x.y",
         "entities":[{"@type":"textEntity","offset":0,"length":3,"type":{"@type":"textEntityTypeBold"}},
                     {"@type":"textEntity","offset":4,"length":11,"type":{"@type":"textEntityTypeUrl"}},
                     {"@type":"textEntity","offset":0,"length":3,"type":{"@type":"textEntityTypeTextUrl","url":"https://a.b"}}]}}
        """#
        let message = try Fixture.decode(Message.self, Fixture.message(id: 1, content: content))
        guard case .text(let text) = message.content else { Issue.record("got \(message.content)"); return }
        #expect(text.text == "see https://x.y")
        #expect(text.entities.map(\.type) == [.bold, .other("textEntityTypeUrl"), .textURL("https://a.b")])
        #expect(message.senderID == .user(2))
        #expect(message.sendingState == nil)
    }

    @Test func photoMessageDecodesMinithumbnailBytes() throws {
        let content = """
        {"@type":"messagePhoto","photo":{"@type":"photo","has_stickers":false,
          "minithumbnail":{"@type":"minithumbnail","width":40,"height":30,"data":"AQID"},
          "sizes":[{"@type":"photoSize","type":"x","photo":\(Fixture.file()),"width":800,"height":600,"progressive_sizes":[]}]},
         "caption":{"@type":"formattedText","text":"Look","entities":[]},
         "show_caption_above_media":false,"has_spoiler":false,"is_secret":false}
        """
        let message = try Fixture.decode(Message.self, Fixture.message(id: 2, content: content))
        guard case .photo(let photo, let caption) = message.content else { Issue.record("got \(message.content)"); return }
        #expect(photo.minithumbnail?.data == Data([1, 2, 3]))
        #expect(photo.sizes.first?.width == 800)
        #expect(photo.sizes.first?.photo.id == 7)
        #expect(caption.text == "Look")
    }

    @Test func stickerFormat() throws {
        let content = """
        {"@type":"messageSticker","is_premium":false,"sticker":{"@type":"sticker","id":"123","set_id":"456",
          "width":512,"height":512,"emoji":"👍","format":{"@type":"stickerFormatTgs"},
          "full_type":{"@type":"stickerFullTypeRegular"},"sticker":\(Fixture.file())}}
        """
        let message = try Fixture.decode(Message.self, Fixture.message(id: 3, content: content))
        guard case .sticker(let sticker) = message.content else { Issue.record("got \(message.content)"); return }
        #expect(sticker.format == .tgs)
        #expect(sticker.setID == 456)
        #expect(sticker.thumbnail == nil)
    }

    @Test func unknownContentIsKept() throws {
        let content = #"{"@type":"messagePoll","poll":{"@type":"poll"}}"#
        let message = try Fixture.decode(Message.self, Fixture.message(id: 4, content: content))
        #expect(message.content == .unsupported("messagePoll"))
    }

    @Test func unknownUpdateIsIgnored() throws {
        let update = try Fixture.decodeUpdate(#"{"@type":"updateStoryListChatCount","story_list":{},"chat_count":3}"#)
        #expect(update == .unknown("updateStoryListChatCount"))
    }

    @Test func pendingOutgoingMessage() throws {
        let message = try Fixture.decode(Message.self, Fixture.message(id: 10, outgoing: true, pending: true))
        #expect(message.isOutgoing)
        #expect(message.sendingState == .pending)
    }

    @Test func waitCodeState() throws {
        let json = """
        {"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitCode",
          "code_info":{"@type":"authenticationCodeInfo","phone_number":"+10000000000",
            "type":{"@type":"authenticationCodeTypeTelegramMessage","length":5},
            "next_type":{"@type":"authenticationCodeTypeSms","length":5},"timeout":60}}}
        """
        guard case .authorizationState(.waitCode(let info)) = try Fixture.decodeUpdate(json) else {
            Issue.record("unexpected update"); return
        }
        #expect(info.type.name == "TelegramMessage")
        #expect(info.type.length == 5)
        #expect(info.nextType?.name == "Sms")
        #expect(info.timeout == 60)
    }

    @Test func waitPasswordState() throws {
        let json = """
        {"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitPassword",
          "password_hint":"pet","has_recovery_email_address":true,"has_passport_data":false,
          "recovery_email_address_pattern":"a***@b.c"}}
        """
        let expected = AuthorizationState.PasswordInfo(
            passwordHint: "pet", hasRecoveryEmailAddress: true, recoveryEmailAddressPattern: "a***@b.c")
        #expect(try Fixture.decodeUpdate(json) == .authorizationState(.waitPassword(expected)))
    }

    @Test func userWithStatus() throws {
        let json = """
        {"@type":"updateUser","user":{"@type":"user","id":2,"first_name":"Alex","last_name":"",
          "usernames":{"@type":"usernames","active_usernames":["alex"],"disabled_usernames":[],
                       "editable_username":"alex","collectible_usernames":[]},
          "phone_number":"","status":{"@type":"userStatusOffline","was_online":1761300000},
          "accent_color_id":1,"is_contact":true,"is_mutual_contact":false,"type":{"@type":"userTypeRegular"}}}
        """
        guard case .user(let user) = try Fixture.decodeUpdate(json) else { Issue.record("unexpected update"); return }
        #expect(user.fullName == "Alex")
        #expect(user.status == .offline(wasOnline: 1_761_300_000))
        #expect(user.usernames?.activeUsernames == ["alex"])
        #expect(user.profilePhoto == nil)
    }

    @Test func deleteMessages() throws {
        let json = Fixture.update("updateDeleteMessages", #""chat_id":100,"message_ids":[1,2],"is_permanent":true,"from_cache":false"#)
        #expect(try Fixture.decodeUpdate(json) == .deleteMessages(chatID: 100, messageIDs: [1, 2], isPermanent: true, fromCache: false))
    }

    @Test func optionValue() throws {
        let json = Fixture.update("updateOption", #""name":"my_id","value":{"@type":"optionValueInteger","value":"777"}"#)
        #expect(try Fixture.decodeUpdate(json) == .option(name: "my_id", value: .integer(777)))
    }

    @Test func messagesSkipsNulls() throws {
        let json = #"{"@type":"messages","total_count":2,"messages":[\#(Fixture.message(id: 1)),null]}"#
        #expect(try Fixture.decode(Messages.self, json).messages.map(\.id) == [1])
    }
}
