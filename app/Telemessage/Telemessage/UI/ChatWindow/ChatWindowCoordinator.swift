import Cocoa
import os

/// Keeps one window per chat: reopening focuses the existing window. Only chats the selection
/// policy allows can get a window, including when restoring at launch.
final class ChatWindowCoordinator {
    private let services: AccountServices
    private var controllers: [Int64: ChatWindowController] = [:]
    /// While the account ends, windows close without being forgotten so they reopen next launch.
    private var isEnding = false

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "ChatWindows")

    init(services: AccountServices) {
        self.services = services
    }

    var openChatIDs: [Int64] { Array(controllers.keys) }

    func controller(for chatID: Int64) -> ChatWindowController? { controllers[chatID] }

    /// Opens or focuses the chat's window. `activate: false` restores without stealing focus.
    func open(_ chatID: Int64, activate: Bool = true) {
        if let existing = controllers[chatID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard services.policy.isSelected(chatID) else { return }
        guard services.store.chats[chatID] != nil else {
            // Not loaded yet (TDLib loads chats lazily); fetch, then try again.
            Task { [weak self, services] in
                do {
                    _ = try await services.session.send(GetChat(chatID: chatID))
                    self?.open(chatID, activate: activate)
                } catch {
                    Self.logger.error("Can't open chat: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        guard services.policy.canPresent(chatID) else { return }
        let controller = ChatWindowController(chatID: chatID, services: services) { [weak self] id in self?.windowClosed(id) }
        controllers[chatID] = controller
        if services.windowState.state(for: chatID).frame == nil { cascade(controller.window) }
        if activate {
            controller.showWindow(nil)
        } else {
            controller.window?.orderFront(nil)
        }
        persistOpenChats()
    }

    /// Reopens the windows that were open when the app last quit, if their chats are still picked.
    func restore() {
        for chatID in services.windowState.openChatIDs where services.policy.isSelected(chatID) {
            open(chatID, activate: false)
        }
    }

    /// Closes windows of chats that are no longer picked and forgets their window state.
    func selectionChanged() {
        for chatID in controllers.keys where !services.policy.isSelected(chatID) {
            controllers[chatID]?.close()
        }
        for chatID in services.windowState.openChatIDs where !services.policy.isSelected(chatID) {
            services.windowState.forget(chatID)
        }
    }

    /// Closes every window (account ending). The open list is kept for the next launch.
    func closeAll() {
        persistOpenChats()
        isEnding = true
        for controller in controllers.values { controller.close() }
        controllers.removeAll()
        services.windowState.flush()
        isEnding = false
    }

    private func windowClosed(_ chatID: Int64) {
        controllers[chatID] = nil
        guard !isEnding else { return }
        persistOpenChats()
    }

    private func persistOpenChats() {
        services.windowState.setOpenChatIDs(controllers.keys.sorted())
    }

    private func cascade(_ window: NSWindow?) {
        guard let window else { return }
        let offset = CGFloat(controllers.count - 1) * 24
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.midX - window.frame.width / 2 + 120 + offset,
                                                y: screen.maxY - 60 - offset))
        } else {
            window.center()
        }
    }
}
