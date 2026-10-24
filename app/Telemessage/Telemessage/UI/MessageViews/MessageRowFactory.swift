import Cocoa

/// Resolves a message into what its row shows: sender, reply, text, media slot and footer.
struct MessageRowFactory {
    let services: AccountServices
    let model: ConversationModel

    func make(_ message: Message, previous: Message?) -> MessageRowModel {
        let presentation = services.presentation
        if case .unsupported(let type) = message.content, ServiceText.isServiceMessage(type) {
            var description = ServiceText.describe(type)
            description = description.prefix(1).lowercased() + description.dropFirst()
            let text = "\(presentation.senderName(message.senderID)) \(description)"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
            return MessageRowModel(message: message, senderName: nil, senderColor: .labelColor, reply: nil, text: attributed,
                                   media: nil, footer: NSAttributedString(), continuesGroup: false, isService: true)
        }

        let continues = TimelineBuilder.continuesGroup(message, after: previous)
        let isGroup = model.chat.map(presentation.isGroup) ?? false
        let senderName = isGroup && !message.isOutgoing && !continues ? presentation.senderName(message.senderID) : nil
        let (text, media) = body(of: message.content)
        let overlay = media != nil && media?.kind != .card && text == nil
        return MessageRowModel(
            message: message,
            senderName: senderName,
            senderColor: color(for: message.senderID),
            reply: reply(for: message),
            text: text,
            media: media,
            footer: footer(for: message, onMedia: overlay),
            continuesGroup: continues,
            isService: false
        )
    }

    private func body(of content: MessageContent) -> (NSAttributedString?, MediaSpec?) {
        let media = MediaSpec.make(for: content, maxWidth: 320)
        func caption(_ text: FormattedText) -> NSAttributedString? {
            text.text.isEmpty ? nil : MessageText.attributed(text)
        }
        switch content {
        case .text(let text):
            return (MessageText.attributed(text), nil)
        case .photo(_, let text), .video(_, let text), .animation(_, let text), .document(_, let text),
             .voiceNote(_, let text), .audio(_, let text):
            return (caption(text), media)
        case .sticker, .videoNote:
            return (nil, media)
        case .unsupported(let type):
            return (MessageText.italicNote("\(ServiceText.describe(type)) — open Telegram to view it."), nil)
        }
    }

    private func reply(for message: Message) -> MessageRowModel.Reply? {
        switch model.reply(for: message) {
        case nil:
            return nil
        case .loaded(let replied):
            return MessageRowModel.Reply(title: services.presentation.senderName(replied.senderID),
                                         text: ChatPresentation.summary(of: replied.content),
                                         color: color(for: replied.senderID))
        case .loading:
            return MessageRowModel.Reply(title: "Reply", text: "Loading…", color: .controlAccentColor)
        case .unavailable:
            return MessageRowModel.Reply(title: "Reply", text: "Deleted message", color: .secondaryLabelColor)
        }
    }

    func color(for sender: MessageSender) -> NSColor {
        switch sender {
        case .user(let userID):
            AvatarView.accentColor(services.store.users[userID]?.accentColorID ?? Int32(truncatingIfNeeded: userID))
        case .chat(let chatID):
            AvatarView.accentColor(services.store.chats[chatID]?.accentColorID ?? 5)
        case .unknown:
            .controlAccentColor
        }
    }

    /// "edited 10:42 ✓✓" — time and, for outgoing messages, delivery state.
    func footer(for message: Message, onMedia: Bool) -> NSAttributedString {
        let color: NSColor = onMedia ? .white : .secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: MessageLayout.footerFont, .foregroundColor: color]
        var text = message.editDate > 0 ? "edited " : ""
        text += Date(timeIntervalSince1970: TimeInterval(message.date)).formatted(date: .omitted, time: .shortened)
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        guard message.isOutgoing else { return result }
        switch message.sendingState {
        case .pending:
            result.append(NSAttributedString(string: " ", attributes: attributes))
            result.append(Self.symbol("clock", color: color))
        case .failed:
            result.append(NSAttributedString(string: " ", attributes: attributes))
            result.append(Self.symbol("exclamationmark.circle.fill", color: .systemRed))
        case .unknown, nil:
            let isRead = message.id <= (model.chat?.lastReadOutboxMessageID ?? 0)
            var tick = attributes
            if isRead, !onMedia { tick[.foregroundColor] = NSColor.controlAccentColor }
            result.append(NSAttributedString(string: isRead ? " ✓✓" : " ✓", attributes: tick))
        }
        return result
    }

    private static func symbol(_ name: String, color: NSColor) -> NSAttributedString {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?.tinted(color) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}
