import Cocoa

/// One chat's timeline and composer. Used by a standalone chat window.
final class ConversationViewController: NSViewController {
    let chatID: Int64
    let services: AccountServices
    let model: ConversationModel

    private var observations: [StoreObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private(set) var items: [TimelineItem] = []
    private var orderedMessages: [Message] = []
    private var messageIndex: [Int64: Int] = [:]
    private var rowModels: [Int64: MessageRowModel] = [:]
    private var layouts: [Int64: MessageLayout] = [:]
    private var layoutWidth: CGFloat = 0
    private var layoutHeight: CGFloat = 0
    /// Whether the user was at the latest message before a resize; kept current while scrolling.
    private var pinnedToBottom = true
    private var replyingTo: Int64?
    private var unseenCount = 0
    private var scrollToBottomOnNextReload = true
    private var viewReport: DispatchWorkItem?
    private var attachments: [AttachmentItem] = []
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private let tray = AttachmentTrayView()

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let composer = ComposerView()
    private let replyBar = ReplyBarView()
    private let readOnlyLabel = Controls.secondaryLabel("", size: NSFont.systemFontSize, lines: 2)
    private let bottomStack = NSStackView()
    private let newMessagesButton = NSButton(title: "", target: nil, action: nil)
    private let loadingSpinner = NSProgressIndicator()

    let media: ConversationMediaController
    private var mediaRenderer: MediaRendering? { media }

    init(chatID: Int64, services: AccountServices) {
        self.chatID = chatID
        self.services = services
        model = ConversationModel(chatID: chatID, services: services)
        media = ConversationMediaController(services: services)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        let root = DropTargetView(frame: NSRect(x: 0, y: 0, width: 440, height: 640))
        root.acceptsDrops = { [weak self] in self?.canAttach ?? false }
        root.onDropFiles = { [weak self] urls in self?.addFiles(urls) }
        root.onDropImage = { [weak self] data in self?.addImage(data) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.setAccessibilityLabel("Messages")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let separator = NSBox()
        separator.boxType = .separator
        replyBar.isHidden = true
        replyBar.onClose = { [weak self] in self?.setReply(nil) }
        readOnlyLabel.alignment = .center
        readOnlyLabel.isHidden = true
        let readOnlyContainer = NSView()
        readOnlyContainer.addSubview(readOnlyLabel)
        readOnlyLabel.pin(to: readOnlyContainer, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        bottomStack.orientation = .vertical
        bottomStack.spacing = 0
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        tray.isHidden = true
        tray.onRemove = { [weak self] id in self?.removeAttachment(id) }
        for view in [separator, replyBar, tray, composer, readOnlyContainer] {
            bottomStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
        }
        readOnlyContainer.isHidden = true

        newMessagesButton.bezelStyle = .push
        newMessagesButton.controlSize = .small
        newMessagesButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        newMessagesButton.imagePosition = .imageLeading
        newMessagesButton.target = self
        newMessagesButton.action = #selector(jumpToBottom)
        newMessagesButton.isHidden = true
        newMessagesButton.translatesAutoresizingMaskIntoConstraints = false

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        for view in [scrollView, bottomStack, newMessagesButton, loadingSpinner] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            newMessagesButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            newMessagesButton.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),
            loadingSpinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            loadingSpinner.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 10),
        ])
        view = root
        self.readOnlyContainer = readOnlyContainer
    }

    private var readOnlyContainer: NSView?

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.text = services.drafts.draft(for: chatID)
        composer.onSend = { [weak self] text in self?.send(text) }
        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            services.drafts.setDraft(text, for: chatID)
        }
        composer.onEscape = { [weak self] in self?.setReply(nil) }
        composer.onAttach = { [weak self] in self?.chooseFiles() }
        composer.onPaste = { [weak self] pasteboard in self?.paste(from: pasteboard) ?? false }
        model.onReplyLoaded = { [weak self] in self?.invalidateAll() }

        observations.append(services.store.observe { [weak self] change in self?.storeChanged(change) })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.didScroll() } })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleViewReport() } })

        updateComposerAvailability()
        model.open()
        loadingSpinner.startAnimation(nil)
        Task { [weak self] in
            await self?.model.loadInitial()
            self?.loadingSpinner.stopAnimation(nil)
            self?.scrollToBottomOnNextReload = true
            self?.reloadTimeline()
        }
        reloadTimeline()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        composer.focus()
        media.hostWindow = view.window
        if let window = view.window {
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleViewReport() } })
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleViewReport() } })
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.bounds.width
        let height = scrollView.bounds.height
        let widthChanged = abs(width - layoutWidth) > 0.5
        guard widthChanged || abs(height - layoutHeight) > 0.5 else { return }
        let wasAtBottom = pinnedToBottom
        let anchor = wasAtBottom ? nil : captureAnchor()
        layoutHeight = height
        if widthChanged {
            layoutWidth = width
            layouts.removeAll()
            // Cells hold frames computed for the old width, so rebuild them rather than only re-measuring.
            tableView.reloadData()
        }
        alignShortContentToBottom()
        if wasAtBottom { scrollToBottom() } else if let anchor { restore(anchor) }
    }

    /// Called by the window when it closes.
    func tearDown() {
        services.drafts.setDraft(composer.text, for: chatID)
        services.drafts.flush()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        observations.removeAll()
        mediaRenderer?.tearDown()
        for task in preparations.values { task.cancel() }
        services.staging.discard(attachments.compactMap(\.prepared).flatMap(\.allPaths))
        attachments.removeAll()
        model.close()
    }

    // MARK: Store changes

    private func storeChanged(_ change: StoreChange) {
        switch change {
        case .messagesAdded(let chatID, let ids) where chatID == self.chatID:
            let lastBefore = orderedMessages.last?.id ?? 0
            let newAtBottom = ids.filter { $0 > lastBefore }
            let incoming = newAtBottom.filter { model.message($0)?.isOutgoing == false }.count
            if newAtBottom.contains(where: { model.message($0)?.isOutgoing == true }) { scrollToBottomOnNextReload = true }
            if incoming > 0, !isNearBottom, !scrollToBottomOnNextReload { unseenCount += incoming }
            reloadTimeline()
        case .messageChanged(let chatID, let id) where chatID == self.chatID:
            invalidate([id])
            reloadTimeline()
        case .messageReplaced(let chatID, let old, let new) where chatID == self.chatID:
            invalidate([old, new])
            if replyingTo == old { replyingTo = new }
            reloadTimeline()
        case .messagesRemoved(let chatID, let ids) where chatID == self.chatID:
            invalidate(ids)
            if let replyingTo, ids.contains(replyingTo) { setReply(nil) }
            reloadTimeline()
        case .chat(let chatID) where chatID == self.chatID:
            // Read-outbox changes alter delivery ticks on every outgoing message.
            invalidateAll()
            updateComposerAvailability()
        case .basicGroup, .supergroup:
            updateComposerAvailability()
        case .file(let fileID):
            mediaRenderer?.fileChanged(fileID)
        default:
            break
        }
    }

    private func invalidate(_ ids: [Int64]) {
        for id in ids {
            rowModels[id] = nil
            layouts[id] = nil
        }
    }

    private func invalidateAll() {
        rowModels.removeAll()
        layouts.removeAll()
        reloadTimeline()
    }

    // MARK: Timeline

    private func reloadTimeline() {
        let atBottom = scrollToBottomOnNextReload || isNearBottom
        let anchor = atBottom ? nil : captureAnchor()
        orderedMessages = model.messages
        messageIndex = Dictionary(uniqueKeysWithValues: orderedMessages.enumerated().map { ($1.id, $0) })
        // Grouping depends on the previous message, which may have changed.
        for (index, message) in orderedMessages.enumerated() {
            if let cached = rowModels[message.id] {
                let previous = index > 0 ? orderedMessages[index - 1] : nil
                if cached.continuesGroup != TimelineBuilder.continuesGroup(message, after: previous) {
                    invalidate([message.id])
                }
            }
        }
        items = TimelineBuilder.items(for: orderedMessages)
        tableView.reloadData()
        alignShortContentToBottom()
        if atBottom {
            scrollToBottom()
            scrollToBottomOnNextReload = false
            unseenCount = 0
        } else if let anchor {
            restore(anchor)
        }
        updateNewMessagesButton()
        scheduleViewReport()
    }

    func rowModel(for id: Int64) -> MessageRowModel? {
        if let cached = rowModels[id] { return cached }
        guard let index = messageIndex[id] else { return nil }
        let message = orderedMessages[index]
        let previous = index > 0 ? orderedMessages[index - 1] : nil
        let built = MessageRowFactory(services: services, model: model).make(message, previous: previous)
        rowModels[id] = built
        return built
    }

    func layout(for id: Int64) -> MessageLayout? {
        if let cached = layouts[id] { return cached }
        guard let row = rowModel(for: id) else { return nil }
        let layout = MessageLayout(model: row, width: max(layoutWidth, 200))
        layouts[id] = layout
        return layout
    }

    // MARK: Scrolling

    private struct Anchor {
        let item: TimelineItem
        let offset: CGFloat
    }

    var isNearBottom: Bool {
        let clip = scrollView.contentView.bounds
        return clip.maxY >= tableView.frame.height - 48
    }

    private func captureAnchor() -> Anchor? {
        let clip = scrollView.contentView.bounds
        let rows = tableView.rows(in: clip)
        guard rows.length > 0 else { return nil }
        for row in rows.location..<min(NSMaxRange(rows), items.count) {
            if case .message = items[row] {
                return Anchor(item: items[row], offset: tableView.rect(ofRow: row).minY - clip.minY)
            }
        }
        return nil
    }

    private func restore(_ anchor: Anchor) {
        guard let row = items.firstIndex(of: anchor.item) else { return }
        let y = tableView.rect(ofRow: row).minY - anchor.offset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(-scrollView.contentInsets.top, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// A conversation shorter than the window sits just above the composer, not at the top.
    private func alignShortContentToBottom() {
        tableView.layoutSubtreeIfNeeded()
        let bottom: CGFloat = 8
        let available = scrollView.bounds.height - bottom
        // The table stretches to fill the clip view; measure the rows instead.
        let contentHeight = items.isEmpty ? 0 : tableView.rect(ofRow: items.count - 1).maxY
        let top = max(6, available - contentHeight)
        if abs(scrollView.contentInsets.top - top) > 0.5 {
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
    }

    func scrollToBottom() {
        tableView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let y = max(-scrollView.contentInsets.top, tableView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        pinnedToBottom = true
    }

    @objc private func jumpToBottom() {
        unseenCount = 0
        scrollToBottom()
        updateNewMessagesButton()
    }

    private func didScroll() {
        pinnedToBottom = isNearBottom
        if isNearBottom, unseenCount > 0 {
            unseenCount = 0
        }
        updateNewMessagesButton()
        scheduleViewReport()
        mediaRenderer?.visibleRowsChanged()
        if scrollView.contentView.bounds.minY < 400, model.didLoadInitial, !model.reachedStart, !model.isLoadingOlder {
            loadingSpinner.startAnimation(nil)
            Task { [weak self] in
                await self?.model.loadOlder()
                self?.loadingSpinner.stopAnimation(nil)
            }
        }
    }

    private func updateNewMessagesButton() {
        let show = !isNearBottom && (unseenCount > 0 || tableView.frame.height - scrollView.contentView.bounds.maxY > 1_500)
        newMessagesButton.isHidden = !show
        newMessagesButton.title = unseenCount > 0 ? (unseenCount == 1 ? "1 new message" : "\(unseenCount) new messages") : "Latest"
    }

    // MARK: Read reporting

    private func scheduleViewReport() {
        viewReport?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reportVisibleMessages() }
        viewReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Marks visible messages read, but only when the user can actually see them.
    private func reportVisibleMessages() {
        guard NSApp.isActive, let window = view.window, window.isKeyWindow,
              window.occlusionState.contains(.visible), !window.isMiniaturized, model.didLoadInitial else { return }
        let rows = tableView.rows(in: scrollView.contentView.bounds)
        guard rows.length > 0 else { return }
        let ids = (rows.location..<min(NSMaxRange(rows), items.count)).compactMap { row -> Int64? in
            if case .message(let id) = items[row] { return id }
            return nil
        }
        model.markViewed(ids)
    }

    // MARK: Composer

    private func updateComposerAvailability() {
        guard let chat = model.chat else { return }
        let policy = services.policy
        let canSend = policy.canSendMessages(in: chat)
        composer.allowsAttachments = policy.canSendMedia(in: chat)
        composer.isHidden = !canSend
        readOnlyContainer?.isHidden = canSend
        readOnlyLabel.isHidden = canSend
        if !canSend {
            readOnlyLabel.stringValue = policy.isSelected(chatID)
                ? "You can't send messages in this chat."
                : "This chat is no longer picked."
            setReply(nil)
        }
    }

    private func send(_ text: String) {
        if !attachments.isEmpty {
            sendAttachments(text: text)
            return
        }
        guard !text.isEmpty else { return }
        let replyID = replyingTo
        composer.text = ""
        setReply(nil)
        services.drafts.setDraft("", for: chatID)
        scrollToBottomOnNextReload = true
        Task { [weak self] in
            do {
                try await self?.model.sendText(text, replyTo: replyID)
            } catch {
                guard let self else { return }
                // Nothing was queued; give the text back.
                if composer.text.isEmpty { composer.text = text }
                showSendError(error)
            }
        }
    }

    // MARK: Attachments

    private var canAttach: Bool {
        guard let chat = model.chat else { return false }
        return !composer.isHidden && services.policy.canSendMedia(in: chat)
    }

    private func chooseFiles() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    /// Files or images on the pasteboard become attachments; text pastes normally.
    private func paste(from pasteboard: NSPasteboard) -> Bool {
        guard canAttach else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addFiles(urls)
            return true
        }
        if pasteboard.string(forType: .string) == nil, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            addImage(data)
            return true
        }
        return false
    }

    func addFiles(_ urls: [URL]) {
        let directory = services.staging.directory
        for url in urls {
            startPreparation(name: url.lastPathComponent) {
                try await AttachmentPreparer.prepare(source: url, stagingDirectory: directory)
            }
        }
        composer.focus()
    }

    private func addImage(_ data: Data) {
        let directory = services.staging.directory
        startPreparation(name: "Pasted Image") {
            try await AttachmentPreparer.prepare(imageData: data, stagingDirectory: directory)
        }
    }

    private func startPreparation(name: String, _ work: @escaping @Sendable () async throws -> PreparedAttachment) {
        let id = UUID()
        attachments.append(AttachmentItem(id: id, name: name, state: .preparing))
        preparations[id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { try await work() }.result
            guard let self else {
                if case .success(let prepared) = result { for path in prepared.allPaths { try? FileManager.default.removeItem(atPath: path) } }
                return
            }
            preparations[id] = nil
            guard let index = attachments.firstIndex(where: { $0.id == id }) else {
                // Removed while preparing.
                if case .success(let prepared) = result { services.staging.discard(prepared.allPaths) }
                return
            }
            switch result {
            case .success(let prepared): attachments[index].state = .ready(prepared)
            case .failure(let error): attachments[index].state = .failed(ErrorText.describe(error))
            }
            updateTray()
        }
        updateTray()
    }

    private func removeAttachment(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        preparations[id]?.cancel()
        if let prepared = attachments[index].prepared { services.staging.discard(prepared.allPaths) }
        attachments.remove(at: index)
        updateTray()
    }

    private func updateTray() {
        tray.isHidden = attachments.isEmpty
        tray.update(attachments, images: services.images)
        let preparing = attachments.contains { if case .preparing = $0.state { return true } else { return false } }
        composer.blocksSending = preparing
        composer.hasAttachments = attachments.contains { $0.prepared != nil }
    }

    /// Submits the tray. Items that failed preparation stay behind so the user sees them.
    private func sendAttachments(text: String) {
        let ready = attachments.compactMap(\.prepared)
        guard !ready.isEmpty else { return }
        let asFiles = tray.sendAsFiles
        let replyID = replyingTo
        attachments.removeAll { $0.prepared != nil }
        updateTray()
        composer.text = ""
        setReply(nil)
        services.drafts.setDraft("", for: chatID)
        scrollToBottomOnNextReload = true
        Task { [weak self, services] in
            do {
                try await self?.model.sendAttachments(ready, text: text, asFiles: asFiles, replyTo: replyID)
            } catch {
                // Files of messages TDLib accepted are tracked; the rest are released.
                services.staging.discard(ready.flatMap(\.allPaths))
                self?.showSendError(error)
            }
        }
    }

    func setReply(_ messageID: Int64?) {
        replyingTo = messageID
        guard let messageID, let message = model.message(messageID) else {
            replyBar.isHidden = true
            return
        }
        replyBar.configure(title: "Reply to \(services.presentation.senderName(message.senderID))",
                           text: ChatPresentation.summary(of: message.content))
        replyBar.isHidden = false
        composer.focus()
    }

    func showSendError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't send the message"
        alert.informativeText = ErrorText.describe(error)
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Context menu actions

    private func clickedMessage() -> Message? {
        let row = tableView.clickedRow
        guard items.indices.contains(row), case .message(let id) = items[row] else { return nil }
        return model.message(id)
    }

    @objc private func replyToClicked() {
        if let message = clickedMessage() { setReply(message.id) }
    }

    @objc private func copyClicked() {
        guard let message = clickedMessage(), let row = rowModel(for: message.id) else { return }
        let cell = tableView.view(atColumn: 0, row: tableView.clickedRow, makeIfNecessary: false) as? MessageCellView
        var text = row.text?.string ?? ""
        if let selection = cell?.textView.selectedRange(), selection.length > 0 {
            text = (text as NSString).substring(with: selection)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func retryClicked() {
        if let message = clickedMessage() { model.retry(message.id) }
    }

    @objc private func deleteClicked() {
        if let message = clickedMessage() { model.deleteLocally(message.id) }
    }
}

extension ConversationViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .day: 32
        case .message(let id): layout(for: id)?.rowHeight ?? 24
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .day(let date):
            let identifier = NSUserInterfaceItemIdentifier("Day")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DaySeparatorView ?? {
                let view = DaySeparatorView()
                view.identifier = identifier
                return view
            }()
            cell.configure(RelativeTime.dayTitle(date))
            return cell
        case .message(let id):
            guard let model = rowModel(for: id), let layout = layout(for: id) else { return nil }
            if let mediaRenderer, let cell = mediaRenderer.cell(for: model, layout: layout, in: tableView) {
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("Message")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageCellView
                ?? MessageCellView(identifier: identifier)
            cell.mediaController = media
            cell.configure(model, layout: layout)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

extension ConversationViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let message = clickedMessage(), let row = rowModel(for: message.id), !row.isService else { return }
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if case .failed(_, let canRetry) = message.sendingState {
            if canRetry { add("Retry Sending", #selector(retryClicked)) }
            add("Delete", #selector(deleteClicked))
            menu.addItem(.separator())
        }
        if !composer.isHidden, message.sendingState == nil { add("Reply", #selector(replyToClicked)) }
        if let text = row.text?.string, !text.isEmpty { add("Copy Text", #selector(copyClicked)) }
        mediaRenderer?.addMenuItems(to: menu, for: message)
    }
}

/// Hooks the media layer (M5/M6) plugs into the timeline.
protocol MediaRendering: AnyObject {
    func cell(for model: MessageRowModel, layout: MessageLayout, in tableView: NSTableView) -> NSView?
    func fileChanged(_ fileID: Int32)
    func visibleRowsChanged()
    func addMenuItems(to menu: NSMenu, for message: Message)
    func tearDown()
}

/// Banner above the composer while replying.
final class ReplyBarView: NSView {
    var onClose: () -> Void = {}
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 12, weight: .semibold), color: .controlAccentColor)
    private let textLabel = Controls.secondaryLabel(size: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: "Reply") ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let labels = Controls.stack([titleLabel, textLabel], spacing: 1, alignment: .leading)
        let close = Controls.symbolButton("xmark.circle.fill", accessibility: "Cancel Reply", target: self, action: #selector(closeTapped))
        close.contentTintColor = .tertiaryLabelColor
        let row = Controls.stack([icon, labels, NSView(), close], orientation: .horizontal, spacing: 10)
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 6, left: 14, bottom: 2, right: 12))
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, text: String) {
        titleLabel.stringValue = title
        textLabel.stringValue = text
    }

    @objc private func closeTapped() { onClose() }
}
