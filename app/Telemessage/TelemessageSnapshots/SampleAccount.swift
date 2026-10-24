import Foundation
@testable import TelemessageCore

/// A fictional account: users, chats and messages fed straight into a store.
@MainActor
enum SampleAccount {
    static let now = Int(Date().timeIntervalSince1970)

    static func makeServices(selected: [Int64] = [2, -1001, -1002, 3]) -> AccountServices {
        let session = Snapshot.makeSession()
        let services = AccountServices(session: session, storage: nil)
        for update in updates() { session.store.apply(update) }
        services.selection.replace(with: selected)
        return services
    }

    static func updates() -> [Update] {
        var json: [String] = [
            #"{"@type":"updateOption","name":"my_id","value":{"@type":"optionValueInteger","value":"1"}}"#,
            user(1, "Sam", "Rivera", accent: 5),
            user(2, "Alex", "Chen", accent: 0, status: #"{"@type":"userStatusOnline","expires":\#(now + 300)}"#),
            user(3, "Mia", "Tanaka", accent: 3, status: #"{"@type":"userStatusOffline","was_online":\#(now - 3_600)}"#),
            user(4, "Kenji", "Sato", accent: 1),
            user(5, "Priya", "Nair", accent: 2),
            #"{"@type":"updateBasicGroup","basic_group":{"@type":"basicGroup","id":11,"member_count":5,"status":{"@type":"chatMemberStatusMember","member_until_date":0},"is_active":true,"upgraded_to_supergroup_id":0}}"#,
            supergroup(21, members: 12, channel: false),
            supergroup(22, members: 18_420, channel: true),
            supergroup(23, members: 240, channel: false, forum: true),
        ]
        json.append(chat(2, "Alex Chen", type: #"{"@type":"chatTypePrivate","user_id":2}"#, accent: 0, order: 900, unread: 2,
                         last: message(901, chat: 2, sender: 2, text: "Here is the latest version — let me know!", ago: 120)))
        json.append(chat(-1001, "Design team", type: #"{"@type":"chatTypeBasicGroup","basic_group_id":11}"#, accent: 3, order: 800, unread: 5,
                         last: message(801, chat: -1001, sender: 4, text: "Shipping the icons tonight", ago: 1_800)))
        json.append(chat(-1002, "Family", type: #"{"@type":"chatTypeSupergroup","supergroup_id":21,"is_channel":false}"#, accent: 1, order: 700, unread: 0,
                         muted: true, last: message(701, chat: -1002, sender: 1, text: "See you Sunday", ago: 90_000)))
        json.append(chat(3, "Mia Tanaka", type: #"{"@type":"chatTypePrivate","user_id":3}"#, accent: 3, order: 600, unread: 0,
                         last: message(601, chat: 3, sender: 3, content: photoContent(caption: ""), ago: 400_000)))
        json.append(chat(-1003, "Tech News", type: #"{"@type":"chatTypeSupergroup","supergroup_id":22,"is_channel":true}"#, accent: 4, order: 500, unread: 31,
                         last: message(501, chat: -1003, sender: 0, text: "Weekly roundup", ago: 7_200)))
        json.append(chat(-1004, "Makers Forum", type: #"{"@type":"chatTypeSupergroup","supergroup_id":23,"is_channel":false}"#, accent: 6, order: 400, unread: 0,
                         last: nil, archived: true))
        json.append(chat(5, "Priya Nair", type: #"{"@type":"chatTypePrivate","user_id":5}"#, accent: 2, order: 300, unread: 0,
                         last: message(301, chat: 5, sender: 1, text: "Thanks!", ago: 900_000), archived: true))
        return json.map(Snapshot.update)
    }

    /// A group conversation exercising the timeline's row kinds.
    static func conversationMessages(chat: Int64 = -1001) -> [Message] {
        let bold = #"[{"@type":"textEntity","offset":0,"length":7,"type":{"@type":"textEntityTypeBold"}},{"@type":"textEntity","offset":31,"length":15,"type":{"@type":"textEntityTypeUrl"}}]"#
        let json = [
            message(100, chat: chat, sender: 4, content: #"{"@type":"messageChatAddMembers","member_user_ids":[5]}"#, ago: 90_000),
            message(101, chat: chat, sender: 4, text: "Morning! Draft icons are up.", ago: 89_000),
            message(102, chat: chat, sender: 4, text: "Feedback welcome before Friday.", ago: 88_950),
            message(103, chat: chat, sender: 1, text: "Looks great — the send arrow could be a touch bolder?", ago: 88_000),
            message(104, chat: chat, sender: 2, content: photoContent(caption: "Updated mockup", path: SampleImages.landscape), ago: 3_600),
            message(105, chat: chat, sender: 2, text: "Heads up: preview at example.com/icons today", ago: 3_500),
            message(106, chat: chat, sender: 1, text: "On it", ago: 600, reply: 105),
            message(107, chat: chat, sender: 5, content: #"{"@type":"messageSticker","is_premium":false,"sticker":{"@type":"sticker","id":"1","set_id":"2","width":512,"height":512,"emoji":"👍","format":{"@type":"stickerFormatWebp"},"full_type":{"@type":"stickerFullTypeRegular"},"sticker":\#(file(80, path: SampleImages.sticker))}}"#, ago: 500),
            message(111, chat: chat, sender: 2, content: videoContent(), ago: 180),
            message(112, chat: chat, sender: 5, content: #"{"@type":"messageVoiceNote","voice_note":{"@type":"voiceNote","duration":14,"waveform":"","mime_type":"audio/ogg","voice":\#(file(83, size: 23_000))},"caption":{"@type":"formattedText","text":"","entities":[]},"is_listened":false}"#, ago: 120),
            message(108, chat: chat, sender: 4, content: textContent("Release notes: icons, dark mode fixes and a much longer line that needs to wrap across several lines in the bubble.", entities: bold), ago: 300, edited: true),
            message(109, chat: chat, sender: 1, content: #"{"@type":"messageDocument","document":{"@type":"document","file_name":"icons-v3.sketch","mime_type":"application/octet-stream","document":\#(file(81, size: 4_200_000))},"caption":{"@type":"formattedText","text":"","entities":[]}}"#, ago: 200),
            message(113, chat: chat, sender: 1, text: "Sending from the train", ago: 30),
        ]
        var messages = json.map { try! TDCoding.decoder.decode(Message.self, from: Data($0.utf8)) }
        messages[messages.count - 1].sendingState = try! TDCoding.decoder.decode(MessageSendingState.self, from: Data(#"{"@type":"messageSendingStatePending","sending_id":1}"#.utf8))
        return messages
    }

    // MARK: JSON builders

    static func user(_ id: Int64, _ first: String, _ last: String, accent: Int, status: String? = nil) -> String {
        """
        {"@type":"updateUser","user":{"@type":"user","id":\(id),"first_name":"\(first)","last_name":"\(last)",
         "usernames":{"@type":"usernames","active_usernames":["\(first.lowercased())"],"disabled_usernames":[],"editable_username":"\(first.lowercased())","collectible_usernames":[]},
         "phone_number":"","status":\(status ?? #"{"@type":"userStatusRecently","by_my_privacy_settings":false}"#),
         "accent_color_id":\(accent),"is_contact":true,"is_mutual_contact":true,"type":{"@type":"userTypeRegular"}}}
        """
    }

    static func supergroup(_ id: Int64, members: Int, channel: Bool, forum: Bool = false) -> String {
        """
        {"@type":"updateSupergroup","supergroup":{"@type":"supergroup","id":\(id),"member_count":\(members),
         "status":{"@type":"chatMemberStatusMember","member_until_date":0},"is_channel":\(channel),"is_forum":\(forum)}}
        """
    }

    static let permissions = """
        {"@type":"chatPermissions","can_send_basic_messages":true,"can_send_audios":true,"can_send_documents":true,
         "can_send_photos":true,"can_send_videos":true,"can_send_video_notes":true,"can_send_voice_notes":true,
         "can_send_polls":true,"can_send_other_messages":true,"can_add_link_previews":true}
        """

    static func chat(_ id: Int64, _ title: String, type: String, accent: Int, order: Int, unread: Int,
                     muted: Bool = false, last: String?, archived: Bool = false) -> String {
        let list = archived ? "chatListArchive" : "chatListMain"
        return """
        {"@type":"updateNewChat","chat":{"@type":"chat","id":\(id),"type":\(type),"title":"\(title)","accent_color_id":\(accent),
         "permissions":\(permissions),
         \(last.map { #""last_message":\#($0),"# } ?? "")
         "positions":[{"@type":"chatPosition","list":{"@type":"\(list)"},"order":"\(order)","is_pinned":false}],
         "unread_count":\(unread),"last_read_inbox_message_id":0,"last_read_outbox_message_id":0,
         "notification_settings":{"@type":"chatNotificationSettings","use_default_mute_for":\(!muted),"mute_for":\(muted ? 2_000_000_000 : 0),
                                  "use_default_show_preview":true,"show_preview":true}}}
        """
    }

    static func message(_ id: Int64, chat: Int64, sender: Int64, text: String = "", content: String? = nil,
                        ago: Int, outgoingRead: Bool = true, reply: Int64? = nil, edited: Bool = false) -> String {
        let senderJSON = sender == 0
            ? #"{"@type":"messageSenderChat","chat_id":\#(chat)}"#
            : #"{"@type":"messageSenderUser","user_id":\#(sender)}"#
        let replyJSON = reply.map { #""reply_to":{"@type":"messageReplyToMessage","chat_id":\#(chat),"message_id":\#($0)},"# } ?? ""
        return """
        {"@type":"message","id":\(id),"sender_id":\(senderJSON),"chat_id":\(chat),"is_outgoing":\(sender == 1),
         "date":\(now - ago),"edit_date":\(edited ? now - ago + 60 : 0),"media_album_id":"0",\(replyJSON)
         "content":\(content ?? textContent(text))}
        """
    }

    static func textContent(_ text: String, entities: String = "[]") -> String {
        #"{"@type":"messageText","text":{"@type":"formattedText","text":"\#(text)","entities":\#(entities)}}"#
    }

    static func file(_ id: Int, size: Int = 120_000, path: String? = nil) -> String {
        """
        {"@type":"file","id":\(id),"size":\(size),"expected_size":\(size),
         "local":{"@type":"localFile","path":"\(path ?? "")","can_be_downloaded":true,"can_be_deleted":true,
                  "is_downloading_active":false,"is_downloading_completed":\(path != nil),"download_offset":0,
                  "downloaded_prefix_size":0,"downloaded_size":\(path != nil ? size : 0)},
         "remote":{"@type":"remoteFile","id":"r\(id)","unique_id":"u\(id)","is_uploading_active":false,
                   "is_uploading_completed":true,"uploaded_size":\(size)}}
        """
    }

    static func videoContent() -> String {
        """
        {"@type":"messageVideo","video":{"@type":"video","duration":83,"width":1280,"height":720,"file_name":"clip.mp4",
          "mime_type":"video/mp4","has_stickers":false,"supports_streaming":true,
          "thumbnail":{"@type":"thumbnail","format":{"@type":"thumbnailFormatJpeg"},"width":320,"height":180,"file":\(file(84, path: SampleImages.poster))},
          "video":\(file(85, size: 18_400_000))},
         "alternative_videos":[],"storyboards":[],"start_timestamp":0,
         "caption":{"@type":"formattedText","text":"","entities":[]},"show_caption_above_media":false,"has_spoiler":false,"is_secret":false}
        """
    }

    static func photoContent(caption: String, width: Int = 1280, height: Int = 960, fileID: Int = 70, path: String? = nil) -> String {
        """
        {"@type":"messagePhoto","photo":{"@type":"photo","has_stickers":false,
          "sizes":[{"@type":"photoSize","type":"x","photo":\(file(fileID, path: path)),"width":\(width),"height":\(height),"progressive_sizes":[]}]},
         "caption":{"@type":"formattedText","text":"\(caption)","entities":[]},
         "show_caption_above_media":false,"has_spoiler":false,"is_secret":false}
        """
    }
}
