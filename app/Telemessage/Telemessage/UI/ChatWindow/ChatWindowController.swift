import Cocoa

/// A standalone window for one chat. Ordinary window level unless "Keep on Top" is on.
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let chatID: Int64
    let conversation: ConversationViewController
    private let services: AccountServices
    private let onClose: (Int64) -> Void
    private var observation: StoreObservation?
    private var statusTimer: Timer?
    private let pinButton = NSButton()

    static let defaultSize = NSSize(width: 440, height: 640)
    static let minimumSize = NSSize(width: 340, height: 420)

    init(chatID: Int64, services: AccountServices, onClose: @escaping (Int64) -> Void) {
        self.chatID = chatID
        self.services = services
        self.onClose = onClose
        conversation = ConversationViewController(chatID: chatID, services: services)
        let window = NSWindow(contentViewController: conversation)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("chat-\(chatID)")
        super.init(window: window)
        window.delegate = self

        let state = services.windowState.state(for: chatID)
        if let frame = state.frame {
            window.setFrame(NSRectFromString(frame), display: false)
        }
        setKeepOnTop(state.keepOnTop)
        installPinAccessory()

        observation = services.store.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .chat(let id) where id == chatID: refreshTitle()
            case .user(let id) where id == chatID: refreshTitle()
            case .basicGroup, .supergroup, .connectionState: refreshTitle()
            default: break
            }
        }
        // "last seen 5 minutes ago" goes stale.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var keepsOnTop: Bool { window?.level == .floating }

    private func refreshTitle() {
        guard let window else { return }
        let presentation = services.presentation
        window.title = presentation.title(of: chatID)
        // While offline, the connection state matters more than "last seen".
        window.subtitle = MainWindowController.connectionText(services.store.connectionState)
            ?? services.store.chats[chatID].map { presentation.subtitle(for: $0) } ?? ""
    }

    private func installPinAccessory() {
        pinButton.bezelStyle = .accessoryBarAction
        pinButton.isBordered = false
        pinButton.setButtonType(.toggle)
        pinButton.target = self
        pinButton.action = #selector(toggleKeepOnTop(_:))
        updatePinButton()
        let accessory = NSTitlebarAccessoryViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        pinButton.frame = NSRect(x: 4, y: 2, width: 26, height: 24)
        container.addSubview(pinButton)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    private func updatePinButton() {
        let on = keepsOnTop
        pinButton.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin", accessibilityDescription: "Keep on Top")
        pinButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        pinButton.state = on ? .on : .off
        pinButton.toolTip = on ? "Stop keeping this window on top" : "Keep this window on top"
        pinButton.setAccessibilityLabel("Keep on Top")
    }

    private func setKeepOnTop(_ on: Bool) {
        window?.level = on ? .floating : .normal
        // Floating chat windows should follow the user across Spaces like a utility panel.
        window?.collectionBehavior = on ? [.managed, .fullScreenAuxiliary] : [.managed]
    }

    @objc func toggleKeepOnTop(_ sender: Any?) {
        let on = !keepsOnTop
        setKeepOnTop(on)
        services.windowState.update(chatID) { $0.keepOnTop = on }
        updatePinButton()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleKeepOnTop(_:)) {
            menuItem.state = keepsOnTop ? .on : .off
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        services.windowState.update(chatID) { $0.frame = NSStringFromRect(frame) }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        observation = nil
        saveFrame()
        conversation.tearDown()
        onClose(chatID)
    }
}
