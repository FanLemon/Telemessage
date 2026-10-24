import Cocoa
import CoreImage.CIFilterBuiltins

/// Sign-in flow driven by TDLib's authorization state; one screen per state.
final class LoginViewController: NSViewController {
    /// What the screen shows. Derived from the authorization state, except `phone` can be forced
    /// by "Change Number" while TDLib still waits for a code or password.
    enum Step: Equatable {
        case connecting
        case phone(canCancel: Bool)
        case qr(link: String)
        case code(AuthenticationCodeInfo)
        case password(AuthorizationState.PasswordInfo)
        case emailAddress
        case emailCode(AuthorizationState.EmailCodeInfo)
        case unsupported(title: String, message: String)

        init(_ state: AuthorizationState?) {
            switch state {
            case .waitPhoneNumber: self = .phone(canCancel: false)
            case .waitOtherDeviceConfirmation(let link): self = .qr(link: link)
            case .waitCode(let info): self = .code(info)
            case .waitPassword(let info): self = .password(info)
            case .waitEmailAddress: self = .emailAddress
            case .waitEmailCode(let info): self = .emailCode(info)
            case .waitRegistration:
                self = .unsupported(title: "No Telegram Account",
                                    message: "This phone number isn't registered with Telegram. Create an account in an official Telegram app first, then sign in here.")
            case .waitPremiumPurchase:
                self = .unsupported(title: "Telegram Premium Required",
                                    message: "Telegram requires a Premium subscription to sign in with this number. Purchase it in an official Telegram app first.")
            case .unknown(let name):
                self = .unsupported(title: "Sign-In Step Not Supported",
                                    message: "Telegram asked for a sign-in step this app doesn't support yet (\(name)). Sign in with another number or an official app.")
            case nil, .waitTdlibParameters, .ready, .loggingOut, .closing, .closed:
                self = .connecting
            }
        }
    }

    private let session: TelegramSession
    private var observation: StoreObservation?
    private var step: Step = .connecting
    private var wantsPhoneEntry = false
    private var isBusy = false
    private var resendTimer: Timer?
    private var resendAvailableAt: Date?

    private let iconView = NSImageView()
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 22, weight: .semibold))
    private let messageLabel = Controls.secondaryLabel(size: NSFont.systemFontSize, lines: 0)
    private let inputContainer = Controls.stack([], spacing: 8, alignment: .centerX)
    private let errorLabel = Controls.label(color: .systemRed, lines: 0)
    private let primaryButton = Controls.button("Next", target: nil, action: #selector(submit))
    private let spinner = NSProgressIndicator()
    private let secondaryStack = Controls.stack([], spacing: 6, alignment: .centerX)
    private var field: NSTextField?
    private var resendButton: NSButton?

    init(session: TelegramSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 540))

        iconView.image = NSImage(systemSymbolName: "paperplane.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .regular))
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
        ])
        titleLabel.alignment = .center
        messageLabel.alignment = .center
        errorLabel.alignment = .center
        errorLabel.isHidden = true

        primaryButton.target = self
        primaryButton.keyEquivalent = "\r"
        primaryButton.controlSize = .large
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = Controls.stack([iconView, titleLabel, messageLabel, inputContainer, errorLabel, primaryButton, secondaryStack],
                                   spacing: 14, alignment: .centerX)
        stack.setCustomSpacing(20, after: iconView)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.setCustomSpacing(18, after: primaryButton)
        root.addSubview(stack)
        // The spinner sits beside the button so the button stays centered.
        root.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: primaryButton.trailingAnchor, constant: 10),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = session.store.observe { [weak self] change in
            if change == .authorizationState { self?.stateDidChange() }
        }
        stateDidChange()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusField()
    }

    // MARK: Rendering

    private func stateDidChange() {
        wantsPhoneEntry = false
        render(Step(session.store.authorizationState))
    }

    private func render(_ newStep: Step) {
        guard newStep != step || field == nil else { return }
        step = newStep
        showError(nil)
        inputContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        secondaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        field = nil
        resendButton = nil
        resendTimer?.invalidate()
        primaryButton.isHidden = false
        primaryButton.title = "Next"

        switch newStep {
        case .connecting:
            titleLabel.stringValue = "Telemessage"
            messageLabel.stringValue = "Connecting to Telegram…"
            primaryButton.isHidden = true
            spinner.startAnimation(nil)

        case .phone(let canCancel):
            titleLabel.stringValue = "Sign In to Telegram"
            messageLabel.stringValue = "Enter your phone number with the country code."
            addField(placeholder: "+81 90 1234 5678")
            addLink("Log In with QR Code", #selector(requestQRCode))
            if canCancel { addLink("Cancel", #selector(cancelPhoneEntry)) }

        case .qr(let link):
            titleLabel.stringValue = "Scan with Telegram"
            messageLabel.stringValue = "On your phone, open Telegram › Settings › Devices › Link Desktop Device, then scan this code."
            inputContainer.addArrangedSubview(qrView(for: link))
            primaryButton.isHidden = true
            addLink("Use Phone Number Instead", #selector(leaveQRLogin))

        case .code(let info):
            titleLabel.stringValue = "Enter Code"
            messageLabel.stringValue = Self.codeMessage(info)
            addField(placeholder: info.type.length.map { String(repeating: "–", count: Int($0)) } ?? "Code", centered: true)
            if info.nextType != nil {
                resendAvailableAt = Date(timeIntervalSinceNow: TimeInterval(info.timeout))
                resendButton = addLink("Resend Code", #selector(resendCode))
                startResendCountdown()
            }
            addLink("Change Number", #selector(changeNumber))

        case .password(let info):
            titleLabel.stringValue = "Two-Step Verification"
            messageLabel.stringValue = info.passwordHint.isEmpty
                ? "Your account is protected with an additional password."
                : "Your account is protected with an additional password.\nHint: \(info.passwordHint)"
            addField(placeholder: "Password", secure: true)
            addLink("Change Number", #selector(changeNumber))

        case .emailAddress:
            titleLabel.stringValue = "Add Login Email"
            messageLabel.stringValue = "Telegram asks for an email address to protect this account."
            addField(placeholder: "name@example.com")
            addLink("Change Number", #selector(changeNumber))

        case .emailCode(let info):
            titleLabel.stringValue = "Check Your Email"
            messageLabel.stringValue = "Enter the code sent to \(info.emailAddressPattern)."
            addField(placeholder: "Code", centered: true)
            addLink("Change Number", #selector(changeNumber))

        case .unsupported(let title, let message):
            titleLabel.stringValue = title
            messageLabel.stringValue = message
            primaryButton.title = "Use Another Number"
        }
        if newStep != .connecting { spinner.stopAnimation(nil) }
        setBusy(false)
        focusField()
    }

    @discardableResult
    private func addField(placeholder: String, secure: Bool = false, centered: Bool = false) -> NSTextField {
        let field = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 16)
        field.alignment = centered ? .center : .natural
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        field.delegate = self
        inputContainer.addArrangedSubview(field)
        self.field = field
        return field
    }

    @discardableResult
    private func addLink(_ title: String, _ action: Selector) -> NSButton {
        let button = Controls.linkButton(title, target: self, action: action)
        secondaryStack.addArrangedSubview(button)
        return button
    }

    private func focusField() {
        if let field { view.window?.makeFirstResponder(field) }
    }

    private func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        primaryButton.isEnabled = !busy
        field?.isEnabled = !busy
        secondaryStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = !busy }
        if busy { spinner.startAnimation(nil) } else if step != .connecting { spinner.stopAnimation(nil) }
        if !busy { updateResendButton() }
    }

    static func codeMessage(_ info: AuthenticationCodeInfo) -> String {
        let phone = info.phoneNumber
        switch info.type.name {
        case "TelegramMessage": return "We sent the code to the Telegram app on your other device."
        case "Sms", "SmsWord", "SmsPhrase": return "We sent the code by SMS to \(phone)."
        case "Call": return "We're calling \(phone) to dictate the code."
        case "FlashCall", "MissedCall": return "We're calling \(phone). The code is the last digits of the calling number."
        case "Fragment": return "Get the code for \(phone) on fragment.com."
        default: return "Enter the code sent to \(phone)."
        }
    }

    // MARK: QR

    /// The code on a white card; the padding doubles as the quiet zone scanners need.
    private func qrView(for link: String) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 10
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.image)
        card.setAccessibilityLabel("Login QR code")
        let imageView = NSImageView(image: Self.qrImage(for: link) ?? NSImage())
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        card.addSubview(imageView)
        imageView.pin(to: card, insets: .all(14))
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 208),
            card.heightAnchor.constraint(equalToConstant: 208),
        ])
        return card
    }

    static func qrImage(for link: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: code)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Actions

    @objc private func submit() {
        guard !isBusy else { return }
        let text = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch step {
        case .connecting, .qr:
            return
        case .unsupported:
            changeNumber()
            return
        case .phone:
            let phone = text.filter { $0.isNumber || $0 == "+" }
            guard !phone.isEmpty else { return showError("Enter your phone number.") }
            perform(SetAuthenticationPhoneNumber(phoneNumber: phone))
        case .code:
            guard !text.isEmpty else { return }
            perform(CheckAuthenticationCode(code: text))
        case .password:
            guard !text.isEmpty else { return }
            perform(CheckAuthenticationPassword(password: text))
        case .emailAddress:
            guard !text.isEmpty else { return }
            perform(SetAuthenticationEmailAddress(emailAddress: text))
        case .emailCode:
            guard !text.isEmpty else { return }
            perform(CheckAuthenticationEmailCode(code: text))
        }
    }

    /// Sends an authorization request. Success shows up as a new authorization state.
    private func perform<Request: TDRequest>(_ request: Request) {
        setBusy(true)
        showError(nil)
        Task {
            do {
                _ = try await session.send(request)
                setBusy(false)
                if wantsPhoneEntry { stateDidChange() }
            } catch {
                setBusy(false)
                showError(ErrorText.describe(error))
                field?.selectText(nil)
            }
        }
    }

    @objc private func requestQRCode() {
        perform(RequestQrCodeAuthentication())
    }

    /// TDLib cannot return from QR login to phone entry, so the half-finished login is discarded;
    /// the coordinator starts a fresh session at the phone step.
    @objc private func leaveQRLogin() {
        perform(LogOut())
    }

    @objc private func changeNumber() {
        wantsPhoneEntry = true
        render(.phone(canCancel: true))
    }

    @objc private func cancelPhoneEntry() {
        stateDidChange()
    }

    @objc private func resendCode() {
        perform(ResendAuthenticationCode())
    }

    private func startResendCountdown() {
        updateResendButton()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateResendButton() }
        }
    }

    private func updateResendButton() {
        guard let resendButton, let resendAvailableAt else { return }
        let remaining = Int(resendAvailableAt.timeIntervalSinceNow.rounded(.up))
        if remaining > 0 {
            resendButton.title = "Resend Code in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
            resendButton.isEnabled = false
        } else {
            resendButton.title = "Resend Code"
            resendButton.isEnabled = !isBusy
            resendTimer?.invalidate()
        }
    }
}

extension LoginViewController: NSTextFieldDelegate {
    /// Submits a login code automatically once it has the expected length.
    func controlTextDidChange(_ notification: Notification) {
        guard case .code(let info) = step, let length = info.type.length, let field,
              field.stringValue.filter(\.isNumber).count == Int(length) else { return }
        submit()
    }
}
