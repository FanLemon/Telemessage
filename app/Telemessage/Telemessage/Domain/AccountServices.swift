import Foundation

/// Services shared by every window of a signed-in account.
final class AccountServices {
    let session: TelegramSession
    let storage: AccountStorage?
    let selection: SelectionStore
    let files: FileService
    let images = ImageLoader()
    let windowState: WindowStateStore
    let drafts: DraftStore
    let staging: StagingStore

    var store: TelegramStore { session.store }
    var policy: SelectionPolicy { SelectionPolicy(selection: selection, store: store) }
    var presentation: ChatPresentation { ChatPresentation(store: store) }

    /// `storage == nil` keeps app state in memory (snapshots, tests).
    init(session: TelegramSession, storage: AccountStorage?) {
        self.session = session
        self.storage = storage
        selection = SelectionStore(url: storage?.appFile("selection.json"))
        files = FileService(session: session)
        windowState = WindowStateStore(url: storage?.appFile("windows.json"))
        let draftsKey = storage.flatMap { try? DatabaseKeyStore.key(for: $0.draftsKeyName) }
        drafts = DraftStore(url: draftsKey == nil ? nil : storage?.appFile("drafts.bin"), keyData: draftsKey)
        staging = StagingStore(
            directory: storage?.stagingDirectory ?? FileManager.default.temporaryDirectory.appending(path: "TelemessageStaging"),
            manifestURL: storage?.appFile("staging.json"))
    }
}
