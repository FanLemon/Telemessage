import CTDJson
import Foundation

typealias JSON = [String: Any]

// MARK: - TDLib JSON client

/// Thin wrapper over td_json_client: one receive thread, responses matched by `@extra`.
final class TDClient {
    private let clientId = td_create_client_id()
    private let lock = NSLock()
    private var handlers: [Int: (JSON) -> Void] = [:]
    private var nextExtra = 1

    /// Called on the receive thread for every update (anything without a pending `@extra`).
    var onUpdate: ((JSON) -> Void)?

    func send(_ request: JSON, completion: ((JSON) -> Void)? = nil) {
        var request = request
        if let completion {
            lock.lock()
            let extra = nextExtra
            nextExtra += 1
            handlers[extra] = completion
            lock.unlock()
            request["@extra"] = extra
        }
        td_send(clientId, TDClient.encode(request))
    }

    /// Sends a request and blocks until its response arrives. Never call from the receive thread.
    func call(_ request: JSON) -> JSON {
        let semaphore = DispatchSemaphore(value: 0)
        var response: JSON = [:]
        send(request) { response = $0; semaphore.signal() }
        semaphore.wait()
        return response
    }

    func startReceiving() {
        let thread = Thread { [self] in
            while true {
                // The returned pointer is only valid until the next td_receive call, so copy it now.
                guard let raw = td_receive(1.0), let object = TDClient.decode(String(cString: raw)) else { continue }
                if let extra = object["@extra"] as? Int, let handler = takeHandler(extra) {
                    handler(object)
                } else {
                    onUpdate?(object)
                }
            }
        }
        thread.name = "tdlib-receive"
        thread.start()
    }

    static func execute(_ request: JSON) -> JSON? {
        td_execute(encode(request)).flatMap { decode(String(cString: $0)) }
    }

    private func takeHandler(_ extra: Int) -> ((JSON) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: extra)
    }

    private static func encode(_ object: JSON) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ text: String) -> JSON? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON
    }
}

/// Blocking FIFO used to hand authorization states from the receive thread to the main thread.
final class Mailbox<T> {
    private var items: [T] = []
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)

    func put(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
        available.signal()
    }

    func take() -> T {
        available.wait()
        lock.lock()
        defer { lock.unlock() }
        return items.removeFirst()
    }
}

// MARK: - Helpers

struct Config {
    let apiId: Int
    let apiHash: String

    /// TD_API_ID / TD_API_HASH env vars win; otherwise read $TDCLI_CONFIG or ./config.local.json.
    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        if let id = env["TD_API_ID"].flatMap(Int.init), let hash = env["TD_API_HASH"], !hash.isEmpty {
            return Config(apiId: id, apiHash: hash)
        }
        let path = env["TDCLI_CONFIG"] ?? "config.local.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let id = json["api_id"] as? Int,
              let hash = json["api_hash"] as? String
        else {
            fail("Missing API credentials. Create \(path) (see config.example.json) or set TD_API_ID / TD_API_HASH.")
        }
        return Config(apiId: id, apiHash: hash)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Parks the calling thread; the receive thread exits the process on authorizationStateClosed.
func waitForClose() -> Never {
    while true { sleep(60) }
}

func closeAndWait() -> Never {
    client.send(["@type": "close"])
    waitForClose()
}

func prompt(_ text: String) -> String {
    print(text, terminator: "")
    fflush(stdout)
    guard let line = readLine() else { closeAndWait() }
    return line.trimmingCharacters(in: .whitespaces)
}

func askPhoneNumber() -> String {
    prompt("Phone number (international format, e.g. +8613800000000): ")
}

func promptSecret(_ text: String) -> String {
    guard let raw = getpass(text) else { closeAndWait() }
    return String(cString: raw)
}

/// Prints a TDLib error response and returns false, or returns true for anything else.
@discardableResult
func check(_ response: JSON) -> Bool {
    guard response["@type"] as? String == "error" else { return true }
    print("TDLib error \(response["code"] ?? "?"): \(response["message"] ?? "")")
    return false
}

/// Keeps asking until TDLib accepts the answer (wrong codes leave the auth state unchanged).
func askUntilAccepted(_ ask: () -> String, _ makeRequest: (String) -> JSON) {
    while !check(client.call(makeRequest(ask()))) {}
}

let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

func describe(message: JSON) -> String {
    let content = message["content"] as? JSON ?? [:]
    let type = content["@type"] as? String ?? "?"
    let text: String
    switch type {
    case "messageText":
        text = (content["text"] as? JSON)?["text"] as? String ?? ""
    default:
        let caption = (content["caption"] as? JSON)?["text"] as? String ?? ""
        text = "<\(type)>" + (caption.isEmpty ? "" : " \(caption)")
    }
    let date = Date(timeIntervalSince1970: TimeInterval(message["date"] as? Int ?? 0))
    let direction = (message["is_outgoing"] as? Bool ?? false) ? "→" : "←"
    return "[\(dateFormatter.string(from: date))] \(message["id"] ?? "?") \(direction) \(text)"
}

// Chat titles cached from updates; written on the receive thread, read on the main thread.
let titlesLock = NSLock()
var chatTitles: [Int: String] = [:]

func setTitle(_ title: String, for chatId: Int) {
    titlesLock.lock()
    chatTitles[chatId] = title
    titlesLock.unlock()
}

func title(for chatId: Int) -> String {
    titlesLock.lock()
    defer { titlesLock.unlock() }
    return chatTitles[chatId] ?? String(chatId)
}

// MARK: - Startup

let config = Config.load()
_ = TDClient.execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": 1])

let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TelemessageCLI", isDirectory: true)

let client = TDClient()
let authStates = Mailbox<JSON>()

client.onUpdate = { update in
    switch update["@type"] as? String {
    case "updateAuthorizationState":
        let state = update["authorization_state"] as? JSON ?? [:]
        if state["@type"] as? String == "authorizationStateClosed" {
            print("\nTDLib closed.")
            exit(0)
        }
        authStates.put(state)
    case "updateNewChat":
        if let chat = update["chat"] as? JSON, let id = chat["id"] as? Int {
            setTitle(chat["title"] as? String ?? "", for: id)
        }
    case "updateChatTitle":
        if let id = update["chat_id"] as? Int {
            setTitle(update["title"] as? String ?? "", for: id)
        }
    case "updateNewMessage":
        if let message = update["message"] as? JSON,
           !(message["is_outgoing"] as? Bool ?? false),
           let chatId = message["chat_id"] as? Int {
            print("\n[new] \(title(for: chatId)) (\(chatId)): \(describe(message: message))")
        }
    default:
        break
    }
}
client.startReceiving()

// Close TDLib cleanly on Ctrl-C so its database stays consistent.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler { client.send(["@type": "close"]) }
sigint.resume()

// The instance emits no updates until it receives its first request.
client.send(["@type": "getOption", "name": "version"]) { response in
    print("TDLib version \(response["value"] ?? "?")")
}

// MARK: - Authorization

authorization: while true {
    let state = authStates.take()
    switch state["@type"] as? String ?? "" {
    case "authorizationStateWaitTdlibParameters":
        let parameters: JSON = [
            "@type": "setTdlibParameters",
            "use_test_dc": false,
            "database_directory": dataDir.appendingPathComponent("db").path,
            "files_directory": dataDir.appendingPathComponent("files").path,
            "database_encryption_key": "",
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": config.apiId,
            "api_hash": config.apiHash,
            "system_language_code": Locale.current.language.languageCode?.identifier ?? "en",
            "device_model": "Mac",
            "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "application_version": "0.1 (tdcli)",
        ]
        if !check(client.call(parameters)) { fail("setTdlibParameters rejected") }
    case "authorizationStateWaitPhoneNumber":
        askUntilAccepted(askPhoneNumber) {
            ["@type": "setAuthenticationPhoneNumber", "phone_number": $0]
        }
    case "authorizationStateWaitCode":
        // TDLib persists this state, so after a restart we land here without asking for the phone again.
        let info = state["code_info"] as? JSON ?? [:]
        let via = ((info["type"] as? JSON)?["@type"] as? String ?? "?")
            .replacingOccurrences(of: "authenticationCodeType", with: "")
        print("Login code was sent to \(info["phone_number"] ?? "?") via \(via).")
        codeLoop: while true {
            let answer = prompt("Login code ('phone' = use another number, 'resend' = send code again): ")
            switch answer.lowercased() {
            case "phone":
                // Accepted → a fresh authorizationStateWaitCode arrives for the new number.
                if check(client.call(["@type": "setAuthenticationPhoneNumber", "phone_number": askPhoneNumber()])) { break codeLoop }
            case "resend":
                if check(client.call(["@type": "resendAuthenticationCode",
                                      "reason": ["@type": "resendCodeReasonUserRequest"] as JSON])) { break codeLoop }
            default:
                if check(client.call(["@type": "checkAuthenticationCode", "code": answer])) { break codeLoop }
            }
        }
    case "authorizationStateWaitPassword":
        let hint = state["password_hint"] as? String ?? ""
        askUntilAccepted({ promptSecret("2FA password\(hint.isEmpty ? "" : " (hint: \(hint))"): ") }) {
            ["@type": "checkAuthenticationPassword", "password": $0]
        }
    case "authorizationStateWaitEmailAddress":
        askUntilAccepted({ prompt("Login email address: ") }) {
            ["@type": "setAuthenticationEmailAddress", "email_address": $0]
        }
    case "authorizationStateWaitEmailCode":
        askUntilAccepted({ prompt("Email code: ") }) {
            ["@type": "checkAuthenticationEmailCode",
             "code": ["@type": "emailAddressAuthenticationCode", "code": $0] as JSON]
        }
    case "authorizationStateWaitOtherDeviceConfirmation":
        print("Confirm this login on another device: \(state["link"] ?? "")")
    case "authorizationStateWaitRegistration":
        print("This phone number has no Telegram account. Sign up in an official Telegram app first.")
        client.send(["@type": "close"])
    case "authorizationStateWaitPremiumPurchase":
        print("Telegram requires a Premium purchase to log in with this number; not supported here.")
        client.send(["@type": "close"])
    case "authorizationStateReady":
        break authorization
    case let other:
        print("Authorization state: \(other)")
    }
}

// MARK: - Commands

let me = client.call(["@type": "getMe"])
print("Logged in as \(me["first_name"] ?? "") \(me["last_name"] ?? "") (id \(me["id"] ?? "?"))")

let help = """
Commands:
  me                        Show the current user
  chats [limit]             List chats from the main list (default 20)
  history <chat_id> [limit] Show recent messages (default 20)
  send <chat_id> <text>     Send a text message
  logout                    Log out and delete the local session
  quit                      Close TDLib and exit (also Ctrl-C / Ctrl-D)
"""
print(help)

func listChats(limit: Int) {
    let chatList: JSON = ["@type": "chatListMain"]
    // Returns 404 once every chat is already loaded; that's fine.
    _ = client.call(["@type": "loadChats", "chat_list": chatList, "limit": limit])
    let chats = client.call(["@type": "getChats", "chat_list": chatList, "limit": limit])
    guard check(chats) else { return }
    for id in chats["chat_ids"] as? [Int] ?? [] {
        let chat = client.call(["@type": "getChat", "chat_id": id])
        let unread = chat["unread_count"] as? Int ?? 0
        print("\(id)\t\(chat["title"] as? String ?? "")" + (unread > 0 ? "  (\(unread) unread)" : ""))
    }
}

func showHistory(chatId: Int, limit: Int) {
    // getChatHistory may return fewer messages than asked, so page until we have enough.
    var messages: [JSON] = []
    var fromId = 0
    while messages.count < limit {
        let response = client.call([
            "@type": "getChatHistory", "chat_id": chatId, "from_message_id": fromId,
            "offset": 0, "limit": limit - messages.count, "only_local": false,
        ])
        guard check(response) else { return }
        let page = response["messages"] as? [JSON] ?? []
        guard let last = page.last, let lastId = last["id"] as? Int else { break }
        messages += page
        fromId = lastId
    }
    print("— \(title(for: chatId)) —")
    for message in messages.reversed() { print(describe(message: message)) }
}

func sendText(chatId: Int, text: String) {
    let response = client.call([
        "@type": "sendMessage", "chat_id": chatId,
        "input_message_content": [
            "@type": "inputMessageText",
            "text": ["@type": "formattedText", "text": text] as JSON,
        ] as JSON,
    ])
    if check(response) { print("Queued message \(response["id"] ?? "?")") }
}

while true {
    print("> ", terminator: "")
    fflush(stdout)
    guard let line = readLine() else { closeAndWait() }
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
    guard let command = parts.first else { continue }
    let args = Array(parts.dropFirst())

    switch command {
    case "me":
        let user = client.call(["@type": "getMe"])
        if check(user) {
            let username = ((user["usernames"] as? JSON)?["active_usernames"] as? [String])?.first.map { "@\($0)" } ?? "-"
            print("\(user["first_name"] ?? "") \(user["last_name"] ?? "")  id=\(user["id"] ?? "?")  username=\(username)  phone=+\(user["phone_number"] ?? "")")
        }
    case "chats":
        listChats(limit: args.first.flatMap(Int.init) ?? 20)
    case "history":
        guard let chatId = args.first.flatMap(Int.init) else { print("usage: history <chat_id> [limit]"); continue }
        showHistory(chatId: chatId, limit: args.dropFirst().first.flatMap(Int.init) ?? 20)
    case "send":
        guard args.count == 2, let chatId = Int(args[0]) else { print("usage: send <chat_id> <text>"); continue }
        sendText(chatId: chatId, text: args[1])
    case "logout":
        client.send(["@type": "logOut"])
        waitForClose()
    case "quit", "exit":
        closeAndWait()
    case "help":
        print(help)
    default:
        print("Unknown command. Type 'help'.")
    }
}
