import Cocoa

/// Builds and updates media views for one conversation, and performs media actions.
final class ConversationMediaController: MediaRendering {
    let services: AccountServices
    weak var hostWindow: NSWindow?
    private let views = NSHashTable<MediaContentView>.weakObjects()
    /// Actions to run once a user-requested download completes.
    private var pendingActions: [Int32: (String) -> Void] = [:]

    init(services: AccountServices) {
        self.services = services
    }

    /// A media view for `model`, reusing `existing` when it is of the right kind.
    func mediaView(for model: MessageRowModel, reusing existing: NSView?) -> NSView? {
        guard let kind = model.media?.kind else { return nil }
        let make: () -> MediaContentView = switch kind {
        case .photo: { PhotoMediaView(frame: .zero) }
        case .video: { VideoMediaView(frame: .zero) }
        case .animation: { AnimationMediaView(frame: .zero) }
        case .sticker: { StickerMediaView(frame: .zero) }
        case .videoNote: { VideoNoteMediaView(frame: .zero) }
        case .card: { FileCardView(frame: .zero) }
        }
        let view: MediaContentView
        if let existing = existing as? MediaContentView, Self.kind(of: existing) == kind {
            view = existing
        } else {
            view = make()
            view.controller = self
            views.add(view)
        }
        view.configure(model)
        return view
    }

    private static func kind(of view: MediaContentView) -> MediaSpec.Kind? {
        switch view {
        case is PhotoMediaView: .photo
        case is VideoMediaView: .video
        case is AnimationMediaView: .animation
        case is StickerMediaView: .sticker
        case is VideoNoteMediaView: .videoNote
        case is FileCardView: .card
        default: nil
        }
    }

    // MARK: MediaRendering

    func cell(for model: MessageRowModel, layout: MessageLayout, in tableView: NSTableView) -> NSView? { nil }

    func fileChanged(_ fileID: Int32) {
        for view in views.allObjects where view.watchedFileIDs.contains(fileID) {
            view.refresh()
        }
        if let action = pendingActions[fileID], let path = services.store.files[fileID]?.completedPath {
            pendingActions[fileID] = nil
            action(path)
        }
    }

    func visibleRowsChanged() {
        for view in views.allObjects { view.visibilityChanged() }
    }

    func addMenuItems(to menu: NSMenu, for message: Message) {
        guard let file = Self.primaryFile(of: message.content) else { return }
        let path = services.files.localPath(file)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if case .photo = message.content {
            menu.addItem(item("Open Photo", #selector(openPhotoItem(_:)), message))
        }
        if let path {
            if !MediaFiles.isPotentiallyExecutable(URL(fileURLWithPath: path)) {
                menu.addItem(item("Open", #selector(openFileItem(_:)), path))
            }
            menu.addItem(item("Show in Finder", #selector(revealItem(_:)), path))
        } else {
            menu.addItem(item("Download", #selector(downloadItem(_:)), file))
        }
    }

    func tearDown() {
        for view in views.allObjects { view.stopPlayback() }
        pendingActions.removeAll()
    }

    // MARK: Actions

    /// Runs `action` with the file's path, downloading it first at user priority.
    func whenDownloaded(_ file: TDFile, _ action: @escaping (String) -> Void) {
        if let path = services.files.localPath(file) {
            action(path)
            return
        }
        pendingActions[file.id] = action
        services.files.download(file, priority: .requested)
    }

    /// Stops an upload by deleting the message still being sent.
    func cancelSending(_ message: Message) {
        services.session.post(DeleteMessages(chatID: message.chatID, messageIDs: [message.id], revoke: true))
    }

    func cancelDownload(_ file: TDFile) {
        pendingActions[file.id] = nil
        services.files.cancel(file)
    }

    func openPhoto(_ message: Message) {
        guard case .photo(let photo, _) = message.content else { return }
        let title = "\(services.presentation.senderName(message.senderID)) · "
            + Date(timeIntervalSince1970: TimeInterval(message.date)).formatted(date: .abbreviated, time: .shortened)
        MediaViewers.shared.showPhoto(photo, title: title, services: services)
    }

    func playVideo(path: String, size: CGSize) {
        MediaViewers.shared.playVideo(path: path, naturalSize: size)
    }

    func reportUnplayable(path: String) {
        let alert = NSAlert()
        alert.messageText = "This audio format can't be played here"
        alert.informativeText = "Show the file in Finder to open it with another app."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { MediaFiles.reveal(path) }
        }
        if let hostWindow { alert.beginSheetModal(for: hostWindow, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    static func primaryFile(of content: MessageContent) -> TDFile? {
        switch content {
        case .photo(let photo, _): MediaFiles.largestSize(of: photo)?.photo
        case .video(let video, _): video.video
        case .animation(let animation, _): animation.animation
        case .sticker(let sticker): sticker.sticker
        case .document(let document, _): document.document
        case .voiceNote(let voice, _): voice.voice
        case .audio(let audio, _): audio.audio
        case .videoNote(let note): note.video
        case .text, .unsupported: nil
        }
    }

    private func item(_ title: String, _ action: Selector, _ object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func openPhotoItem(_ sender: NSMenuItem) {
        if let message = sender.representedObject as? Message { openPhoto(message) }
    }

    @objc private func openFileItem(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { MediaFiles.open(path) }
    }

    @objc private func revealItem(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { MediaFiles.reveal(path) }
    }

    @objc private func downloadItem(_ sender: NSMenuItem) {
        if let file = sender.representedObject as? TDFile { services.files.download(file, priority: .requested) }
    }
}

