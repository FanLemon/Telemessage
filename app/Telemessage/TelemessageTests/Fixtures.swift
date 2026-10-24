import Foundation
@testable import TelemessageCore

/// Synthetic TDLib JSON shaped like td_api.tl 1.8.69 output (no real account data).
nonisolated enum Fixture {
    static func file(id: Int32 = 7, completed: Bool = false, path: String = "") -> String {
        """
        {"@type":"file","id":\(id),"size":1024,"expected_size":1024,
         "local":{"@type":"localFile","path":"\(path)","can_be_downloaded":true,"can_be_deleted":false,
                  "is_downloading_active":false,"is_downloading_completed":\(completed),"download_offset":0,
                  "downloaded_prefix_size":0,"downloaded_size":\(completed ? 1024 : 0)},
         "remote":{"@type":"remoteFile","id":"AgAD","unique_id":"AQAD","is_uploading_active":false,
                   "is_uploading_completed":true,"uploaded_size":1024}}
        """
    }

    static func textContent(_ text: String) -> String {
        #"{"@type":"messageText","text":{"@type":"formattedText","text":"\#(text)","entities":[]}}"#
    }

    static func message(id: Int64, chatID: Int64 = 100, outgoing: Bool = false,
                        content: String? = nil, pending: Bool = false) -> String {
        """
        {"@type":"message","id":\(id),
         "sender_id":{"@type":"messageSenderUser","user_id":\(outgoing ? 1 : 2)},
         "chat_id":\(chatID),
         \(pending ? #""sending_state":{"@type":"messageSendingStatePending","sending_id":1},"# : "")
         "is_outgoing":\(outgoing),"is_pinned":false,"date":1761300000,"edit_date":0,
         "media_album_id":"0",
         "content":\(content ?? textContent("Message \(id)"))}
        """
    }

    static func chat(id: Int64 = 100, title: String = "Alex", order: Int64? = 5_000,
                     list: String = "chatListMain", unreadCount: Int32 = 0) -> String {
        let positions = order.map {
            #"[{"@type":"chatPosition","list":{"@type":"\#(list)"},"order":"\#($0)","is_pinned":false}]"#
        } ?? "[]"
        return """
        {"@type":"chat","id":\(id),"type":{"@type":"chatTypePrivate","user_id":2},"title":"\(title)",
         "accent_color_id":3,"positions":\(positions),"unread_count":\(unreadCount),
         "permissions":{"@type":"chatPermissions","can_send_basic_messages":true,"can_send_audios":true,
                        "can_send_documents":true,"can_send_photos":true,"can_send_videos":true,
                        "can_send_video_notes":true,"can_send_voice_notes":true,"can_send_polls":true,
                        "can_send_other_messages":true,"can_add_link_previews":true},
         "last_read_inbox_message_id":0,"last_read_outbox_message_id":0,
         "notification_settings":{"@type":"chatNotificationSettings","use_default_mute_for":true,"mute_for":0,
                                  "use_default_show_preview":true,"show_preview":false}}
        """
    }

    static func update(_ type: String, _ fields: String) -> String {
        #"{"@type":"\#(type)",\#(fields)}"#
    }

    static func decodeUpdate(_ json: String) throws -> Update {
        try TDCoding.decoder.decode(Update.self, from: Data(json.utf8))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TDCoding.decoder.decode(T.self, from: Data(json.utf8))
    }
}

/// In-memory TDLib stand-in: records requests and emits scripted events from a responder.
nonisolated final class MockTransport: TDTransport, @unchecked Sendable {
    typealias Responder = (_ request: [String: Any]) -> [String]

    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var queue: [String] = []
    private var sentRequests: [[String: Any]] = []
    private let responder: Responder

    init(responder: @escaping Responder = { _ in [] }) {
        self.responder = responder
    }

    var sent: [[String: Any]] {
        lock.withLock { sentRequests }
    }

    func send(_ request: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(request.utf8))) as? [String: Any] ?? [:]
        lock.withLock { sentRequests.append(object) }
        for event in responder(object) { push(event) }
    }

    func receive(timeout: Double) -> String? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { queue.removeFirst() }
    }

    func push(_ event: String) {
        lock.withLock { queue.append(event) }
        available.signal()
    }

    /// A response object echoing the request's `@extra`.
    static func reply(to request: [String: Any], _ json: String) -> String {
        let extra = request["@extra"] as? Int ?? -1
        var body = json.trimmingCharacters(in: .whitespacesAndNewlines)
        body.removeLast()
        return body + #","@extra":\#(extra)}"#
    }
}
