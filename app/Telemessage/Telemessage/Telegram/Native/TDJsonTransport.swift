import CTDJson

/// The real TDLib instance behind the td_json_client C interface.
///
/// td_receive is process-wide (it returns events for every client id), so the app runs exactly one
/// TDLib instance at a time with one receive thread.
nonisolated final class TDJsonTransport: TDTransport {
    private let clientID = td_create_client_id()

    func send(_ request: String) {
        td_send(clientID, request)
    }

    func receive(timeout: Double) -> String? {
        // The returned buffer is only valid until the next td_receive call, so copy it immediately.
        td_receive(timeout).map { String(cString: $0) }
    }
}
