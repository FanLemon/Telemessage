import Foundation

/// A TDLib function. Stored properties are its arguments; `nil` optionals are omitted, which TDLib reads as null.
nonisolated protocol TDRequest: Encodable, Sendable {
    associatedtype Response: Decodable & Sendable
    static var type: String { get }
}

// MARK: - Authorization

nonisolated struct SetTdlibParameters: TDRequest {
    typealias Response = TDOk
    static let type = "setTdlibParameters"

    var useTestDc = false
    let databaseDirectory: String
    let filesDirectory: String
    /// Base64-encoded key; TDLib's `bytes` type.
    let databaseEncryptionKey: String
    var useFileDatabase = true
    var useChatInfoDatabase = true
    var useMessageDatabase = true
    var useSecretChats = false
    let apiID: Int
    let apiHash: String
    let systemLanguageCode: String
    let deviceModel: String
    let systemVersion: String
    let applicationVersion: String
}

nonisolated struct SetAuthenticationPhoneNumber: TDRequest {
    typealias Response = TDOk
    static let type = "setAuthenticationPhoneNumber"
    let phoneNumber: String
}

nonisolated struct CheckAuthenticationCode: TDRequest {
    typealias Response = TDOk
    static let type = "checkAuthenticationCode"
    let code: String
}

nonisolated struct ResendAuthenticationCode: TDRequest {
    typealias Response = TDOk
    static let type = "resendAuthenticationCode"
    var reason = TDTyped("resendCodeReasonUserRequest")
}

nonisolated struct CheckAuthenticationPassword: TDRequest {
    typealias Response = TDOk
    static let type = "checkAuthenticationPassword"
    let password: String
}

nonisolated struct SetAuthenticationEmailAddress: TDRequest {
    typealias Response = TDOk
    static let type = "setAuthenticationEmailAddress"
    let emailAddress: String
}

nonisolated struct CheckAuthenticationEmailCode: TDRequest {
    typealias Response = TDOk
    static let type = "checkAuthenticationEmailCode"

    struct Code: Encodable, Sendable { let code: String }
    let code: TDTyped<Code>

    init(code: String) {
        self.code = TDTyped("emailAddressAuthenticationCode", Code(code: code))
    }
}

nonisolated struct RequestQrCodeAuthentication: TDRequest {
    typealias Response = TDOk
    static let type = "requestQrCodeAuthentication"
    var otherUserIDs: [Int64] = []
}

nonisolated struct LogOut: TDRequest {
    typealias Response = TDOk
    static let type = "logOut"
}

nonisolated struct Close: TDRequest {
    typealias Response = TDOk
    static let type = "close"
}

// MARK: - Users and chats

nonisolated struct GetOption: TDRequest {
    typealias Response = OptionValue
    static let type = "getOption"
    let name: String
}

nonisolated struct SetOption: TDRequest {
    typealias Response = TDOk
    static let type = "setOption"

    enum Value: Encodable, Sendable {
        case boolean(Bool)

        private struct BooleanValue: Encodable, Sendable { let value: Bool }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .boolean(let value): try TDTyped("optionValueBoolean", BooleanValue(value: value)).encode(to: encoder)
            }
        }
    }

    let name: String
    let value: Value
}

nonisolated struct GetMe: TDRequest {
    typealias Response = User
    static let type = "getMe"
}

nonisolated struct GetUser: TDRequest {
    typealias Response = User
    static let type = "getUser"
    let userID: Int64
}

nonisolated struct GetContacts: TDRequest {
    typealias Response = Users
    static let type = "getContacts"
}

nonisolated struct GetChat: TDRequest {
    typealias Response = Chat
    static let type = "getChat"
    let chatID: Int64
}

/// Loads more chats into `chatList`; they arrive as updateNewChat/updateChatPosition.
/// Fails with code 404 once the whole list is loaded.
nonisolated struct LoadChats: TDRequest {
    typealias Response = TDOk
    static let type = "loadChats"
    let chatList: ChatList
    let limit: Int32
}

nonisolated struct GetChats: TDRequest {
    typealias Response = Chats
    static let type = "getChats"
    let chatList: ChatList
    let limit: Int32
}

nonisolated struct CreatePrivateChat: TDRequest {
    typealias Response = Chat
    static let type = "createPrivateChat"
    let userID: Int64
    var force = false
}

nonisolated struct CreateSupergroupChat: TDRequest {
    typealias Response = Chat
    static let type = "createSupergroupChat"
    let supergroupID: Int64
    var force = false
}

nonisolated struct GetBasicGroup: TDRequest {
    typealias Response = BasicGroup
    static let type = "getBasicGroup"
    let basicGroupID: Int64
}

/// Tells TDLib how the Mac is connected, so it reconnects promptly after network changes.
nonisolated struct SetNetworkType: TDRequest {
    typealias Response = TDOk
    static let type = "setNetworkType"
    let type: TDTyped<TDEmpty>

    init(_ name: String) { type = TDTyped(name) }

    static let none = SetNetworkType("networkTypeNone")
    static let wifi = SetNetworkType("networkTypeWiFi")
    static let other = SetNetworkType("networkTypeOther")
}

// MARK: - Messages

nonisolated struct GetMessage: TDRequest {
    typealias Response = Message
    static let type = "getMessage"
    let chatID: Int64
    let messageID: Int64
}

/// Retries messages that failed to send; only valid for messages in the failed state.
nonisolated struct ResendMessages: TDRequest {
    typealias Response = Messages
    static let type = "resendMessages"
    let chatID: Int64
    let messageIDs: [Int64]
}

nonisolated struct DeleteMessages: TDRequest {
    typealias Response = TDOk
    static let type = "deleteMessages"
    let chatID: Int64
    let messageIDs: [Int64]
    let revoke: Bool
}

/// Returns messages newest first, starting at `fromMessageID` (0 = newest). May return fewer than `limit`.
nonisolated struct GetChatHistory: TDRequest {
    typealias Response = Messages
    static let type = "getChatHistory"
    let chatID: Int64
    let fromMessageID: Int64
    var offset: Int32 = 0
    let limit: Int32
    var onlyLocal = false
}

nonisolated struct OpenChat: TDRequest {
    typealias Response = TDOk
    static let type = "openChat"
    let chatID: Int64
}

nonisolated struct CloseChat: TDRequest {
    typealias Response = TDOk
    static let type = "closeChat"
    let chatID: Int64
}

/// Reports messages as shown; marks them read only while the chat is open.
nonisolated struct ViewMessages: TDRequest {
    typealias Response = TDOk
    static let type = "viewMessages"
    let chatID: Int64
    let messageIDs: [Int64]
    var source = TDTyped("messageSourceChatHistory")
    var forceRead = false
}

/// Message content to send. Files are referenced by local path and uploaded by TDLib.
nonisolated enum InputMessageContent: Encodable, Sendable, Equatable {
    case text(FormattedText)
    case photo(path: String, thumbnail: InputThumbnail?, width: Int32, height: Int32, caption: FormattedText)
    case video(path: String, thumbnail: InputThumbnail?, duration: Int32, width: Int32, height: Int32, caption: FormattedText)
    case document(path: String, thumbnail: InputThumbnail?, caption: FormattedText)

    nonisolated struct InputThumbnail: Encodable, Sendable, Equatable {
        let path: String
        let width: Int32
        let height: Int32

        private enum CodingKeys: String, CodingKey { case type = "@type", thumbnail, width, height }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("inputThumbnail", forKey: .type)
            try container.encode(InputMessageContent.localFile(path), forKey: .thumbnail)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }

    private struct LocalFile: Encodable, Sendable { let path: String }
    private struct Text: Encodable, Sendable { let text: FormattedText; var clearDraft = true }
    private struct Photo: Encodable, Sendable {
        let photo: TDTyped<PhotoFile>
        let caption: FormattedText
    }
    private struct PhotoFile: Encodable, Sendable {
        let photo: TDTyped<LocalFile>
        let thumbnail: InputThumbnail?
        let width: Int32
        let height: Int32
    }
    private struct Video: Encodable, Sendable {
        let video: TDTyped<VideoFile>
        let caption: FormattedText
    }
    private struct VideoFile: Encodable, Sendable {
        let video: TDTyped<LocalFile>
        let thumbnail: InputThumbnail?
        let duration: Int32
        let width: Int32
        let height: Int32
        var supportsStreaming = true
    }
    private struct Document: Encodable, Sendable {
        let document: TDTyped<DocumentFile>
        let caption: FormattedText
    }
    private struct DocumentFile: Encodable, Sendable {
        let document: TDTyped<LocalFile>
        let thumbnail: InputThumbnail?
        var disableContentTypeDetection = false
    }

    private static func localFile(_ path: String) -> TDTyped<LocalFile> { TDTyped("inputFileLocal", LocalFile(path: path)) }

    var caption: FormattedText {
        switch self {
        case .text(let text): text
        case .photo(_, _, _, _, let caption), .video(_, _, _, _, _, let caption), .document(_, _, let caption): caption
        }
    }

    /// A copy with `caption` (not applicable to text).
    func withCaption(_ caption: FormattedText) -> InputMessageContent {
        switch self {
        case .text: self
        case .photo(let path, let thumbnail, let width, let height, _): .photo(path: path, thumbnail: thumbnail, width: width, height: height, caption: caption)
        case .video(let path, let thumbnail, let duration, let width, let height, _):
            .video(path: path, thumbnail: thumbnail, duration: duration, width: width, height: height, caption: caption)
        case .document(let path, let thumbnail, _): .document(path: path, thumbnail: thumbnail, caption: caption)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let text):
            try TDTyped("inputMessageText", Text(text: text)).encode(to: encoder)
        case .photo(let path, let thumbnail, let width, let height, let caption):
            let file = PhotoFile(photo: Self.localFile(path), thumbnail: thumbnail, width: width, height: height)
            try TDTyped("inputMessagePhoto", Photo(photo: TDTyped("inputPhoto", file), caption: caption)).encode(to: encoder)
        case .video(let path, let thumbnail, let duration, let width, let height, let caption):
            let file = VideoFile(video: Self.localFile(path), thumbnail: thumbnail, duration: duration, width: width, height: height)
            try TDTyped("inputMessageVideo", Video(video: TDTyped("inputVideo", file), caption: caption)).encode(to: encoder)
        case .document(let path, let thumbnail, let caption):
            let file = DocumentFile(document: Self.localFile(path), thumbnail: thumbnail)
            try TDTyped("inputMessageDocument", Document(document: TDTyped("inputDocument", file), caption: caption)).encode(to: encoder)
        }
    }
}

nonisolated struct SendMessage: TDRequest {
    typealias Response = Message
    static let type = "sendMessage"

    struct ReplyToMessage: Encodable, Sendable { let messageID: Int64 }

    let chatID: Int64
    let replyTo: TDTyped<ReplyToMessage>?
    let inputMessageContent: InputMessageContent

    init(chatID: Int64, content: InputMessageContent, replyToMessageID: Int64? = nil) {
        self.chatID = chatID
        replyTo = replyToMessageID.map { TDTyped("inputMessageReplyToMessage", ReplyToMessage(messageID: $0)) }
        inputMessageContent = content
    }

    init(chatID: Int64, text: FormattedText, replyToMessageID: Int64? = nil) {
        self.init(chatID: chatID, content: .text(text), replyToMessageID: replyToMessageID)
    }
}

/// Sends 2–10 photos/videos (or 2–10 documents) as one album.
nonisolated struct SendMessageAlbum: TDRequest {
    typealias Response = Messages
    static let type = "sendMessageAlbum"

    let chatID: Int64
    let replyTo: TDTyped<SendMessage.ReplyToMessage>?
    let inputMessageContents: [InputMessageContent]

    init(chatID: Int64, contents: [InputMessageContent], replyToMessageID: Int64? = nil) {
        self.chatID = chatID
        replyTo = replyToMessageID.map { TDTyped("inputMessageReplyToMessage", SendMessage.ReplyToMessage(messageID: $0)) }
        inputMessageContents = contents
    }
}

// MARK: - Files

nonisolated struct CancelDownloadFile: TDRequest {
    typealias Response = TDOk
    static let type = "cancelDownloadFile"
    let fileID: Int32
    var onlyIfPending = false
}

nonisolated struct StorageStatisticsFast: Decodable, Sendable {
    let filesSize: Int64
    let fileCount: Int32
    let databaseSize: Int64
}

nonisolated struct GetStorageStatisticsFast: TDRequest {
    typealias Response = StorageStatisticsFast
    static let type = "getStorageStatisticsFast"
}

/// Deletes downloaded files (not the message database). `size: 0` removes all of them.
nonisolated struct OptimizeStorage: TDRequest {
    nonisolated struct Statistics: Decodable, Sendable {}
    typealias Response = Statistics
    static let type = "optimizeStorage"
    var size: Int64 = 0
    var ttl: Int32 = 0
    var count: Int32 = 0
    var immunityDelay: Int32 = 0
    var fileTypes: [TDTyped<TDEmpty>] = []
    var chatIDs: [Int64] = []
    var excludeChatIDs: [Int64] = []
    var returnDeletedFileStatistics = false
    var chatLimit: Int32 = 0
}

/// Starts or reprioritizes a download (priority 1–32); progress arrives as updateFile.
nonisolated struct DownloadFile: TDRequest {
    typealias Response = TDFile
    static let type = "downloadFile"
    let fileID: Int32
    let priority: Int32
    var offset: Int64 = 0
    var limit: Int64 = 0
    var synchronous = false
}
