import Cocoa
import os

/// Sheet for choosing which chats Telemessage shows. Lists main and archived chats plus contacts
/// without a chat yet; nothing changes on Telegram's side.
final class ChatPickerViewController: NSViewController {
    struct Candidate: Equatable {
        /// For contacts without a chat this is the user id (a private chat's id equals its user's id).
        let chatID: Int64
        let contactUserID: Int64?
        let isArchived: Bool
    }

    private let services: AccountServices
    private let onFinish: () -> Void
    private var candidates: [Candidate] = []
    private var visible: [Candidate] = []
    private var checked: Set<Int64>
    private var contactUserIDs: [Int64] = []
    private var query = ""
    private var loadTask: Task<Void, Never>?
    private var observation: StoreObservation?
    private var reloadScheduled = false
    private var isSaving = false
    private var isLoading = false

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = Controls.secondaryLabel()
    private let spinner = NSProgressIndicator()
    private let saveButton = Controls.button("Save", target: nil, action: #selector(save))
    private let errorLabel = Controls.label(color: .systemRed, lines: 2)

    private static let logger = Logger(subsystem: "com.Farsonic.Telemessage", category: "ChatPicker")

    init(services: AccountServices, onFinish: @escaping () -> Void) {
        self.services = services
        self.onFinish = onFinish
        checked = Set(services.selection.chatIDs)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))

        let title = Controls.label("Choose Chats", font: .systemFont(ofSize: 17, weight: .semibold))
        let explanation = Controls.secondaryLabel(
            "Only the chats you pick appear in Telemessage. This doesn't change anything in Telegram.",
            size: NSFont.systemFontSize, lines: 0)

        searchField.placeholderString = "Search chats and contacts"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate")))
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let cancelButton = Controls.button("Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.keyEquivalent = "\r"
        errorLabel.isHidden = true
        let footer = Controls.stack([spinner, statusLabel, NSView(), cancelButton, saveButton], orientation: .horizontal, spacing: 8)

        let stack = Controls.stack([title, explanation, searchField, scrollView, errorLabel, footer], spacing: 10, alignment: .leading)
        root.addSubview(stack)
        stack.pin(to: root, insets: .all(20))
        for view in [explanation, searchField, scrollView, errorLabel, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = services.store.observe { [weak self] change in
            switch change {
            case .chat, .user, .file, .basicGroup, .supergroup: self?.scheduleReload(rebuild: false)
            default: break
            }
        }
        rebuild()
        load()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: Loading

    /// Pages through the main and archive lists (TDLib delivers the chats as updates), then contacts.
    private func load() {
        spinner.startAnimation(nil)
        isLoading = true
        loadTask = Task { [weak self, services] in
            for list in [ChatList.main, .archive] {
                for _ in 0..<50 {
                    do {
                        _ = try await services.session.send(LoadChats(chatList: list, limit: 100))
                    } catch {
                        // 404: the whole list is loaded.
                        if (error as? TDError)?.code != 404 {
                            Self.logger.error("loadChats failed: \(error.localizedDescription, privacy: .public)")
                        }
                        break
                    }
                    guard !Task.isCancelled else { return }
                    self?.rebuild()
                }
            }
            if let contacts = try? await services.session.send(GetContacts()) {
                self?.contactUserIDs = contacts.userIDs
            }
            self?.isLoading = false
            self?.rebuild()
            self?.spinner.stopAnimation(nil)
        }
    }

    private func rebuild() {
        let store = services.store
        var seen = Set<Int64>()
        var result: [Candidate] = []
        func add(_ chatID: Int64, contact: Int64? = nil, archived: Bool = false) {
            guard seen.insert(chatID).inserted else { return }
            result.append(Candidate(chatID: chatID, contactUserID: contact, isArchived: archived))
        }
        // Picked chats first so they are easy to find and remove.
        for chatID in services.selection.chatIDs { add(chatID, archived: store.chats[chatID]?.position(in: .archive) != nil) }
        for chatID in store.chatIDs(in: .main) { add(chatID) }
        for chatID in store.chatIDs(in: .archive) { add(chatID, archived: true) }
        let contacts = contactUserIDs
            .filter { !seen.contains($0) }
            .sorted { (store.users[$0]?.fullName ?? "") .localizedCaseInsensitiveCompare(store.users[$1]?.fullName ?? "") == .orderedAscending }
        for userID in contacts { add(userID, contact: userID) }
        candidates = result
        applyFilter()
    }

    private func scheduleReload(rebuild: Bool) {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            if rebuild { self.rebuild() } else { tableView.reloadData() }
        }
    }

    private func applyFilter() {
        let needle = query.lowercased()
        visible = needle.isEmpty ? candidates : candidates.filter { candidate in
            title(of: candidate).lowercased().contains(needle)
                || username(of: candidate).map { $0.lowercased().contains(needle) } == true
        }
        tableView.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        if !checked.isEmpty {
            statusLabel.stringValue = "\(checked.count) selected"
        } else {
            statusLabel.stringValue = isLoading ? "Loading chats…" : ""
        }
    }

    // MARK: Presentation

    fileprivate func title(of candidate: Candidate) -> String {
        if let userID = candidate.contactUserID, services.store.chats[candidate.chatID] == nil {
            return services.store.users[userID]?.fullName ?? "Contact"
        }
        return services.presentation.title(of: candidate.chatID)
    }

    private func username(of candidate: Candidate) -> String? {
        let store = services.store
        if case .private(let userID)? = store.chats[candidate.chatID]?.type {
            return store.users[userID]?.usernames?.activeUsernames.first
        }
        return candidate.contactUserID.flatMap { store.users[$0]?.usernames?.activeUsernames.first }
    }

    fileprivate func subtitle(of candidate: Candidate) -> (String, isSupported: Bool) {
        let store = services.store
        guard let chat = store.chats[candidate.chatID] else {
            return (candidate.contactUserID != nil ? "Contact" : "Loading…", true)
        }
        if case .unsupported(let reason) = services.policy.eligibility(of: chat) { return (reason, false) }
        var parts: [String] = []
        switch chat.type {
        case .private(let userID):
            let user = store.users[userID]
            parts.append(user?.type == .bot ? "Bot" : (user?.isContact == true ? "Contact" : "Person"))
        case .basicGroup, .supergroup:
            parts.append("Group")
            let members = services.presentation.subtitle(for: chat)
            if members != "group" { parts.append(members) }
        default:
            break
        }
        if candidate.isArchived { parts.append("Archived") }
        return (parts.joined(separator: " · "), true)
    }

    fileprivate func isChecked(_ candidate: Candidate) -> Bool { checked.contains(candidate.chatID) }

    fileprivate func configureAvatar(_ avatar: AvatarView, for candidate: Candidate) {
        if let chat = services.store.chats[candidate.chatID] {
            avatar.configure(chat: chat, services: services)
        } else if let userID = candidate.contactUserID, let user = services.store.users[userID] {
            avatar.configure(user: user, services: services)
        } else {
            avatar.configure(title: "?", accentColorID: 5, small: nil, minithumbnail: nil, services: services)
        }
    }

    fileprivate func toggle(_ candidate: Candidate) {
        if checked.contains(candidate.chatID) {
            checked.remove(candidate.chatID)
        } else if subtitle(of: candidate).isSupported {
            checked.insert(candidate.chatID)
        } else {
            return
        }
        if let row = visible.firstIndex(of: candidate) {
            tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
        updateStatus()
    }

    // MARK: Actions

    @objc private func searchChanged() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        applyFilter()
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard visible.indices.contains(row) else { return }
        toggle(visible[row])
    }

    @objc private func cancel() {
        loadTask?.cancel()
        onFinish()
    }

    @objc private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveButton.isEnabled = false
        errorLabel.isHidden = true
        spinner.startAnimation(nil)
        let ordered = candidates.filter { checked.contains($0.chatID) }
        Task {
            do {
                var chatIDs: [Int64] = []
                for candidate in ordered {
                    if services.store.chats[candidate.chatID] == nil, let userID = candidate.contactUserID {
                        chatIDs.append(try await services.session.send(CreatePrivateChat(userID: userID)).id)
                    } else {
                        chatIDs.append(candidate.chatID)
                    }
                }
                services.selection.replace(with: chatIDs)
                loadTask?.cancel()
                onFinish()
            } catch {
                isSaving = false
                saveButton.isEnabled = true
                spinner.stopAnimation(nil)
                errorLabel.stringValue = "Couldn't save: \(ErrorText.describe(error))"
                errorLabel.isHidden = false
            }
        }
    }
}

extension ChatPickerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PickerRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PickerRowView
            ?? PickerRowView(identifier: identifier, onToggle: { [weak self] candidate in self?.toggle(candidate) })
        cell.configure(visible[row], picker: self)
        return cell
    }
}

private final class PickerRowView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let avatar = AvatarView(size: 28)
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 13))
    private let subtitleLabel = Controls.secondaryLabel(size: 11)
    private let onToggle: (ChatPickerViewController.Candidate) -> Void
    private var candidate: ChatPickerViewController.Candidate?

    init(identifier: NSUserInterfaceItemIdentifier, onToggle: @escaping (ChatPickerViewController.Candidate) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let labels = Controls.stack([titleLabel, subtitleLabel], spacing: 1, alignment: .leading)
        for view in [checkbox, avatar, labels] { addSubview(view) }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ candidate: ChatPickerViewController.Candidate, picker: ChatPickerViewController) {
        self.candidate = candidate
        let title = picker.title(of: candidate)
        let (subtitle, isSupported) = picker.subtitle(of: candidate)
        let isChecked = picker.isChecked(candidate)
        titleLabel.stringValue = title
        titleLabel.textColor = isSupported ? .labelColor : .tertiaryLabelColor
        subtitleLabel.stringValue = subtitle
        checkbox.state = isChecked ? .on : .off
        // Unsupported chats can still be unchecked if they were picked earlier.
        checkbox.isEnabled = isSupported || isChecked
        checkbox.setAccessibilityLabel(title)
        picker.configureAvatar(avatar, for: candidate)
        avatar.alphaValue = isSupported ? 1 : 0.5
    }

    /// Mouse clicks anywhere in the row go to the table, which toggles the row; the checkbox
    /// action remains for keyboard and VoiceOver activation.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func toggled() {
        if let candidate { onToggle(candidate) }
    }
}
