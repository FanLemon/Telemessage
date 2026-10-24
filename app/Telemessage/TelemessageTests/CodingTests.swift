import Foundation
import Testing
@testable import TelemessageCore

struct KeyMappingTests {
    @Test(arguments: [
        ("chat_id", "chatID"),
        ("message_ids", "messageIDs"),
        ("last_read_inbox_message_id", "lastReadInboxMessageID"),
        ("is_outgoing", "isOutgoing"),
        ("id", "id"),
        ("title", "title"),
        ("@type", "@type"),
        ("@extra", "@extra"),
    ])
    func jsonToSwift(json: String, swift: String) {
        #expect(TDCoding.swiftKey(forJSONKey: json) == swift)
    }

    @Test(arguments: [
        ("chatID", "chat_id"),
        ("messageIDs", "message_ids"),
        ("otherUserIDs", "other_user_ids"),
        ("useTestDc", "use_test_dc"),
        ("apiID", "api_id"),
        ("newVerbosityLevel", "new_verbosity_level"),
        ("id", "id"),
        ("@type", "@type"),
    ])
    func swiftToJSON(swift: String, json: String) {
        #expect(TDCoding.jsonKey(forSwiftKey: swift) == json)
    }
}

struct ValueCodingTests {
    @Test func int64DecodesFromStringOrNumber() throws {
        #expect(try Fixture.decode(TDInt64.self, #""9007199254740993""#) == TDInt64(9_007_199_254_740_993))
        #expect(try Fixture.decode(TDInt64.self, "42") == 42)
    }

    @Test func int64EncodesAsString() throws {
        let data = try TDCoding.encoder.encode([TDInt64(9_007_199_254_740_993)])
        #expect(String(decoding: data, as: UTF8.self) == #"["9007199254740993"]"#)
    }

    @Test func chatListRoundTrips() throws {
        for list in [ChatList.main, .archive, .folder(3)] {
            let data = try TDCoding.encoder.encode(list)
            #expect(try TDCoding.decoder.decode(ChatList.self, from: data) == list)
        }
    }
}

struct RequestEncodingTests {
    /// Sends one request through a client and returns the JSON object the transport received.
    @MainActor
    private func encoded<R: TDRequest>(_ request: R) async throws -> [String: Any] {
        let transport = MockTransport { [MockTransport.reply(to: $0, #"{"@type":"ok"}"#)] }
        let client = TDLibClient(transport: transport)
        client.startReceiving()
        let runner = Task { await client.run { _ in } }
        defer {
            client.shutdown()
            runner.cancel()
        }
        _ = try? await client.send(request)
        return try #require(transport.sent.first)
    }

    @Test func envelopeAddsTypeAndExtra() async throws {
        let json = try await encoded(GetChatHistory(chatID: 100, fromMessageID: 0, limit: 30))
        #expect(json["@type"] as? String == "getChatHistory")
        #expect(json["@extra"] as? Int == 1)
        #expect(json["chat_id"] as? Int == 100)
        #expect(json["from_message_id"] as? Int == 0)
        #expect(json["limit"] as? Int == 30)
        #expect(json["only_local"] as? Bool == false)
    }

    @Test func sendMessageNestsTypedObjects() async throws {
        let json = try await encoded(SendMessage(chatID: 100, text: FormattedText(text: "hi"), replyToMessageID: 55))
        let content = try #require(json["input_message_content"] as? [String: Any])
        #expect(content["@type"] as? String == "inputMessageText")
        #expect((content["text"] as? [String: Any])?["text"] as? String == "hi")
        let reply = try #require(json["reply_to"] as? [String: Any])
        #expect(reply["@type"] as? String == "inputMessageReplyToMessage")
        #expect(reply["message_id"] as? Int == 55)
    }

    @Test func sendMessageOmitsNilReply() async throws {
        let json = try await encoded(SendMessage(chatID: 100, text: FormattedText(text: "hi")))
        #expect(json["reply_to"] == nil)
    }

    @Test func loadChatsEncodesChatList() async throws {
        let json = try await encoded(LoadChats(chatList: .archive, limit: 20))
        #expect((json["chat_list"] as? [String: Any])?["@type"] as? String == "chatListArchive")
    }

    @Test func emailCodeIsTyped() async throws {
        let json = try await encoded(CheckAuthenticationEmailCode(code: "12345"))
        let code = try #require(json["code"] as? [String: Any])
        #expect(code["@type"] as? String == "emailAddressAuthenticationCode")
        #expect(code["code"] as? String == "12345")
    }
}
