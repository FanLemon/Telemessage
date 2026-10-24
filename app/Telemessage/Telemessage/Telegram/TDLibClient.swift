import Foundation
import os
import Synchronization

/// Raw JSON channel to one TDLib instance. `receive` is only ever called from the client's receive thread.
nonisolated protocol TDTransport: Sendable {
    func send(_ request: String)
    /// Blocks for up to `timeout` seconds; nil when nothing arrived.
    func receive(timeout: Double) -> String?
}

nonisolated enum TDClientError: Error, Equatable {
    /// The client closed before (or while) the request was answered.
    case closed
}

/// Typed async front end for a TDLib instance.
///
/// A dedicated thread blocks in `receive` and decodes each event. Responses and updates go into one
/// ordered stream; `run` consumes it on the main actor, applying updates and resuming requests in
/// arrival order. So when `send` returns, every update TDLib emitted before the response is applied.
nonisolated final class TDLibClient: Sendable {
    enum Event: Sendable {
        case response(extra: Int, data: Data)
        case update(Update)
    }

    private struct State {
        var nextExtra = 1
        var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
        var isClosed = false
    }

    private let transport: any TDTransport
    /// Called (on the receive thread) with the `@type` and error of every event that failed to decode.
    private let onDecodeFailure: (@Sendable (String, String) -> Void)?
    private let state = Mutex(State())
    private let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "TDLib")

    init(transport: any TDTransport, onDecodeFailure: (@Sendable (String, String) -> Void)? = nil) {
        self.transport = transport
        self.onDecodeFailure = onDecodeFailure
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    /// Starts the blocking receive thread. Call once.
    func startReceiving() {
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "TDLib receive"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Consumes events in order until the client closes. Call once, from a single task.
    @MainActor
    func run(handleUpdate: (Update) -> Void) async {
        for await event in events {
            switch event {
            case .response(let extra, let data):
                complete(extra: extra, data: data)
            case .update(let update):
                handleUpdate(update)
                if case .authorizationState(.closed) = update { shutdown() }
            }
        }
    }

    func send<R: TDRequest>(_ request: R) async throws -> R.Response {
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let extra: Int? = state.withLock { state in
                guard !state.isClosed else { return nil }
                let extra = state.nextExtra
                state.nextExtra += 1
                state.pending[extra] = continuation
                return extra
            }
            guard let extra else {
                continuation.resume(throwing: TDClientError.closed)
                return
            }
            do {
                let json = try TDCoding.encoder.encode(Envelope(request: request, extra: extra))
                transport.send(String(decoding: json, as: UTF8.self))
            } catch {
                state.withLock { $0.pending.removeValue(forKey: extra) }?.resume(throwing: error)
            }
        }
        if try TDCoding.decoder.decode(Header.self, from: data).type == "error" {
            throw try TDCoding.decoder.decode(TDError.self, from: data)
        }
        return try TDCoding.decoder.decode(R.Response.self, from: data)
    }

    /// Fails every pending request exactly once and stops receiving. Called automatically on
    /// `authorizationStateClosed`; afterwards `send` throws `TDClientError.closed`.
    func shutdown() {
        let pending = state.withLock { state in
            state.isClosed = true
            defer { state.pending = [:] }
            return state.pending
        }
        for continuation in pending.values {
            continuation.resume(throwing: TDClientError.closed)
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        while !state.withLock({ $0.isClosed }) {
            guard let json = transport.receive(timeout: 1.0) else { continue }
            if let event = Self.decodeEvent(Data(json.utf8), onFailure: onDecodeFailure) {
                eventSink.yield(event)
            }
        }
        eventSink.finish()
    }

    static func decodeEvent(_ data: Data, onFailure: (@Sendable (String, String) -> Void)? = nil) -> Event? {
        let header: Header
        do {
            header = try TDCoding.decoder.decode(Header.self, from: data)
        } catch {
            logger.error("Unreadable TDLib event: \(error, privacy: .public)")
            onFailure?("?", "\(error)")
            return nil
        }
        if let extra = header.extra {
            return .response(extra: extra, data: data)
        }
        do {
            return .update(try TDCoding.decoder.decode(Update.self, from: data))
        } catch {
            // A modeled update failed to decode: the model disagrees with the pinned schema.
            logger.fault("Failed to decode \(header.type, privacy: .public): \(error, privacy: .public)")
            onFailure?(header.type, "\(error)")
            return nil
        }
    }

    private func complete(extra: Int, data: Data) {
        // Responses for requests failed by shutdown() are dropped here.
        state.withLock { $0.pending.removeValue(forKey: extra) }?.resume(returning: data)
    }

    private struct Header: Decodable {
        let type: String
        let extra: Int?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case extra = "@extra"
        }
    }

    private struct Envelope<Request: TDRequest>: Encodable {
        let request: Request
        let extra: Int

        func encode(to encoder: any Encoder) throws {
            try request.encode(to: encoder)
            var container = encoder.container(keyedBy: Header.CodingKeys.self)
            try container.encode(Request.type, forKey: .type)
            try container.encode(extra, forKey: .extra)
        }
    }
}
