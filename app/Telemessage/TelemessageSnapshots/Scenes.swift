import Cocoa
@testable import TelemessageCore

@MainActor
enum Scenes {
    static let all: [(String, () -> Void)] = [
        ("login", login),
        ("main", mainWindow),
        ("picker", picker),
        ("conversation", conversation),
        ("sending", sending),
        ("settings", settings),
    ]

    static func settings() {
        Snapshot.render("settings", size: NSSize(width: 460, height: 360), dark: true) {
            SettingsViewController(services: SampleAccount.makeServices(), actions: .init())
        }
    }

    static func sending() {
        Snapshot.render("sending-tray", size: NSSize(width: 440, height: 520), settle: 2.5) {
            let services = SampleAccount.makeServices()
            let uploading = SampleAccount.message(120, chat: 2, sender: 1, content: SampleAccount.photoContent(
                caption: "", width: 1280, height: 960, fileID: 90, path: SampleImages.landscape), ago: 5)
            var message = try! TDCoding.decoder.decode(Message.self, from: Data(uploading.utf8))
            message.sendingState = try! TDCoding.decoder.decode(MessageSendingState.self, from: Data(#"{"@type":"messageSendingStatePending","sending_id":1}"#.utf8))
            services.store.trackMessages(in: 2)
            services.store.merge([message], into: 2)
            // Half uploaded.
            services.store.apply(Snapshot.update(#"{"@type":"updateFile","file":\#(SampleAccount.file(90, size: 120_000, path: SampleImages.landscape).replacingOccurrences(of: "\"uploaded_size\":120000", with: "\"uploaded_size\":60000").replacingOccurrences(of: "\"is_uploading_completed\":true", with: "\"is_uploading_completed\":false"))}"#))
            let controller = ConversationViewController(chatID: 2, services: services)
            _ = controller.view
            controller.addFiles([URL(fileURLWithPath: SampleImages.landscape), URL(fileURLWithPath: SampleImages.poster),
                                 URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")])
            controller.composer.text = "Trip photos"
            return controller
        }
    }

    static func conversation() {
        Snapshot.render("conversation-group", size: NSSize(width: 440, height: 1100), dark: true, settle: 0.4) {
            let services = SampleAccount.makeServices()
            let store = services.store
            store.apply(Snapshot.update(#"{"@type":"updateChatReadOutbox","chat_id":-1001,"last_read_outbox_message_id":106}"#))
            store.trackMessages(in: -1001)
            store.merge(SampleAccount.conversationMessages(), into: -1001)
            return ConversationViewController(chatID: -1001, services: services)
        }
        Snapshot.render("conversation-short", size: NSSize(width: 360, height: 480)) {
            let services = SampleAccount.makeServices()
            services.store.trackMessages(in: 2)
            services.store.merge(Array(SampleAccount.conversationMessages(chat: 2).suffix(2)), into: 2)
            return ConversationViewController(chatID: 2, services: services)
        }
    }

    static func mainWindow() {
        Snapshot.render("main-list", size: NSSize(width: 320, height: 420), dark: true) {
            ChatListViewController(services: SampleAccount.makeServices(), actions: .init())
        }
        Snapshot.render("main-empty", size: NSSize(width: 320, height: 420)) {
            ChatListViewController(services: SampleAccount.makeServices(selected: []), actions: .init())
        }
    }

    static func picker() {
        Snapshot.render("picker", size: NSSize(width: 480, height: 600), dark: true) {
            ChatPickerViewController(services: SampleAccount.makeServices(selected: [2, -1002]), onFinish: {})
        }
    }

    static func login() {
        let states: [(String, String)] = [
            ("phone", #"{"@type":"authorizationStateWaitPhoneNumber"}"#),
            ("code", #"""
                {"@type":"authorizationStateWaitCode","code_info":{"@type":"authenticationCodeInfo",
                 "phone_number":"+81 90 0000 0000","type":{"@type":"authenticationCodeTypeTelegramMessage","length":5},
                 "next_type":{"@type":"authenticationCodeTypeSms","length":5},"timeout":42}}
                """#),
            ("password", #"""
                {"@type":"authorizationStateWaitPassword","password_hint":"first pet","has_recovery_email_address":true,
                 "has_passport_data":false,"recovery_email_address_pattern":"a***@example.com"}
                """#),
            ("qr", #"{"@type":"authorizationStateWaitOtherDeviceConfirmation","link":"tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}"#),
            ("registration", #"{"@type":"authorizationStateWaitRegistration","terms_of_service":{"@type":"termsOfService","text":{"@type":"formattedText","text":"","entities":[]},"min_user_age":0,"show_popup":false}}"#),
        ]
        for (name, state) in states {
            Snapshot.render("login-\(name)", size: NSSize(width: 440, height: 540), dark: name == "code") {
                let session = Snapshot.makeSession()
                session.store.apply(Snapshot.update(#"{"@type":"updateAuthorizationState","authorization_state":\#(state)}"#))
                return LoginViewController(session: session)
            }
        }
    }
}
