import Cocoa
import os

/// Owns the Telegram session and routes between sign-in and the signed-in windows.
///
/// A session ends at authorizationStateClosed. After a logout or a session revoked elsewhere
/// (both pass through loggingOut) the account's local data is removed and a fresh session starts
/// at the sign-in screen. Quitting closes the session without logging out.
@MainActor
final class AppCoordinator {
    private let storage = AccountStorage()
    private(set) var session: TelegramSession?
    private(set) var account: AccountContext?
    private var sessionObservation: StoreObservation?
    private var loginWindowController: LoginWindowController?
    private var sawLoggingOut = false
    private let notificationPoster = UserNotificationPoster()
    private var isTerminating = false

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "App")

    var isSignedIn: Bool { account != nil }

    func start() {
        startSession()
    }

    // MARK: Session lifecycle

    private func startSession() {
        let secrets: TelegramSecrets
        let databaseKey: Data
        do {
            secrets = try TelegramSecrets.load().get()
            databaseKey = try DatabaseKeyStore.key(for: storage.name)
            try storage.ensure(storage.root)
        } catch {
            presentStartupError(error)
            return
        }
        let configuration = TelegramSession.Configuration(
            secrets: secrets,
            dataDirectory: storage.root,
            databaseKey: databaseKey,
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )
        let session = TelegramSession(transport: TDJsonTransport(), configuration: configuration)
        sawLoggingOut = false
        sessionObservation = session.store.observe { [weak self] change in
            if change == .authorizationState { self?.route() }
        }
        self.session = session
        session.start()
    }

    private func route() {
        guard let session, let state = session.store.authorizationState else { return }
        switch state {
        case .waitTdlibParameters, .closing:
            break
        case .ready:
            closeLogin()
            if account == nil {
                let account = AccountContext(session: session, storage: storage, coordinator: self, poster: notificationPoster)
                self.account = account
                account.start()
            }
        case .loggingOut:
            sawLoggingOut = true
            endAccount()
        case .closed:
            endAccount()
            closeLogin()
            sessionObservation = nil
            self.session = nil
            guard !isTerminating else { return }
            if sawLoggingOut {
                // TDLib destroyed its database during logout; remove the app's account data too.
                storage.removeAll()
            }
            startSession()
        default:
            endAccount()
            showLogin(for: session)
        }
    }

    private func endAccount() {
        account?.end()
        account = nil
    }

    // MARK: Windows

    private func showLogin(for session: TelegramSession) {
        if loginWindowController?.session !== session {
            loginWindowController?.close()
            loginWindowController = LoginWindowController(session: session)
        }
        loginWindowController?.showWindow(nil)
    }

    private func closeLogin() {
        loginWindowController?.close()
        loginWindowController = nil
    }

    /// Dock icon clicked with no visible windows.
    func reopen() {
        if let account {
            account.showMainWindow()
        } else if let session {
            showLogin(for: session)
        }
    }

    // MARK: Commands

    func confirmLogOut() {
        guard let session, account != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Log out of Telegram?"
        alert.informativeText = "Your picked chats, drafts and downloaded media on this Mac will be removed. Your Telegram account and messages are not affected."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.post(LogOut())
    }

    /// Closes TDLib before the app exits; returns when it is safe to terminate.
    func prepareForTermination() async {
        isTerminating = true
        account?.saveState()
        await session?.close()
    }

    private func presentStartupError(_ error: any Error) {
        Self.logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Telemessage can't start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
