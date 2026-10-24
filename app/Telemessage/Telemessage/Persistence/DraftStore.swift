import CryptoKit
import Foundation
import os

/// Unsent composer text per chat, encrypted at rest with AES-GCM under a Keychain-held key.
final class DraftStore {
    private var drafts: [Int64: String] = [:]
    private let url: URL?
    private let key: SymmetricKey?
    private var pendingSave: DispatchWorkItem?

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Drafts")

    /// Without `url` and `keyData` drafts live in memory only.
    init(url: URL?, keyData: Data?) {
        self.url = url
        key = keyData.map { SymmetricKey(data: $0) }
        guard let url, let key, let sealed = try? Data(contentsOf: url) else { return }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
            let stored = try JSONDecoder().decode([String: String].self, from: plain)
            drafts = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int64(key).map { ($0, value) } })
        } catch {
            Self.logger.error("Drafts unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    func draft(for chatID: Int64) -> String { drafts[chatID] ?? "" }

    func setDraft(_ text: String, for chatID: Int64) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard drafts[chatID] != (trimmed.isEmpty ? nil : text) else { return }
        drafts[chatID] = trimmed.isEmpty ? nil : text
        scheduleSave()
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let url, let key else { return }
        do {
            let plain = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: drafts.map { (String($0.key), $0.value) }))
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Saving drafts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        guard url != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
