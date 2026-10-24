import Foundation
import os

/// Tracks staged upload files until TDLib no longer needs them, across restarts.
///
/// Files of a message stay while it is pending or failed (a retry re-reads them) and are deleted
/// once it is sent, deleted, or gone after a restart. Attachments still in a composer tray are not
/// tracked and are removed at the next launch.
final class StagingStore {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var chatID: Int64
        var messageID: Int64
        var paths: [String]
    }

    let directory: URL
    private let manifestURL: URL?
    private var entries: [Entry]
    /// Failed messages being resent: TDLib deletes them, but their files are about to be re-read.
    private var retrying: Set<Int64> = []

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Staging")

    init(directory: URL, manifestURL: URL?) {
        self.directory = directory
        self.manifestURL = manifestURL
        entries = manifestURL.flatMap { JSONFileStore.load([Entry].self, from: $0) } ?? []
    }

    var trackedEntries: [Entry] { entries }

    func register(paths: [String], chatID: Int64, messageID: Int64) {
        entries.append(Entry(chatID: chatID, messageID: messageID, paths: paths))
        save()
    }

    /// A temporary message got its final id. Sent messages release their files; failed ones keep them.
    func messageReplaced(chatID: Int64, oldMessageID: Int64, newMessageID: Int64, sent: Bool) {
        guard let index = entries.firstIndex(where: { $0.chatID == chatID && $0.messageID == oldMessageID }) else { return }
        if sent {
            remove(at: index)
        } else {
            entries[index].messageID = newMessageID
            save()
        }
    }

    func beginRetry(chatID: Int64, messageID: Int64) {
        retrying.insert(messageID)
    }

    /// The resent message replaced `oldMessageID` (nil when the resend request failed).
    func finishRetry(chatID: Int64, oldMessageID: Int64, newMessageID: Int64?) {
        retrying.remove(oldMessageID)
        guard let newMessageID, let index = entries.firstIndex(where: { $0.chatID == chatID && $0.messageID == oldMessageID }) else { return }
        entries[index].messageID = newMessageID
        save()
    }

    func messagesDeleted(chatID: Int64, messageIDs: [Int64]) {
        let ids = Set(messageIDs).subtracting(retrying)
        for index in entries.indices.reversed() where entries[index].chatID == chatID && ids.contains(entries[index].messageID) {
            remove(at: index)
        }
    }

    /// Deletes files that were staged but never sent (removed from the tray, or a send that failed to submit).
    func discard(_ paths: [String]) {
        let tracked = Set(entries.flatMap(\.paths))
        for path in paths where !tracked.contains(path) { deleteFile(path) }
    }

    /// After launch: keep files only for messages TDLib still reports as pending or failed, and
    /// remove untracked leftovers.
    func reconcile(session: TelegramSession) async {
        for entry in entries {
            let message = try? await session.send(GetMessage(chatID: entry.chatID, messageID: entry.messageID))
            if message?.sendingState == nil, let index = entries.firstIndex(of: entry) {
                remove(at: index)
            }
        }
        let tracked = Set(entries.flatMap { $0.paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path } })
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !tracked.contains(folder.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func remove(at index: Int) {
        let entry = entries.remove(at: index)
        let stillUsed = Set(entries.flatMap(\.paths))
        for path in entry.paths where !stillUsed.contains(path) { deleteFile(path) }
        save()
    }

    /// Removes a staged file and its per-attachment folder once empty.
    private func deleteFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if folder.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path),
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func save() {
        guard let manifestURL else { return }
        do {
            try JSONFileStore.save(entries, to: manifestURL)
        } catch {
            Self.logger.error("Saving staging manifest failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
