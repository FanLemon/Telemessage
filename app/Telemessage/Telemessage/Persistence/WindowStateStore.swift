import Foundation

/// Which chat windows are open, plus each chat window's frame and keep-on-top preference.
final class WindowStateStore {
    nonisolated struct ChatWindowState: Codable, Equatable, Sendable {
        var frame: String?
        var keepOnTop = false
    }

    private nonisolated struct Document: Codable {
        var version = 1
        var openChatIDs: [Int64] = []
        var windows: [String: ChatWindowState] = [:]
    }

    private var document: Document
    private let url: URL?
    private var pendingSave: DispatchWorkItem?

    init(url: URL?) {
        self.url = url
        document = url.flatMap { JSONFileStore.load(Document.self, from: $0) } ?? Document()
    }

    var openChatIDs: [Int64] { document.openChatIDs }

    func state(for chatID: Int64) -> ChatWindowState {
        document.windows[String(chatID)] ?? ChatWindowState()
    }

    func update(_ chatID: Int64, _ body: (inout ChatWindowState) -> Void) {
        var state = state(for: chatID)
        body(&state)
        document.windows[String(chatID)] = state
        scheduleSave()
    }

    func setOpenChatIDs(_ chatIDs: [Int64]) {
        guard document.openChatIDs != chatIDs else { return }
        document.openChatIDs = chatIDs
        scheduleSave()
    }

    /// Drops everything remembered about a chat that is no longer picked.
    func forget(_ chatID: Int64) {
        document.windows[String(chatID)] = nil
        document.openChatIDs.removeAll { $0 == chatID }
        scheduleSave()
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        if let url { try? JSONFileStore.save(document, to: url) }
    }

    private func scheduleSave() {
        guard url != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
