import Cocoa

final class SettingsViewController: NSViewController {
    struct Actions {
        var logOut: () -> Void = {}
        /// Asks macOS for notification permission; returns whether it was granted.
        var requestNotificationPermission: () async -> Bool = { true }
    }

    private let services: AccountServices
    private let settings: AppSettings
    private let actions: Actions
    private var observation: StoreObservation?

    private let notificationsBox = NSButton(checkboxWithTitle: "Show notifications for picked chats", target: nil, action: nil)
    private let previewsBox = NSButton(checkboxWithTitle: "Show message text in notifications", target: nil, action: nil)
    private let notificationNote = Controls.secondaryLabel("Notifications appear only while Telemessage is running. Muted chats stay silent.",
                                                           size: 11, lines: 0)
    private let photosBox = NSButton(checkboxWithTitle: "Download photos automatically", target: nil, action: nil)
    private let storageLabel = Controls.label("Downloaded media: calculating…")
    private let clearButton = Controls.button("Clear Downloads", target: nil, action: #selector(clearDownloads))
    private let avatar = AvatarView(size: 40)
    private let nameLabel = Controls.label(font: .systemFont(ofSize: 13, weight: .semibold))
    private let phoneLabel = Controls.secondaryLabel(size: 12)

    init(services: AccountServices, settings: AppSettings = .shared, actions: Actions) {
        self.services = services
        self.settings = settings
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        for box in [notificationsBox, previewsBox, photosBox] {
            box.target = self
            box.action = #selector(toggled(_:))
        }
        clearButton.target = self
        let logOut = Controls.button("Log Out…", target: self, action: #selector(logOutTapped))

        let notifications = section("Notifications", [notificationsBox, indent(previewsBox), indent(notificationNote)])
        let media = section("Media", [photosBox, Controls.stack([storageLabel, NSView(), clearButton], orientation: .horizontal)])
        let account = section("Account", [Controls.stack([avatar, Controls.stack([nameLabel, phoneLabel], spacing: 2, alignment: .leading),
                                                          NSView(), logOut], orientation: .horizontal, spacing: 12)])
        let stack = Controls.stack([notifications, separator(), media, separator(), account], spacing: 16, alignment: .leading)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = services.store.observe { [weak self] change in
            switch change {
            case .myUserID, .user, .file: self?.refreshAccount()
            default: break
            }
        }
        refresh()
        refreshAccount()
        refreshStorage()
    }

    private func refresh() {
        notificationsBox.state = settings.notificationsEnabled ? .on : .off
        previewsBox.state = settings.notificationPreviews ? .on : .off
        previewsBox.isEnabled = settings.notificationsEnabled
        photosBox.state = settings.autoDownloadPhotos ? .on : .off
    }

    private func refreshAccount() {
        guard let id = services.store.myUserID, let user = services.store.users[id] else {
            nameLabel.stringValue = "Signed in"
            return
        }
        nameLabel.stringValue = user.fullName
        phoneLabel.stringValue = user.phoneNumber.isEmpty ? "" : "+\(user.phoneNumber)"
        avatar.configure(user: user, services: services)
    }

    private func refreshStorage() {
        Task { [weak self, services] in
            let stats = try? await services.session.send(GetStorageStatisticsFast())
            self?.storageLabel.stringValue = "Downloaded media: \(MediaFiles.size(stats?.filesSize ?? 0))"
        }
    }

    // MARK: Actions

    @objc private func toggled(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case notificationsBox where on:
            Task { [weak self] in
                guard let self else { return }
                let granted = await actions.requestNotificationPermission()
                settings.notificationsEnabled = granted
                notificationNote.stringValue = granted
                    ? "Notifications appear only while Telemessage is running. Muted chats stay silent."
                    : "Allow notifications for Telemessage in System Settings › Notifications."
                notificationNote.textColor = granted ? .secondaryLabelColor : .systemOrange
                refresh()
            }
        case notificationsBox:
            settings.notificationsEnabled = false
        case previewsBox:
            settings.notificationPreviews = on
        case photosBox:
            settings.autoDownloadPhotos = on
        default:
            break
        }
        refresh()
    }

    @objc private func clearDownloads() {
        clearButton.isEnabled = false
        Task { [weak self, services] in
            _ = try? await services.session.send(OptimizeStorage())
            self?.clearButton.isEnabled = true
            self?.refreshStorage()
        }
    }

    @objc private func logOutTapped() {
        actions.logOut()
    }

    // MARK: Layout helpers

    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let header = Controls.label(title, font: .systemFont(ofSize: 13, weight: .semibold))
        let stack = Controls.stack([header] + rows, spacing: 8, alignment: .leading)
        for row in rows { row.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        if let last = rows.last as? NSStackView, last.orientation == .horizontal {
            last.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func indent(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 380),
        ])
        return container
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

final class SettingsWindowController: NSWindowController {
    init(services: AccountServices, actions: SettingsViewController.Actions) {
        let controller = SettingsViewController(services: services, actions: actions)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.view.fittingSize)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
