import Cocoa

/// The compact list of picked chats, in the user's manual order.
final class ChatListViewController: NSViewController {
    struct Actions {
        var openChat: (Int64) -> Void = { _ in }
        var chooseChats: () -> Void = {}
        var showSettings: () -> Void = {}
    }

    private let services: AccountServices
    private let actions: Actions
    private var observations: [StoreObservation] = []
    private var rows: [Int64] = []
    private var query = ""

    private let searchField = NSSearchField()
    private let tableView = ChatTableView()
    private let scrollView = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyTitle = Controls.label(font: .systemFont(ofSize: 15, weight: .semibold))
    private let emptyMessage = Controls.secondaryLabel(size: NSFont.systemFontSize, lines: 0)
    private let emptyButton = Controls.button("Choose Chats…", target: nil, action: #selector(chooseChats))

    private static let rowType = NSPasteboard.PasteboardType("com.farsonic.telemessage.chat-row")

    init(services: AccountServices, actions: Actions) {
        self.services = services
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let addButton = Controls.symbolButton("square.and.pencil", accessibility: "Choose Chats", target: self, action: #selector(chooseChats))
        addButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let header = Controls.stack([searchField, addButton], orientation: .horizontal, spacing: 8)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.style = .fullWidth
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedChat)
        tableView.onReturn = { [weak self] in self?.openSelectedChat() }
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.menu = makeContextMenu()
        tableView.setAccessibilityLabel("Picked chats")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let manageButton = Controls.linkButton("Manage Chats", target: self, action: #selector(chooseChats))
        let settingsButton = Controls.symbolButton("gearshape", accessibility: "Settings", target: self, action: #selector(showSettings))
        let footer = Controls.stack([manageButton, NSView(), settingsButton], orientation: .horizontal)

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitle.alignment = .center
        emptyMessage.alignment = .center
        emptyButton.target = self
        [emptyIcon, emptyTitle, emptyMessage, emptyButton].forEach(emptyView.addArrangedSubview)
        emptyView.orientation = .vertical
        emptyView.spacing = 10
        emptyView.setCustomSpacing(16, after: emptyMessage)
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        [header, scrollView, separator, footer, emptyView].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            emptyView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            emptyMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observations.append(services.selection.observe { [weak self] in self?.reload() })
        observations.append(services.store.observe { [weak self] change in self?.storeChanged(change) })
        reload()
    }

    // MARK: Data

    private func reload() {
        let presentation = services.presentation
        let selected = services.selection.chatIDs
        let needle = query.lowercased()
        rows = needle.isEmpty ? selected : selected.filter { presentation.title(of: $0).lowercased().contains(needle) }
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let noSelection = services.selection.entries.isEmpty
        emptyView.isHidden = !rows.isEmpty
        emptyButton.isHidden = !noSelection
        if noSelection {
            emptyTitle.stringValue = "No Chats Yet"
            emptyMessage.stringValue = "Pick the people and groups you want to keep an eye on."
        } else {
            emptyTitle.stringValue = "No Results"
            emptyMessage.stringValue = "No picked chat matches “\(query)”."
        }
    }

    private func storeChanged(_ change: StoreChange) {
        switch change {
        case .chat(let chatID):
            reloadRow(for: chatID)
        case .user(let userID):
            // A private chat's id equals its user's id.
            reloadRow(for: userID)
        case .file(let fileID):
            for (index, chatID) in rows.enumerated() where services.store.chats[chatID]?.photo?.small.id == fileID {
                tableView.reloadData(forRowIndexes: [index], columnIndexes: [0])
            }
        case .myUserID:
            tableView.reloadData()
        default:
            break
        }
    }

    private func reloadRow(for chatID: Int64) {
        guard let index = rows.firstIndex(of: chatID) else { return }
        if !query.isEmpty {
            reload()
        } else {
            tableView.reloadData(forRowIndexes: [index], columnIndexes: [0])
        }
    }

    // MARK: Actions

    @objc private func searchChanged() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        reload()
    }

    @objc private func chooseChats() { actions.chooseChats() }
    @objc private func showSettings() { actions.showSettings() }

    @objc private func openClickedChat() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        actions.openChat(rows[row])
    }

    private func openSelectedChat() {
        for row in tableView.selectedRowIndexes where rows.indices.contains(row) {
            actions.openChat(rows[row])
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openClickedChat), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Telemessage", action: #selector(removeClickedChat), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func removeClickedChat() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        services.selection.remove(rows[row])
    }
}

extension ChatListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ChatRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChatRowView ?? ChatRowView(identifier: identifier)
        cell.configure(chatID: rows[row], services: services)
        return cell
    }

    // Manual reordering by drag; disabled while filtering since rows are then a subset.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard query.isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, info.draggingSource as? NSTableView === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        var source = IndexSet()
        info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self]) { item, _, _ in
            if let string = (item.item as? NSPasteboardItem)?.string(forType: Self.rowType), let index = Int(string) {
                source.insert(index)
            }
        }
        guard !source.isEmpty else { return false }
        services.selection.move(from: source, to: row)
        return true
    }
}

/// Table that opens the selected chat on Return.
final class ChatTableView: NSTableView {
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {  // Return, keypad Enter
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One picked chat: avatar, title, last message, time and unread count.
final class ChatRowView: NSTableCellView {
    private let avatar = AvatarView(size: 40)
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 13, weight: .semibold))
    private let previewLabel = Controls.secondaryLabel(size: 12)
    private let timeLabel = Controls.secondaryLabel(size: 11)
    private let mutedIcon = NSImageView(image: NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: "Muted") ?? NSImage())
    private let badge = BadgeView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        mutedIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        mutedIcon.contentTintColor = .tertiaryLabelColor
        mutedIcon.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.alignment = .right
        for view in [avatar, titleLabel, previewLabel, timeLabel, mutedIcon, badge] { addSubview(view) }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            mutedIcon.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            mutedIcon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: mutedIcon.trailingAnchor, constant: 6),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: previewLabel.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(chatID: Int64, services: AccountServices) {
        let presentation = services.presentation
        guard let chat = services.store.chats[chatID] else {
            titleLabel.stringValue = "Loading…"
            previewLabel.stringValue = ""
            timeLabel.stringValue = ""
            badge.count = 0
            mutedIcon.isHidden = true
            avatar.configure(title: "", accentColorID: 5, small: nil, minithumbnail: nil, services: services)
            return
        }
        let title = presentation.title(of: chat)
        let muted = presentation.isMuted(chat)
        titleLabel.stringValue = title
        previewLabel.stringValue = presentation.preview(of: chat)
        timeLabel.stringValue = chat.lastMessage.map {
            RelativeTime.listLabel(Date(timeIntervalSince1970: TimeInterval($0.date)))
        } ?? ""
        mutedIcon.isHidden = !muted
        badge.isMuted = muted
        badge.count = chat.unreadCount
        avatar.configure(chat: chat, services: services)
        setAccessibilityLabel(chat.unreadCount > 0 ? "\(title), \(chat.unreadCount) unread" : title)
    }
}
