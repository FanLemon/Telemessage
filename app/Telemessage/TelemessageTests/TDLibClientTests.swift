import Foundation
import Testing
@testable import TelemessageCore

@MainActor
struct TDLibClientTests {
    /// Starts a client whose updates go into `store`; returns a teardown closure.
    private func start(_ client: TDLibClient, store: TelegramStore) -> () -> Void {
        client.startReceiving()
        let runner = Task { await client.run { store.apply($0) } }
        return {
            client.shutdown()
            runner.cancel()
        }
    }

    @Test func responseResolvesMatchingRequest() async throws {
        let transport = MockTransport { request in
            [MockTransport.reply(to: request, Fixture.chat(id: request["chat_id"] as? Int64 ?? 0, title: "Chat"))]
        }
        let client = TDLibClient(transport: transport)
        let stop = start(client, store: TelegramStore())
        defer { stop() }

        async let first = client.send(GetChat(chatID: 1))
        async let second = client.send(GetChat(chatID: 2))
        let (a, b) = try await (first, second)
        #expect(a.id == 1)
        #expect(b.id == 2)
    }

    @Test func updatesBeforeResponseAreAppliedFirst() async throws {
        let transport = MockTransport { request in
            [
                Fixture.update("updateChatTitle", #""chat_id":100,"title":"Renamed""#),
                MockTransport.reply(to: request, Fixture.chat(title: "Renamed")),
            ]
        }
        let store = TelegramStore()
        store.apply(.newChat(try Fixture.decode(Chat.self, Fixture.chat(title: "Alex"))))
        let client = TDLibClient(transport: transport)
        let stop = start(client, store: store)
        defer { stop() }

        _ = try await client.send(GetChat(chatID: 100))
        #expect(store.chats[100]?.title == "Renamed")
    }

    @Test func errorResponseThrows() async throws {
        let transport = MockTransport { request in
            [MockTransport.reply(to: request, #"{"@type":"error","code":400,"message":"PHONE_CODE_INVALID"}"#)]
        }
        let client = TDLibClient(transport: transport)
        let stop = start(client, store: TelegramStore())
        defer { stop() }

        await #expect(throws: TDError(code: 400, message: "PHONE_CODE_INVALID")) {
            try await client.send(CheckAuthenticationCode(code: "00000"))
        }
    }

    @Test func shutdownFailsPendingRequestsOnce() async throws {
        let client = TDLibClient(transport: MockTransport())  // never answers
        let stop = start(client, store: TelegramStore())
        defer { stop() }

        let pending = Task { try await client.send(GetMe()) }
        try await Task.sleep(for: .milliseconds(50))
        client.shutdown()
        client.shutdown()
        await #expect(throws: TDClientError.closed) { try await pending.value }
        await #expect(throws: TDClientError.closed) { try await client.send(GetMe()) }
    }

    @Test func closedAuthorizationStateShutsDown() async throws {
        let transport = MockTransport { request in
            guard request["@type"] as? String == "close" else { return [] }
            return [
                Fixture.update("updateAuthorizationState", #""authorization_state":{"@type":"authorizationStateClosing"}"#),
                MockTransport.reply(to: request, #"{"@type":"ok"}"#),
                Fixture.update("updateAuthorizationState", #""authorization_state":{"@type":"authorizationStateClosed"}"#),
            ]
        }
        let store = TelegramStore()
        let client = TDLibClient(transport: transport)
        let stop = start(client, store: store)
        defer { stop() }

        _ = try await client.send(Close())
        // The closed update follows the response; wait for the consumer to apply it.
        for _ in 0..<100 where store.authorizationState != .closed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.authorizationState == .closed)
        await #expect(throws: TDClientError.closed) { try await client.send(GetMe()) }
    }

    @Test func undecodableEventIsDropped() {
        #expect(TDLibClient.decodeEvent(Data("not json".utf8)) == nil)
        // A modeled update with a missing required field must not crash the pipeline.
        #expect(TDLibClient.decodeEvent(Data(#"{"@type":"updateChatTitle","chat_id":1}"#.utf8)) == nil)
    }
}
