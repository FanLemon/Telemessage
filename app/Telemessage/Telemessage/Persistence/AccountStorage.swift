import Foundation

/// On-disk layout for one Telegram account inside the app container.
///
/// ```
/// Application Support/Accounts/<name>/
///   db/, files/        TDLib database and downloaded files
///   App/               selection, window state, drafts (owned by the app)
///   Staging/           copies of outgoing attachments until TDLib no longer needs them
/// ```
nonisolated struct AccountStorage: Sendable {
    let name: String
    let root: URL

    init(name: String = "primary", base: URL = .applicationSupportDirectory) {
        self.name = name
        root = base.appending(path: "Accounts/\(name)", directoryHint: .isDirectory)
    }

    var appDirectory: URL { root.appending(path: "App", directoryHint: .isDirectory) }
    var stagingDirectory: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }

    func appFile(_ name: String) -> URL { appDirectory.appending(path: name) }

    /// Keychain account of the key that encrypts drafts.
    var draftsKeyName: String { "\(name).drafts" }

    /// Creates `directory` if needed and returns it.
    @discardableResult
    func ensure(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes everything stored for the account, including its database key. Only call after
    /// TDLib reported authorizationStateClosed.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? DatabaseKeyStore.delete(for: name)
        try? DatabaseKeyStore.delete(for: draftsKeyName)
    }
}

/// Small JSON documents in the account's App directory, written atomically.
nonisolated enum JSONFileStore {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
