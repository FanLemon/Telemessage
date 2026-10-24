import Foundation
import os

/// One running TDLib instance plus the store it feeds. A logout or close ends the session; the app
/// creates a new session (with a new client) to sign in again.
@MainActor
final class TelegramSession {
    struct Configuration: Sendable {
        let secrets: TelegramSecrets
        /// Account-specific root; TDLib keeps `db/` and `files/` beneath it.
        let dataDirectory: URL
        let databaseKey: Data
        let applicationVersion: String
    }

    let store = TelegramStore()
    private let client: TDLibClient
    private let configuration: Configuration
    private var runTask: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateHandlers: [UUID: (Update) -> Void] = [:]

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Session")

    init(transport: any TDTransport, configuration: Configuration,
         onDecodeFailure: (@Sendable (String, String) -> Void)? = nil) {
        client = TDLibClient(transport: transport, onDecodeFailure: onDecodeFailure)
        self.configuration = configuration
    }

    var isClosed: Bool { store.authorizationState == .closed }

    func start() {
        guard runTask == nil else { return }
        client.startReceiving()
        runTask = Task { [client] in
            await client.run { [weak self] update in self?.handle(update) }
        }
        // TDLib emits nothing until it receives its first request.
        Task { [client] in
            if case .string(let version) = try? await client.send(GetOption(name: "version")) {
                Self.logger.info("TDLib \(version, privacy: .public) started")
            }
        }
    }

    func send<Request: TDRequest>(_ request: Request) async throws -> Request.Response {
        try await client.send(request)
    }

    /// Fire-and-forget for requests whose result only matters through updates (openChat, viewMessages, …).
    func post<Request: TDRequest>(_ request: Request) {
        Task { [client] in
            do {
                _ = try await client.send(request)
            } catch {
                Self.logger.error("\(Request.type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Raw updates, delivered after the store has applied them. For coordinators that react to
    /// events the store does not keep (e.g. new messages in chats without an open window).
    func observeUpdates(_ handler: @escaping (Update) -> Void) -> StoreObservation {
        let id = UUID()
        updateHandlers[id] = handler
        return StoreObservation { [weak self] in self?.updateHandlers[id] = nil }
    }

    /// Closes TDLib without logging out and waits for authorizationStateClosed.
    func close() async {
        guard runTask != nil, !isClosed else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            Task { [client] in _ = try? await client.send(Close()) }
        }
    }

    private func handle(_ update: Update) {
        store.apply(update)
        for handler in updateHandlers.values { handler(update) }
        guard case .authorizationState(let state) = update else { return }
        // Log only the case name: associated values can contain the phone number.
        let name = Mirror(reflecting: state).children.first?.label ?? String(describing: state)
        Self.logger.info("Authorization state: \(name, privacy: .public)")
        switch state {
        case .waitTdlibParameters:
            Task { await sendParameters() }
        case .closed:
            let waiters = closeWaiters
            closeWaiters = []
            for waiter in waiters { waiter.resume() }
        default:
            break
        }
    }

    private func sendParameters() async {
        let directory = configuration.dataDirectory
        let parameters = SetTdlibParameters(
            databaseDirectory: directory.appending(path: "db", directoryHint: .isDirectory).path(percentEncoded: false),
            filesDirectory: directory.appending(path: "files", directoryHint: .isDirectory).path(percentEncoded: false),
            databaseEncryptionKey: configuration.databaseKey.base64EncodedString(),
            apiID: configuration.secrets.apiID,
            apiHash: configuration.secrets.apiHash,
            systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
            deviceModel: "Mac",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            applicationVersion: configuration.applicationVersion
        )
        do {
            _ = try await client.send(parameters)
        } catch {
            Self.logger.error("setTdlibParameters failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
