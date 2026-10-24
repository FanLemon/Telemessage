import Foundation

/// The single answer to "may this chat surface?" Every presentation path asks it: the chat list,
/// opening and restoring windows, notifications, the Dock badge and automatic media downloads.
struct SelectionPolicy {
    enum Eligibility: Equatable {
        case eligible
        case unsupported(String)
    }

    let selection: SelectionStore
    let store: TelegramStore

    func isSelected(_ chatID: Int64) -> Bool {
        selection.contains(chatID)
    }

    /// A picked chat that can currently be shown.
    func canPresent(_ chatID: Int64) -> Bool {
        guard isSelected(chatID), let chat = store.chats[chatID] else { return false }
        return eligibility(of: chat) == .eligible
    }

    func eligibility(of chat: Chat) -> Eligibility {
        switch chat.type {
        case .private(let userID):
            if store.users[userID]?.type == .deleted { return .unsupported("Deleted account") }
            return .eligible
        case .basicGroup(let groupID):
            guard let group = store.basicGroups[groupID] else { return .eligible }
            if group.upgradedToSupergroupID != 0 { return .unsupported("Upgraded to a supergroup") }
            return .eligible
        case .supergroup(let supergroupID, let isChannel):
            if isChannel { return .unsupported("Channels aren't supported") }
            if store.supergroups[supergroupID]?.isForum == true { return .unsupported("Forum groups aren't supported yet") }
            return .eligible
        case .secret:
            return .unsupported("Secret chats aren't supported")
        case .unknown:
            return .unsupported("Unsupported chat type")
        }
    }

    /// Whether the user may post text in `chat` (members, not left/banned/restricted).
    func canSendMessages(in chat: Chat) -> Bool {
        sendPermission(in: chat) { $0.canSendBasicMessages }
    }

    func canSendMedia(in chat: Chat) -> Bool {
        sendPermission(in: chat) { $0.canSendPhotos || $0.canSendVideos || $0.canSendDocuments }
    }

    private func sendPermission(in chat: Chat, _ allowed: (ChatPermissions) -> Bool) -> Bool {
        let status: ChatMemberStatus
        switch chat.type {
        case .private(let userID):
            return store.users[userID]?.type != .deleted
        case .basicGroup(let groupID):
            guard let group = store.basicGroups[groupID] else { return true }
            guard group.isActive, group.upgradedToSupergroupID == 0 else { return false }
            status = group.status
        case .supergroup(let supergroupID, _):
            guard let group = store.supergroups[supergroupID] else { return true }
            status = group.status
        case .secret, .unknown:
            return false
        }
        switch status {
        case .creator(let isMember): return isMember
        case .administrator: return true
        case .member: return allowed(chat.permissions)
        case .restricted(let isMember, let permissions): return isMember && allowed(permissions)
        case .left, .banned, .unknown: return false
        }
    }
}
