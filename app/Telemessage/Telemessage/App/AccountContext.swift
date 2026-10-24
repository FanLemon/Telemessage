import Cocoa
import os

/// Everything that exists while an account is signed in. Created at authorizationStateReady and
/// ended on logout, revocation or quit; ending closes every account window.
@MainActor
final class AccountContext {
    let services: AccountServices
    private unowned let coordinator: AppCoordinator
    private var mainWindowController: MainWindowController?
    private var pickerWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
    let chatWindows: ChatWindowCoordinator
    private let poster: UserNotificationPoster
    private var attention: AttentionCoordinator?
    private let connectivity: ConnectivityMonitor
    private var observations: [StoreObservation] = []

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "Account")

    var session: TelegramSession { services.session }
    var store: TelegramStore { services.store }
    var selection: SelectionStore { services.selection }

    init(session: TelegramSession, storage: AccountStorage, coordinator: AppCoordinator, poster: UserNotificationPoster) {
        services = AccountServices(session: session, storage: storage)
        chatWindows = ChatWindowCoordinator(services: services)
        self.coordinator = coordinator
        self.poster = poster
        connectivity = ConnectivityMonitor(session: session)
    }

    func start() {
        observations.append(session.observeUpdates { [weak self] update in self?.handle(update) })
        observations.append(selection.observe { [weak self] in self?.selectionChanged() })
        loadSelectedChats()
        Task { [services] in await services.staging.reconcile(session: services.session) }
        connectivity.start()
        let attention = AttentionCoordinator(
            services: services, settings: .shared, poster: poster,
            isViewing: { [weak self] chatID in
                NSApp.isActive && self?.chatWindows.controller(for: chatID)?.window?.isKeyWindow == true
            },
            setBadge: { NSApp.dockTile.badgeLabel = $0 })
        attention.start()
        self.attention = attention
        poster.onOpenChat = { [weak self] chatID in self?.openFromNotification(chatID) }
        showMainWindow()
        chatWindows.restore()
        if selection.entries.isEmpty { showChatPicker() }
    }

    func end() {
        observations.removeAll()
        attention?.end()
        attention = nil
        connectivity.stop()
        poster.onOpenChat = { _ in }
        settingsWindowController?.close()
        settingsWindowController = nil
        MediaViewers.shared.closeAll()
        AudioPlayback.shared.stop()
        closePicker()
        chatWindows.closeAll()
        services.drafts.flush()
        mainWindowController?.close()
        mainWindowController = nil
    }

    func saveState() {
        services.windowState.setOpenChatIDs(chatWindows.openChatIDs.sorted())
        services.windowState.flush()
        services.drafts.flush()
    }

    // MARK: Windows

    func showMainWindow() {
        if mainWindowController == nil {
            var actions = ChatListViewController.Actions()
            actions.openChat = { [weak self] chatID in self?.openChat(chatID) }
            actions.chooseChats = { [weak self] in self?.showChatPicker() }
            actions.showSettings = { [weak self] in self?.showSettings() }
            mainWindowController = MainWindowController(services: services, actions: actions)
        }
        mainWindowController?.showWindow(nil)
    }

    func showChatPicker() {
        if let pickerWindow {
            pickerWindow.makeKeyAndOrderFront(nil)
            return
        }
        showMainWindow()
        guard let mainWindow = mainWindowController?.window else { return }
        let picker = ChatPickerViewController(services: services) { [weak self] in self?.closePicker() }
        let sheet = NSWindow(contentViewController: picker)
        sheet.setContentSize(NSSize(width: 480, height: 600))
        pickerWindow = sheet
        mainWindow.beginSheet(sheet)
    }

    private func closePicker() {
        guard let pickerWindow else { return }
        pickerWindow.sheetParent?.endSheet(pickerWindow)
        pickerWindow.orderOut(nil)
        self.pickerWindow = nil
    }

    func showSettings() {
        if settingsWindowController == nil {
            var actions = SettingsViewController.Actions()
            actions.logOut = { [weak self] in self?.coordinator.confirmLogOut() }
            actions.requestNotificationPermission = { [poster] in await poster.requestAuthorization() }
            settingsWindowController = SettingsWindowController(services: services, actions: actions)
        }
        settingsWindowController?.showWindow(nil)
    }

    /// A notification was clicked. The chat may have been unpicked since it was posted.
    private func openFromNotification(_ chatID: Int64) {
        NSApp.activate()
        if services.policy.canPresent(chatID) {
            chatWindows.open(chatID)
        } else {
            showMainWindow()
        }
    }

    func openChat(_ chatID: Int64) {
        chatWindows.open(chatID)
    }

    // MARK: Selection maintenance

    /// TDLib loads chats lazily; ask for every picked chat so the list can show it.
    private func loadSelectedChats() {
        for chatID in selection.chatIDs where store.chats[chatID] == nil {
            Task { [session] in
                do {
                    _ = try await session.send(GetChat(chatID: chatID))
                } catch {
                    Self.logger.error("Picked chat unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func selectionChanged() {
        loadSelectedChats()
        chatWindows.selectionChanged()
    }

    private func handle(_ update: Update) {
        switch update {
        case .basicGroup(let group) where group.upgradedToSupergroupID != 0:
            followMigration(of: group)
        case .messageSendSucceeded(let message, let oldMessageID):
            services.staging.messageReplaced(chatID: message.chatID, oldMessageID: oldMessageID, newMessageID: message.id, sent: true)
        case .messageSendFailed(let message, let oldMessageID, _):
            services.staging.messageReplaced(chatID: message.chatID, oldMessageID: oldMessageID, newMessageID: message.id, sent: false)
        case .deleteMessages(let chatID, let messageIDs, _, let fromCache) where !fromCache:
            services.staging.messagesDeleted(chatID: chatID, messageIDs: messageIDs)
        default:
            break
        }
    }

    /// A picked basic group that became a supergroup stays picked under its new chat.
    private func followMigration(of group: BasicGroup) {
        let migrated = selection.chatIDs.filter {
            if case .basicGroup(let id)? = store.chats[$0]?.type { return id == group.id }
            return false
        }
        for oldChatID in migrated {
            Task { [session, selection] in
                do {
                    let chat = try await session.send(CreateSupergroupChat(supergroupID: group.upgradedToSupergroupID))
                    selection.replaceChat(oldChatID, with: chat.id)
                } catch {
                    Self.logger.error("Following group migration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
