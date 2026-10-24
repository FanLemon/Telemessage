import Foundation

nonisolated struct Message: Decodable, Sendable, Identifiable, Equatable {
    let id: Int64
    let senderID: MessageSender
    let chatID: Int64
    var sendingState: MessageSendingState?
    let isOutgoing: Bool
    let date: Int32
    var editDate: Int32
    var replyTo: MessageReplyTo?
    let mediaAlbumID: TDInt64
    var content: MessageContent
}

nonisolated enum MessageSender: Decodable, Sendable, Hashable {
    case user(Int64)
    case chat(Int64)
    case unknown(String)

    private struct UserSender: Decodable { let userID: Int64 }
    private struct ChatSender: Decodable { let chatID: Int64 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "messageSenderUser": self = .user(try UserSender(from: decoder).userID)
        case "messageSenderChat": self = .chat(try ChatSender(from: decoder).chatID)
        case let other: self = .unknown(other)
        }
    }
}

nonisolated enum MessageSendingState: Decodable, Sendable, Equatable {
    case pending
    case failed(error: TDError, canRetry: Bool)
    case unknown(String)

    private struct Failed: Decodable { let error: TDError; let canRetry: Bool }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "messageSendingStatePending":
            self = .pending
        case "messageSendingStateFailed":
            let failed = try Failed(from: decoder)
            self = .failed(error: failed.error, canRetry: failed.canRetry)
        case let other:
            self = .unknown(other)
        }
    }
}

nonisolated enum MessageReplyTo: Decodable, Sendable, Equatable {
    /// `chatID` may differ from the message's chat for cross-chat replies.
    case message(chatID: Int64, messageID: Int64)
    case other(String)

    private struct ToMessage: Decodable { let chatID: Int64; let messageID: Int64 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "messageReplyToMessage":
            let value = try ToMessage(from: decoder)
            self = .message(chatID: value.chatID, messageID: value.messageID)
        case let other:
            self = .other(other)
        }
    }
}

nonisolated struct FormattedText: Codable, Sendable, Equatable {
    var text: String
    var entities: [TextEntity]

    init(text: String, entities: [TextEntity] = []) {
        self.text = text
        self.entities = entities
    }
}

nonisolated struct TextEntity: Codable, Sendable, Equatable {
    /// UTF-16 offset and length.
    let offset: Int32
    let length: Int32
    let type: TextEntityType
}

nonisolated enum TextEntityType: Codable, Sendable, Equatable {
    case bold, italic, underline, strikethrough, spoiler, code
    case pre(language: String?)
    case textURL(String)
    case mentionName(userID: Int64)
    case customEmoji(TDInt64)
    case blockQuote, expandableBlockQuote
    /// Entities TDLib detects itself (url, mention, hashtag, …) and anything newer than this model.
    case other(String)

    private struct Pre: Codable { let language: String }
    private struct TextURL: Codable { let url: String }
    private struct MentionName: Codable { let userID: Int64 }
    private struct CustomEmoji: Codable { let customEmojiID: TDInt64 }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "textEntityTypeBold": self = .bold
        case "textEntityTypeItalic": self = .italic
        case "textEntityTypeUnderline": self = .underline
        case "textEntityTypeStrikethrough": self = .strikethrough
        case "textEntityTypeSpoiler": self = .spoiler
        case "textEntityTypeCode": self = .code
        case "textEntityTypePre": self = .pre(language: nil)
        case "textEntityTypePreCode": self = .pre(language: try Pre(from: decoder).language)
        case "textEntityTypeTextUrl": self = .textURL(try TextURL(from: decoder).url)
        case "textEntityTypeMentionName": self = .mentionName(userID: try MentionName(from: decoder).userID)
        case "textEntityTypeCustomEmoji": self = .customEmoji(try CustomEmoji(from: decoder).customEmojiID)
        case "textEntityTypeBlockQuote": self = .blockQuote
        case "textEntityTypeExpandableBlockQuote": self = .expandableBlockQuote
        case let other: self = .other(other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .bold: try TDTyped("textEntityTypeBold").encode(to: encoder)
        case .italic: try TDTyped("textEntityTypeItalic").encode(to: encoder)
        case .underline: try TDTyped("textEntityTypeUnderline").encode(to: encoder)
        case .strikethrough: try TDTyped("textEntityTypeStrikethrough").encode(to: encoder)
        case .spoiler: try TDTyped("textEntityTypeSpoiler").encode(to: encoder)
        case .code: try TDTyped("textEntityTypeCode").encode(to: encoder)
        case .pre(nil): try TDTyped("textEntityTypePre").encode(to: encoder)
        case .pre(let language?): try TDTyped("textEntityTypePreCode", Pre(language: language)).encode(to: encoder)
        case .textURL(let url): try TDTyped("textEntityTypeTextUrl", TextURL(url: url)).encode(to: encoder)
        case .mentionName(let userID): try TDTyped("textEntityTypeMentionName", MentionName(userID: userID)).encode(to: encoder)
        case .customEmoji(let id): try TDTyped("textEntityTypeCustomEmoji", CustomEmoji(customEmojiID: id)).encode(to: encoder)
        case .blockQuote: try TDTyped("textEntityTypeBlockQuote").encode(to: encoder)
        case .expandableBlockQuote: try TDTyped("textEntityTypeExpandableBlockQuote").encode(to: encoder)
        case .other(let type): try TDTyped(type).encode(to: encoder)
        }
    }
}

nonisolated enum MessageContent: Decodable, Sendable, Equatable {
    case text(FormattedText)
    case photo(Photo, caption: FormattedText)
    case video(Video, caption: FormattedText)
    case animation(Animation, caption: FormattedText)
    case sticker(Sticker)
    case document(Document, caption: FormattedText)
    case voiceNote(VoiceNote, caption: FormattedText)
    case audio(Audio, caption: FormattedText)
    case videoNote(VideoNote)
    /// Service messages, polls, locations, etc.; rendered as a descriptive fallback card.
    case unsupported(String)

    private struct Text: Decodable { let text: FormattedText }
    private struct PhotoContent: Decodable { let photo: Photo; let caption: FormattedText }
    private struct VideoContent: Decodable { let video: Video; let caption: FormattedText }
    private struct AnimationContent: Decodable { let animation: Animation; let caption: FormattedText }
    private struct StickerContent: Decodable { let sticker: Sticker }
    private struct DocumentContent: Decodable { let document: Document; let caption: FormattedText }
    private struct VoiceNoteContent: Decodable { let voiceNote: VoiceNote; let caption: FormattedText }
    private struct AudioContent: Decodable { let audio: Audio; let caption: FormattedText }
    private struct VideoNoteContent: Decodable { let videoNote: VideoNote }

    init(from decoder: any Decoder) throws {
        switch try TDTypeTag.read(decoder) {
        case "messageText":
            self = .text(try Text(from: decoder).text)
        case "messagePhoto":
            let value = try PhotoContent(from: decoder)
            self = .photo(value.photo, caption: value.caption)
        case "messageVideo":
            let value = try VideoContent(from: decoder)
            self = .video(value.video, caption: value.caption)
        case "messageAnimation":
            let value = try AnimationContent(from: decoder)
            self = .animation(value.animation, caption: value.caption)
        case "messageSticker":
            self = .sticker(try StickerContent(from: decoder).sticker)
        case "messageDocument":
            let value = try DocumentContent(from: decoder)
            self = .document(value.document, caption: value.caption)
        case "messageVoiceNote":
            let value = try VoiceNoteContent(from: decoder)
            self = .voiceNote(value.voiceNote, caption: value.caption)
        case "messageAudio":
            let value = try AudioContent(from: decoder)
            self = .audio(value.audio, caption: value.caption)
        case "messageVideoNote":
            self = .videoNote(try VideoNoteContent(from: decoder).videoNote)
        case let other:
            self = .unsupported(other)
        }
    }
}

nonisolated struct Messages: Decodable, Sendable {
    let totalCount: Int32
    let messages: [Message]

    private enum CodingKeys: String, CodingKey { case totalCount, messages }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try container.decode(Int32.self, forKey: .totalCount)
        // Some requests (e.g. getMessages) return null for inaccessible messages.
        messages = try container.decode([Message?].self, forKey: .messages).compactMap { $0 }
    }
}
