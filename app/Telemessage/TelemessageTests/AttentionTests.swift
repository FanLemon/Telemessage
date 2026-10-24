import Foundation
import Testing
@testable import TelemessageCore

final class FakePoster: NotificationPosting {
    struct Posted: Equatable {
        let identifier: String
        let title: String
        let subtitle: String?
        let body: String
    }

    var posted: [Posted] = []
    var removed: [String] = []
    var removedAll = 0

    func requestAuthorization() async -> Bool { true }

    func post(identifier: String, threadIdentifier: String, title: String, subtitle: String?, body: String, chatID: Int64) {
        posted.append(Posted(identifier: identifier, title: title, subtitle: subtitle, body: body))
    }

    func removeDelivered(identifiers: [String]) { removed += identifiers }
    func removeAllDelivered() { removedAll += 1 }
}

@MainActor
struct AttentionTests {
    let now = Date(timeIntervalSince1970: 1_761_300_100)

    private struct Harness {
        let services: AccountServices
        let settings: AppSettings
        let poster: FakePoster
        let coordinator: AttentionCoordinator
        let badge: () -> String?
    }

    private func harness(viewing: Set<Int64> = [], muted: Bool = false, picked: [Int64] = [100]) throws -> Harness {
        let configuration = TelegramSession.Configuration(secrets: TelegramSecrets(apiID: 1, apiHash: "x"),
                                                          dataDirectory: FileManager.default.temporaryDirectory,
                                                          databaseKey: Data(), applicationVersion: "test")
        let session = TelegramSession(transport: MockTransport(), configuration: configuration)
        let services = AccountServices(session: session, storage: nil)
        var json = Fixture.chat(id: 100, title: "Alex", unreadCount: 3)
        if muted {
            json = json.replacingOccurrences(of: #""use_default_mute_for":true,"mute_for":0"#, with: #""use_default_mute_for":false,"mute_for":3600"#)
        }
        services.store.apply(.newChat(try Fixture.decode(Chat.self, json)))
        services.store.apply(.newChat(try Fixture.decode(Chat.self, Fixture.chat(id: 200, title: "Other", unreadCount: 7))))
        services.selection.replace(with: picked)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "tm-tests-\(UUID().uuidString)")!)
        settings.notificationsEnabled = true
        let poster = FakePoster()
        var badge: String?
        let coordinator = AttentionCoordinator(services: services, settings: settings, poster: poster,
                                               isViewing: { viewing.contains($0) }, setBadge: { badge = $0 }, now: now)
        coordinator.start()
        return Harness(services: services, settings: settings, poster: poster, coordinator: coordinator, badge: { badge })
    }

    private func incoming(_ id: Int64, chat: Int64 = 100, ago: TimeInterval = 5) throws -> Update {
        var json = Fixture.message(id: id, chatID: chat)
        json = json.replacingOccurrences(of: "\"date\":1761300000", with: "\"date\":\(Int(now.timeIntervalSince1970 - ago))")
        return .newMessage(try Fixture.decode(Message.self, json))
    }

    @Test func notifiesForPickedChatWithoutPreviewByDefault() throws {
        let h = try harness()
        h.coordinator.handle(try incoming(10), now: now)
        #expect(h.poster.posted == [.init(identifier: "msg-100-10", title: "Alex", subtitle: nil, body: "New message")])
    }

    @Test func previewWhenEnabled() throws {
        let h = try harness()
        h.settings.notificationPreviews = true
        h.coordinator.handle(try incoming(10), now: now)
        #expect(h.poster.posted.first?.body == "Message 10")
    }

    @Test func silentCases() throws {
        let unpicked = try harness()
        unpicked.coordinator.handle(try incoming(10, chat: 200), now: now)
        #expect(unpicked.poster.posted.isEmpty)

        let muted = try harness(muted: true)
        muted.coordinator.handle(try incoming(10), now: now)
        #expect(muted.poster.posted.isEmpty)

        let viewing = try harness(viewing: [100])
        viewing.coordinator.handle(try incoming(10), now: now)
        #expect(viewing.poster.posted.isEmpty)

        let backlog = try harness()
        backlog.coordinator.handle(try incoming(10, ago: 3_600), now: now)
        #expect(backlog.poster.posted.isEmpty)

        let disabled = try harness()
        disabled.settings.notificationsEnabled = false
        disabled.coordinator.handle(try incoming(10), now: now)
        #expect(disabled.poster.posted.isEmpty)

        let outgoing = try harness()
        outgoing.coordinator.handle(.newMessage(try Fixture.decode(Message.self, Fixture.message(id: 11, outgoing: true))), now: now)
        #expect(outgoing.poster.posted.isEmpty)
    }

    @Test func readingWithdrawsNotifications() throws {
        let h = try harness()
        h.coordinator.handle(try incoming(10), now: now)
        h.coordinator.handle(try incoming(11), now: now)
        h.coordinator.handle(.chatReadInbox(chatID: 100, lastReadInboxMessageID: 10, unreadCount: 1), now: now)
        #expect(h.poster.removed == ["msg-100-10"])
    }

    @Test func unpickingWithdrawsNotifications() throws {
        let h = try harness()
        h.coordinator.handle(try incoming(10), now: now)
        h.services.selection.remove(100)
        #expect(h.poster.removed == ["msg-100-10"])
    }

    @Test func badgeCountsOnlyPickedUnmutedChats() throws {
        let h = try harness(picked: [100])
        #expect(h.badge() == "3")
        h.services.selection.replace(with: [100, 200])
        #expect(h.badge() == "10")
        let muted = try harness(muted: true, picked: [100])
        #expect(muted.badge() == nil)
    }

    @Test func endingClearsEverything() throws {
        let h = try harness()
        h.coordinator.end()
        #expect(h.poster.removedAll == 1)
        #expect(h.badge() == nil)
    }
}
