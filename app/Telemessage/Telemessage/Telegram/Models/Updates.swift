import Foundation

/// Updates the app reduces. Everything else decodes as `.unknown` and is ignored.
nonisolated enum Update: Decodable, Sendable, Equatable {
    case authorizationState(AuthorizationState)
    case connectionState(ConnectionState)
    case option(name: String, value: OptionValue)

    case user(User)
    case userStatus(userID: Int64, status: UserStatus)
    case basicGroup(BasicGroup)
    case supergroup(Supergroup)

    case newChat(Chat)
    case chatTitle(chatID: Int64, title: String)
    case chatPhoto(chatID: Int64, photo: ChatPhotoInfo?)
    case chatLastMessage(chatID: Int64, lastMessage: Message?, positions: [ChatPosition])
    case chatPosition(chatID: Int64, position: ChatPosition)
    case chatReadInbox(chatID: Int64, lastReadInboxMessageID: Int64, unreadCount: Int32)
    case chatReadOutbox(chatID: Int64, lastReadOutboxMessageID: Int64)
    case chatNotificationSettings(chatID: Int64, settings: ChatNotificationSettings)
    case chatPermissions(chatID: Int64, permissions: ChatPermissions)

    case newMessage(Message)
    case messageSendSucceeded(Message, oldMessageID: Int64)
    case messageSendFailed(Message, oldMessageID: Int64, error: TDError)
    case messageContent(chatID: Int64, messageID: Int64, content: MessageContent)
    case messageEdited(chatID: Int64, messageID: Int64, editDate: Int32)
    /// `fromCache` deletions only evict TDLib's cache; the messages still exist.
    case deleteMessages(chatID: Int64, messageIDs: [Int64], isPermanent: Bool, fromCache: Bool)

    case file(TDFile)

    case unknown(String)

    private struct AuthorizationStatePayload: Decodable { let authorizationState: AuthorizationState }
    private struct ConnectionStatePayload: Decodable { let state: ConnectionState }
    private struct OptionPayload: Decodable { let name: String; let value: OptionValue }
    private struct UserPayload: Decodable { let user: User }
    private struct UserStatusPayload: Decodable { let userID: Int64; let status: UserStatus }
    private struct BasicGroupPayload: Decodable { let basicGroup: BasicGroup }
    private struct SupergroupPayload: Decodable { let supergroup: Supergroup }
    private struct NewChatPayload: Decodable { let chat: Chat }
    private struct ChatTitlePayload: Decodable { let chatID: Int64; let title: String }
    private struct ChatPhotoPayload: Decodable { let chatID: Int64; let photo: ChatPhotoInfo? }
    private struct ChatLastMessagePayload: Decodable {
        let chatID: Int64; let lastMessage: Message?; let positions: [ChatPosition]
    }
    private struct ChatPositionPayload: Decodable { let chatID: Int64; let position: ChatPosition }
    private struct ChatReadInboxPayload: Decodable {
        let chatID: Int64; let lastReadInboxMessageID: Int64; let unreadCount: Int32
    }
    private struct ChatReadOutboxPayload: Decodable { let chatID: Int64; let lastReadOutboxMessageID: Int64 }
    private struct ChatNotificationSettingsPayload: Decodable {
        let chatID: Int64; let notificationSettings: ChatNotificationSettings
    }
    private struct ChatPermissionsPayload: Decodable { let chatID: Int64; let permissions: ChatPermissions }
    private struct NewMessagePayload: Decodable { let message: Message }
    private struct SendSucceededPayload: Decodable { let message: Message; let oldMessageID: Int64 }
    private struct SendFailedPayload: Decodable { let message: Message; let oldMessageID: Int64; let error: TDError }
    private struct MessageContentPayload: Decodable { let chatID: Int64; let messageID: Int64; let newContent: MessageContent }
    private struct MessageEditedPayload: Decodable { let chatID: Int64; let messageID: Int64; let editDate: Int32 }
    private struct DeleteMessagesPayload: Decodable {
        let chatID: Int64; let messageIDs: [Int64]; let isPermanent: Bool; let fromCache: Bool
    }
    private struct FilePayload: Decodable { let file: TDFile }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "updateAuthorizationState":
            self = .authorizationState(try AuthorizationStatePayload(from: decoder).authorizationState)
        case "updateConnectionState":
            self = .connectionState(try ConnectionStatePayload(from: decoder).state)
        case "updateOption":
            let value = try OptionPayload(from: decoder)
            self = .option(name: value.name, value: value.value)
        case "updateUser":
            self = .user(try UserPayload(from: decoder).user)
        case "updateUserStatus":
            let value = try UserStatusPayload(from: decoder)
            self = .userStatus(userID: value.userID, status: value.status)
        case "updateBasicGroup":
            self = .basicGroup(try BasicGroupPayload(from: decoder).basicGroup)
        case "updateSupergroup":
            self = .supergroup(try SupergroupPayload(from: decoder).supergroup)
        case "updateNewChat":
            self = .newChat(try NewChatPayload(from: decoder).chat)
        case "updateChatTitle":
            let value = try ChatTitlePayload(from: decoder)
            self = .chatTitle(chatID: value.chatID, title: value.title)
        case "updateChatPhoto":
            let value = try ChatPhotoPayload(from: decoder)
            self = .chatPhoto(chatID: value.chatID, photo: value.photo)
        case "updateChatLastMessage":
            let value = try ChatLastMessagePayload(from: decoder)
            self = .chatLastMessage(chatID: value.chatID, lastMessage: value.lastMessage, positions: value.positions)
        case "updateChatPosition":
            let value = try ChatPositionPayload(from: decoder)
            self = .chatPosition(chatID: value.chatID, position: value.position)
        case "updateChatReadInbox":
            let value = try ChatReadInboxPayload(from: decoder)
            self = .chatReadInbox(chatID: value.chatID, lastReadInboxMessageID: value.lastReadInboxMessageID,
                                  unreadCount: value.unreadCount)
        case "updateChatReadOutbox":
            let value = try ChatReadOutboxPayload(from: decoder)
            self = .chatReadOutbox(chatID: value.chatID, lastReadOutboxMessageID: value.lastReadOutboxMessageID)
        case "updateChatNotificationSettings":
            let value = try ChatNotificationSettingsPayload(from: decoder)
            self = .chatNotificationSettings(chatID: value.chatID, settings: value.notificationSettings)
        case "updateChatPermissions":
            let value = try ChatPermissionsPayload(from: decoder)
            self = .chatPermissions(chatID: value.chatID, permissions: value.permissions)
        case "updateNewMessage":
            self = .newMessage(try NewMessagePayload(from: decoder).message)
        case "updateMessageSendSucceeded":
            let value = try SendSucceededPayload(from: decoder)
            self = .messageSendSucceeded(value.message, oldMessageID: value.oldMessageID)
        case "updateMessageSendFailed":
            let value = try SendFailedPayload(from: decoder)
            self = .messageSendFailed(value.message, oldMessageID: value.oldMessageID, error: value.error)
        case "updateMessageContent":
            let value = try MessageContentPayload(from: decoder)
            self = .messageContent(chatID: value.chatID, messageID: value.messageID, content: value.newContent)
        case "updateMessageEdited":
            let value = try MessageEditedPayload(from: decoder)
            self = .messageEdited(chatID: value.chatID, messageID: value.messageID, editDate: value.editDate)
        case "updateDeleteMessages":
            let value = try DeleteMessagesPayload(from: decoder)
            self = .deleteMessages(chatID: value.chatID, messageIDs: value.messageIDs,
                                   isPermanent: value.isPermanent, fromCache: value.fromCache)
        case "updateFile":
            self = .file(try FilePayload(from: decoder).file)
        case let other:
            self = .unknown(other)
        }
    }
}
