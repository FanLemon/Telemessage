import Cocoa

/// The compact main window. Closing it leaves chat windows and the app running.
final class MainWindowController: NSWindowController {
    let listController: ChatListViewController
    private let services: AccountServices
    private var observation: StoreObservation?

    init(services: AccountServices, actions: ChatListViewController.Actions) {
        self.services = services
        listController = ChatListViewController(services: services, actions: actions)
        let window = NSWindow(contentViewController: listController)
        window.title = "Telemessage"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 320, height: 520))
        window.minSize = NSSize(width: 260, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        super.init(window: window)
        observation = services.store.observe { [weak self] change in
            if change == .connectionState { self?.updateSubtitle() }
        }
        updateSubtitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateSubtitle() {
        window?.subtitle = Self.connectionText(services.store.connectionState) ?? ""
    }

    /// Short connection status, or nil when connected.
    static func connectionText(_ state: ConnectionState) -> String? {
        switch state {
        case .waitingForNetwork: "Waiting for network…"
        case .connectingToProxy: "Connecting to proxy…"
        case .connecting: "Connecting…"
        case .updating: "Updating…"
        case .ready, .unknown: nil
        }
    }
}
