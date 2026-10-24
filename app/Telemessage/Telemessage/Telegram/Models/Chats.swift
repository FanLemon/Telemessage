import Foundation

nonisolated struct Chat: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    let type: ChatType
    var title: String
    var photo: ChatPhotoInfo?
    var accentColorID: Int32
    var permissions: ChatPermissions
    var lastMessage: Message?
    var positions: [ChatPosition]
    var unreadCount: Int32
    var lastReadInboxMessageID: Int64
    var lastReadOutboxMessageID: Int64
    var notificationSettings: ChatNotificationSettings

    func position(in list: ChatList) -> ChatPosition? {
        positions.first { $0.list == list }
    }

    /// Applies `updateChatPosition` semantics: order 0 removes the chat from that list.
    mutating func setPosition(_ position: ChatPosition) {
        positions.removeAll { $0.list == position.list }
        if position.order.value != 0 { positions.append(position) }
    }
}

nonisolated enum ChatType: Decodable, Sendable, Equatable {
    case `private`(userID: Int64)
    case basicGroup(basicGroupID: Int64)
    case supergroup(supergroupID: Int64, isChannel: Bool)
    case secret(secretChatID: Int32, userID: Int64)
    case unknown(String)

    private struct Private: Decodable { let userID: Int64 }
    private struct Basic: Decodable { let basicGroupID: Int64 }
    private struct Super: Decodable { let supergroupID: Int64; let isChannel: Bool }
    private struct Secret: Decodable { let secretChatID: Int32; let userID: Int64 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "chatTypePrivate":
            self = .private(userID: try Private(from: decoder).userID)
        case "chatTypeBasicGroup":
            self = .basicGroup(basicGroupID: try Basic(from: decoder).basicGroupID)
        case "chatTypeSupergroup":
            let value = try Super(from: decoder)
            self = .supergroup(supergroupID: value.supergroupID, isChannel: value.isChannel)
        case "chatTypeSecret":
            let value = try Secret(from: decoder)
            self = .secret(secretChatID: value.secretChatID, userID: value.userID)
        case let other:
            self = .unknown(other)
        }
    }
}

nonisolated enum ChatList: Codable, Sendable, Hashable {
    case main
    case archive
    case folder(Int32)
    case unknown(String)

    private struct Folder: Codable { let chatFolderID: Int32 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "chatListMain": self = .main
        case "chatListArchive": self = .archive
        case "chatListFolder": self = .folder(try Folder(from: decoder).chatFolderID)
        case let other: self = .unknown(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .main: try TDTyped("chatListMain").encode(to: encoder)
        case .archive: try TDTyped("chatListArchive").encode(to: encoder)
        case .folder(let id): try TDTyped("chatListFolder", Folder(chatFolderID: id)).encode(to: encoder)
        case .unknown(let type): try TDTyped(type).encode(to: encoder)
        }
    }
}

nonisolated struct ChatPosition: Decodable, Sendable, Equatable {
    let list: ChatList
    /// Descending sort key within `list`; 0 means the chat is not in the list.
    let order: TDInt64
    let isPinned: Bool
}

nonisolated struct ChatPhotoInfo: Decodable, Sendable, Equatable {
    let small: TDFile
    let big: TDFile
    let minithumbnail: Minithumbnail?
}

nonisolated struct ChatNotificationSettings: Decodable, Sendable, Equatable {
    let useDefaultMuteFor: Bool
    /// Seconds until unmuted; meaningful when `useDefaultMuteFor` is false.
    let muteFor: Int32
    let useDefaultShowPreview: Bool
    let showPreview: Bool
}

nonisolated struct Chats: Decodable, Sendable {
    let totalCount: Int32
    let chatIDs: [Int64]
}

nonisolated struct Users: Decodable, Sendable {
    let totalCount: Int32
    let userIDs: [Int64]
}
