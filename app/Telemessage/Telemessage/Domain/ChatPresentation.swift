import Foundation

/// Text shown for chats, senders and messages, derived from store state.
struct ChatPresentation {
    let store: TelegramStore

    func title(of chatID: Int64) -> String {
        guard let chat = store.chats[chatID] else { return "Loading…" }
        return title(of: chat)
    }

    func title(of chat: Chat) -> String {
        if !chat.title.isEmpty { return chat.title }
        if case .private(let userID) = chat.type, store.users[userID]?.type == .deleted { return "Deleted Account" }
        return "Untitled"
    }

    func senderName(_ sender: MessageSender) -> String {
        switch sender {
        case .user(let userID):
            if userID == store.myUserID { return "You" }
            guard let user = store.users[userID] else { return "Unknown" }
            return user.type == .deleted ? "Deleted Account" : user.fullName
        case .chat(let chatID):
            return title(of: chatID)
        case .unknown:
            return "Unknown"
        }
    }

    func isGroup(_ chat: Chat) -> Bool {
        switch chat.type {
        case .basicGroup, .supergroup: true
        default: false
        }
    }

    /// One-line summary of the chat's last message for lists ("You: ok", "Alex: Photo").
    func preview(of chat: Chat) -> String {
        guard let message = chat.lastMessage else { return "" }
        let summary = Self.summary(of: message.content)
        if message.isOutgoing { return "You: \(summary)" }
        if isGroup(chat), case .user = message.senderID {
            let name = senderName(message.senderID).split(separator: " ").first.map(String.init) ?? ""
            return name.isEmpty ? summary : "\(name): \(summary)"
        }
        return summary
    }

    static func summary(of content: MessageContent) -> String {
        func withCaption(_ label: String, _ caption: FormattedText) -> String {
            caption.text.isEmpty ? label : "\(label), \(caption.text)"
        }
        switch content {
        case .text(let text): return text.text.replacingOccurrences(of: "\n", with: " ")
        case .photo(_, let caption): return withCaption("Photo", caption)
        case .video(_, let caption): return withCaption("Video", caption)
        case .animation(_, let caption): return withCaption("GIF", caption)
        case .sticker(let sticker): return sticker.emoji.isEmpty ? "Sticker" : "\(sticker.emoji) Sticker"
        case .document(let document, let caption): return withCaption(document.fileName.isEmpty ? "File" : document.fileName, caption)
        case .voiceNote(_, let caption): return withCaption("Voice message", caption)
        case .audio(let audio, let caption):
            let name = [audio.performer, audio.title].filter { !$0.isEmpty }.joined(separator: " – ")
            return withCaption(name.isEmpty ? "Audio" : name, caption)
        case .videoNote: return "Video message"
        case .unsupported(let type): return ServiceText.describe(type)
        }
    }

    /// Window subtitle: a person's last-seen status or a group's member count.
    func subtitle(for chat: Chat, now: Date = .now) -> String {
        switch chat.type {
        case .private(let userID), .secret(_, let userID):
            guard let user = store.users[userID] else { return "" }
            if user.type == .bot { return "bot" }
            return Self.status(user.status, now: now)
        case .basicGroup(let groupID):
            return Self.members(store.basicGroups[groupID]?.memberCount)
        case .supergroup(let supergroupID, _):
            return Self.members(store.supergroups[supergroupID]?.memberCount)
        case .unknown:
            return ""
        }
    }

    static func members(_ count: Int32?) -> String {
        guard let count, count > 0 else { return "group" }
        return count == 1 ? "1 member" : "\(count.formatted()) members"
    }

    static func status(_ status: UserStatus, now: Date) -> String {
        switch status {
        case .online(let expires) where Date(timeIntervalSince1970: TimeInterval(expires)) > now:
            return "online"
        case .online(let expires):
            return "last seen \(RelativeTime.lastSeen(Date(timeIntervalSince1970: TimeInterval(expires)), now: now))"
        case .offline(let wasOnline):
            return "last seen \(RelativeTime.lastSeen(Date(timeIntervalSince1970: TimeInterval(wasOnline)), now: now))"
        case .recently: return "last seen recently"
        case .lastWeek: return "last seen within a week"
        case .lastMonth: return "last seen within a month"
        case .empty, .unknown: return "last seen a long time ago"
        }
    }

    /// Muted through the chat's own setting. Chats that follow the default scope count as unmuted.
    func isMuted(_ chat: Chat) -> Bool {
        !chat.notificationSettings.useDefaultMuteFor && chat.notificationSettings.muteFor > 0
    }

    static func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

enum RelativeTime {
    /// "10:42" today, "Mon" this week, otherwise a short date.
    static func listLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func lastSeen(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "at \(date.formatted(date: .omitted, time: .shortened))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Timeline day separators: "Today", "Yesterday", "Monday, 20 October".
    static func dayTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : date.formatted(date: .long, time: .omitted)
    }
}

/// Descriptions for message types rendered as fallback cards.
enum ServiceText {
    static func describe(_ type: String) -> String {
        switch type {
        case "messagePoll": "Poll"
        case "messageLocation", "messageVenue": "Location"
        case "messageContact": "Contact"
        case "messageDice": "Dice"
        case "messageGame": "Game"
        case "messageInvoice", "messagePaymentSuccessful": "Payment"
        case "messageCall", "messageGroupCall", "messageVideoChatStarted", "messageVideoChatEnded": "Call"
        case "messageStory": "Story"
        case "messageGiveaway", "messageGiveawayWinners": "Giveaway"
        case "messageChecklist": "Checklist"
        case "messagePinMessage": "Pinned a message"
        case "messageChatAddMembers": "Added members"
        case "messageChatJoinByLink", "messageChatJoinByRequest": "Joined the group"
        case "messageChatDeleteMember": "Left the group"
        case "messageChatChangeTitle": "Changed the group name"
        case "messageChatChangePhoto": "Changed the group photo"
        case "messageChatDeletePhoto": "Removed the group photo"
        case "messageBasicGroupChatCreate", "messageSupergroupChatCreate": "Created the group"
        case "messageChatUpgradeTo", "messageChatUpgradeFrom": "Upgraded to a supergroup"
        case "messageContactRegistered": "Joined Telegram"
        case "messageScreenshotTaken": "Took a screenshot"
        case "messageChatSetMessageAutoDeleteTime": "Changed auto-delete settings"
        case "messageGift", "messageUpgradedGift", "messageGiftedPremium", "messagePremiumGiftCode": "Gift"
        case "messageExpiredPhoto": "Photo has expired"
        case "messageExpiredVideo": "Video has expired"
        case "messageUnsupported": "Message not supported by this version of Telegram"
        default: "Unsupported message"
        }
    }

    /// Service messages are centered notices rather than bubbles.
    static func isServiceMessage(_ type: String) -> Bool {
        type.hasPrefix("messageChat") || [
            "messagePinMessage", "messageBasicGroupChatCreate", "messageSupergroupChatCreate",
            "messageContactRegistered", "messageScreenshotTaken", "messageVideoChatStarted",
            "messageVideoChatEnded", "messageGroupCall",
        ].contains(type)
    }
}
