import Cocoa

final class LoginWindowController: NSWindowController {
    let session: TelegramSession

    init(session: TelegramSession) {
        self.session = session
        let window = NSWindow(contentViewController: LoginViewController(session: session))
        window.title = "Sign In"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 440, height: 540))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
