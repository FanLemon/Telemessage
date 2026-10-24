import AppKit
import Foundation
import Testing
@testable import TelemessageCore

/// A chat with messages 1...count whose first history request returns a single message, the way
/// TDLib answers from a cold local cache.
nonisolated final class FakeHistory: @unchecked Sendable {
    let chatID: Int64
    let count: Int64
    private var calls = 0
    private let lock = NSLock()

    init(chatID: Int64 = 100, count: Int64 = 100) {
        self.chatID = chatID
        self.count = count
    }

    func respond(_ request: [String: Any]) -> [String] {
        guard request["@type"] as? String == "getChatHistory" else {
            return [MockTransport.reply(to: request, #"{"@type":"ok"}"#)]
        }
        let from = request["from_message_id"] as? Int64 ?? 0
        var limit = request["limit"] as? Int64 ?? 50
        lock.withLock {
            if calls == 0 { limit = 1 }
            calls += 1
        }
        let newest = from == 0 ? count : from
        let ids = stride(from: newest, to: max(newest - limit, 0), by: -1)
        let messages = ids.map { Fixture.message(id: $0, chatID: chatID) }.joined(separator: ",")
        return [MockTransport.reply(to: request, #"{"@type":"messages","total_count":\#(count),"messages":[\#(messages)]}"#)]
    }
}

@MainActor
struct ConversationModelTests {
    private func makeServices(_ responder: @escaping MockTransport.Responder) -> (AccountServices, MockTransport) {
        let transport = MockTransport(responder: responder)
        let configuration = TelegramSession.Configuration(secrets: TelegramSecrets(apiID: 1, apiHash: "x"),
                                                          dataDirectory: FileManager.default.temporaryDirectory,
                                                          databaseKey: Data(), applicationVersion: "test")
        let session = TelegramSession(transport: transport, configuration: configuration)
        session.start()
        let services = AccountServices(session: session, storage: nil)
        services.store.apply(.newChat(try! Fixture.decode(Chat.self, Fixture.chat())))
        return (services, transport)
    }

    @Test func initialLoadPagesPastAThinFirstAnswer() async {
        let history = FakeHistory()
        let (services, _) = makeServices(history.respond)
        let model = ConversationModel(chatID: 100, services: services)
        model.open()
        await model.loadInitial()
        #expect(model.didLoadInitial)
        #expect(model.messages.count >= 40)
        #expect(model.messages.last?.id == 100)
        #expect(!model.reachedStart)
    }

    @Test func loadingOlderReachesTheStartWithoutDuplicates() async {
        let history = FakeHistory(count: 120)
        let (services, _) = makeServices(history.respond)
        let model = ConversationModel(chatID: 100, services: services)
        model.open()
        await model.loadInitial()
        var guardCount = 0
        while !model.reachedStart, guardCount < 20 {
            await model.loadOlder()
            guardCount += 1
        }
        #expect(model.reachedStart)
        #expect(model.messages.map(\.id) == Array(1...120))
    }

    @Test func viewedReportsOnlyUnreadIncomingOnce() async throws {
        let (services, transport) = makeServices(FakeHistory().respond)
        services.store.apply(.chatReadInbox(chatID: 100, lastReadInboxMessageID: 95, unreadCount: 5))
        let model = ConversationModel(chatID: 100, services: services)
        model.open()
        services.store.merge((94...100).map { try! Fixture.decode(Message.self, Fixture.message(id: $0)) }
            + [try Fixture.decode(Message.self, Fixture.message(id: 101, outgoing: true))], into: 100)

        model.markViewed([94, 96, 97, 101])
        model.markViewed([96, 97, 98])
        try await Task.sleep(for: .milliseconds(100))
        let viewed = transport.sent.filter { $0["@type"] as? String == "viewMessages" }.map { $0["message_ids"] as? [Int64] }
        #expect(viewed == [[96, 97], [98]])
    }

    @Test func openingNeverMarksRead() async throws {
        let (services, transport) = makeServices(FakeHistory().respond)
        let model = ConversationModel(chatID: 100, services: services)
        model.open()
        await model.loadInitial()
        try await Task.sleep(for: .milliseconds(50))
        let types = transport.sent.compactMap { $0["@type"] as? String }
        #expect(types.contains("openChat"))
        #expect(!types.contains("viewMessages"))
    }
}

@MainActor
struct TimelineBuilderTests {
    private func message(_ id: Int64, sender: Int64 = 2, at date: Int32, outgoing: Bool = false) -> Message {
        var json = Fixture.message(id: id, outgoing: outgoing)
        json = json.replacingOccurrences(of: "\"date\":1761300000", with: "\"date\":\(date)")
        json = json.replacingOccurrences(of: "\"user_id\":\(outgoing ? 1 : 2)", with: "\"user_id\":\(sender)")
        return try! Fixture.decode(Message.self, json)
    }

    @Test func daySeparators() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1: Int32 = 1_761_264_000 + 3_600  // 2025-10-24 01:00 UTC
        let day2 = day1 + 86_400
        let items = TimelineBuilder.items(for: [message(1, at: day1), message(2, at: day1 + 60), message(3, at: day2)], calendar: calendar)
        #expect(items.count == 5)
        if case .day = items[0], case .message(1) = items[1], case .message(2) = items[2], case .day = items[3], case .message(3) = items[4] {
        } else {
            Issue.record("unexpected items \(items)")
        }
    }

    @Test func grouping() {
        let base: Int32 = 1_761_300_000
        let first = message(1, at: base)
        #expect(TimelineBuilder.continuesGroup(message(2, at: base + 60), after: first))
        #expect(!TimelineBuilder.continuesGroup(message(3, at: base + 400), after: first))
        #expect(!TimelineBuilder.continuesGroup(message(4, sender: 3, at: base + 60), after: first))
        #expect(!TimelineBuilder.continuesGroup(message(5, at: base + 60, outgoing: true), after: first))
        #expect(!TimelineBuilder.continuesGroup(first, after: nil))
    }
}

@MainActor
struct MessageLayoutTests {
    private func row(_ text: String?, outgoing: Bool = false, media: MediaSpec? = nil, service: Bool = false) -> MessageRowModel {
        let message = try! Fixture.decode(Message.self, Fixture.message(id: 1, outgoing: outgoing))
        let footer = NSAttributedString(string: "10:42 ✓", attributes: [.font: MessageLayout.footerFont])
        return MessageRowModel(message: message, senderName: nil, senderColor: .red, reply: nil,
                               text: text.map { NSAttributedString(string: $0, attributes: [.font: MessageText.bodyFont]) },
                               media: media, footer: footer, continuesGroup: false, isService: service)
    }

    @Test func shortTextKeepsFooterOnItsLine() {
        let layout = MessageLayout(model: row("ok"), width: 440)
        let text = try! #require(layout.text)
        #expect(abs(layout.footer.maxY - text.maxY) < 1)
        #expect(layout.bubble.minX == MessageLayout.sideInset)
    }

    @Test func outgoingAlignsRight() {
        let layout = MessageLayout(model: row("ok", outgoing: true), width: 440)
        #expect(layout.bubble.maxX == 440 - MessageLayout.sideInset)
    }

    @Test func longTextWrapsWithinMaximumWidth() {
        let long = String(repeating: "wrapping words ", count: 40)
        let layout = MessageLayout(model: row(long), width: 440)
        #expect(layout.bubble.width <= MessageLayout.maxBubbleWidth(rowWidth: 440))
        #expect(layout.rowHeight > 100)
        #expect(layout.footer.maxY <= layout.bubble.maxY)
    }

    @Test func mediaWithoutCaptionOverlaysFooter() {
        let media = MediaSpec(kind: .photo, size: CGSize(width: 300, height: 200))
        let layout = MessageLayout(model: row(nil, media: media), width: 440)
        #expect(layout.footerOverlaysMedia)
        let mediaFrame = try! #require(layout.media)
        #expect(mediaFrame.contains(layout.footer))
    }

    @Test func narrowWindowShrinksMedia() {
        let media = MediaSpec(kind: .photo, size: CGSize(width: 320, height: 240))
        let layout = MessageLayout(model: row(nil, media: media), width: 300)
        let frame = try! #require(layout.media)
        #expect(frame.width <= MessageLayout.maxBubbleWidth(rowWidth: 300))
        #expect(abs(frame.width / frame.height - 320 / 240) < 0.02)
    }
}

@MainActor
struct PersistenceTests {
    @Test func draftsRoundTripEncrypted() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = Data((0..<32).map { UInt8($0) })
        let drafts = DraftStore(url: url, keyData: key)
        drafts.setDraft("secret plans", for: 7)
        drafts.flush()
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("secret".utf8)) == nil)
        #expect(DraftStore(url: url, keyData: key).draft(for: 7) == "secret plans")
        #expect(DraftStore(url: url, keyData: Data(repeating: 9, count: 32)).draft(for: 7) == "")
    }

    @Test func emptyDraftIsRemoved() {
        let drafts = DraftStore(url: nil, keyData: nil)
        drafts.setDraft("x", for: 1)
        drafts.setDraft("   ", for: 1)
        #expect(drafts.draft(for: 1) == "")
    }

    @Test func windowStateRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appending(path: "windows-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = WindowStateStore(url: url)
        state.update(5) { $0.keepOnTop = true; $0.frame = "{{1, 2}, {3, 4}}" }
        state.setOpenChatIDs([5, 6])
        state.flush()
        let reloaded = WindowStateStore(url: url)
        #expect(reloaded.openChatIDs == [5, 6])
        #expect(reloaded.state(for: 5).keepOnTop)
        reloaded.forget(5)
        #expect(reloaded.openChatIDs == [6])
        #expect(reloaded.state(for: 5) == WindowStateStore.ChatWindowState())
    }
}
