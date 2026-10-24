import Foundation

nonisolated struct User: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    var firstName: String
    var lastName: String
    var usernames: Usernames?
    var phoneNumber: String
    var status: UserStatus
    var profilePhoto: ProfilePhoto?
    var accentColorID: Int32
    var isContact: Bool
    var isMutualContact: Bool
    var type: UserType

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

nonisolated struct Usernames: Decodable, Sendable, Equatable {
    let activeUsernames: [String]
    let editableUsername: String
}

nonisolated struct ProfilePhoto: Decodable, Sendable, Equatable {
    let id: TDInt64
    let small: TDFile
    let big: TDFile
    let minithumbnail: Minithumbnail?
}

nonisolated enum UserStatus: Decodable, Sendable, Equatable {
    case empty
    case online(expires: Int32)
    case offline(wasOnline: Int32)
    case recently
    case lastWeek
    case lastMonth
    case unknown(String)

    private struct Online: Decodable { let expires: Int32 }
    private struct Offline: Decodable { let wasOnline: Int32 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "userStatusEmpty": self = .empty
        case "userStatusOnline": self = .online(expires: try Online(from: decoder).expires)
        case "userStatusOffline": self = .offline(wasOnline: try Offline(from: decoder).wasOnline)
        case "userStatusRecently": self = .recently
        case "userStatusLastWeek": self = .lastWeek
        case "userStatusLastMonth": self = .lastMonth
        case let other: self = .unknown(other)
        }
    }
}

nonisolated enum UserType: Decodable, Sendable, Equatable {
    case regular
    case deleted
    case bot
    case unknown(String)

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "userTypeRegular": self = .regular
        case "userTypeDeleted": self = .deleted
        case "userTypeBot": self = .bot
        case let other: self = .unknown(other)
        }
    }
}

nonisolated struct BasicGroup: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    var memberCount: Int32
    var status: ChatMemberStatus
    var isActive: Bool
    /// Non-zero once the group has migrated to a supergroup.
    var upgradedToSupergroupID: Int64
}

nonisolated struct Supergroup: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    var memberCount: Int32
    var status: ChatMemberStatus
    var isChannel: Bool
    var isForum: Bool
}

/// The current user's membership in a group.
nonisolated enum ChatMemberStatus: Decodable, Sendable, Equatable {
    case creator(isMember: Bool)
    case administrator
    case member
    case restricted(isMember: Bool, permissions: ChatPermissions)
    case left
    case banned
    case unknown(String)

    private struct Creator: Decodable { let isMember: Bool }
    private struct Restricted: Decodable { let isMember: Bool; let permissions: ChatPermissions }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "chatMemberStatusCreator": self = .creator(isMember: try Creator(from: decoder).isMember)
        case "chatMemberStatusAdministrator": self = .administrator
        case "chatMemberStatusMember": self = .member
        case "chatMemberStatusRestricted":
            let value = try Restricted(from: decoder)
            self = .restricted(isMember: value.isMember, permissions: value.permissions)
        case "chatMemberStatusLeft": self = .left
        case "chatMemberStatusBanned": self = .banned
        case let other: self = .unknown(other)
        }
    }
}

nonisolated struct ChatPermissions: Decodable, Sendable, Equatable {
    let canSendBasicMessages: Bool
    let canSendPhotos: Bool
    let canSendVideos: Bool
    let canSendDocuments: Bool
    let canSendAudios: Bool
    let canSendOtherMessages: Bool

    static let all = ChatPermissions(canSendBasicMessages: true, canSendPhotos: true, canSendVideos: true,
                                     canSendDocuments: true, canSendAudios: true, canSendOtherMessages: true)
}
