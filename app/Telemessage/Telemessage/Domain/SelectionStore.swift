import Foundation
import os

/// The account's picked chats in their manual order, persisted in the account's App directory.
///
/// Selection is local to Telemessage: it never changes Telegram folders, pins, archive state,
/// membership or notification settings.
final class SelectionStore {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        let chatID: Int64
        let addedAt: Date
    }

    private nonisolated struct Document: Codable {
        var version = 1
        var chats: [Entry]
    }

    private(set) var entries: [Entry]
    private let url: URL?
    private var observers: [UUID: () -> Void] = [:]

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Selection")

    /// `url == nil` keeps the selection in memory only (tests, snapshots).
    init(url: URL?) {
        self.url = url
        entries = url.flatMap { JSONFileStore.load(Document.self, from: $0)?.chats } ?? []
    }

    var chatIDs: [Int64] { entries.map(\.chatID) }

    func contains(_ chatID: Int64) -> Bool {
        entries.contains { $0.chatID == chatID }
    }

    /// Replaces the selection. Chats that stay keep their position; new chats are appended in the given order.
    func replace(with chatIDs: [Int64], now: Date = .now) {
        let wanted = Set(chatIDs)
        var result = entries.filter { wanted.contains($0.chatID) }
        let kept = Set(result.map(\.chatID))
        var appended = Set<Int64>()
        for chatID in chatIDs where !kept.contains(chatID) && appended.insert(chatID).inserted {
            result.append(Entry(chatID: chatID, addedAt: now))
        }
        commit(result)
    }

    func remove(_ chatID: Int64) {
        commit(entries.filter { $0.chatID != chatID })
    }

    /// Moves the entries at `source` so they land before the entry currently at `destination`.
    func move(from source: IndexSet, to destination: Int) {
        var result = entries
        let moving = source.map { result[$0] }
        let insertionIndex = destination - source.count(in: 0..<destination)
        for index in source.reversed() { result.remove(at: index) }
        result.insert(contentsOf: moving, at: insertionIndex)
        commit(result)
    }

    /// Swaps a chat for its replacement (basic group migrated to a supergroup), keeping its position.
    func replaceChat(_ oldChatID: Int64, with newChatID: Int64) {
        guard let index = entries.firstIndex(where: { $0.chatID == oldChatID }) else { return }
        var result = entries
        if result.contains(where: { $0.chatID == newChatID }) {
            result.remove(at: index)
        } else {
            result[index] = Entry(chatID: newChatID, addedAt: result[index].addedAt)
        }
        commit(result)
    }

    func observe(_ handler: @escaping () -> Void) -> StoreObservation {
        let id = UUID()
        observers[id] = handler
        return StoreObservation { [weak self] in self?.observers[id] = nil }
    }

    private func commit(_ newEntries: [Entry]) {
        guard newEntries != entries else { return }
        entries = newEntries
        if let url {
            do {
                try JSONFileStore.save(Document(chats: entries), to: url)
            } catch {
                Self.logger.error("Saving selection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for observer in observers.values { observer() }
    }
}
