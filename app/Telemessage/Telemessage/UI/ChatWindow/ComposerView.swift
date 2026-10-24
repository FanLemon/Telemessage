import Cocoa

/// Plain-text message input. Return sends, Shift- or Option-Return inserts a newline, and Return
/// never sends while an input method is still composing.
final class ComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    /// Return false to let the default paste run (plain text).
    var onPaste: (NSPasteboard) -> Bool = { _ in false }
    var placeholder = "Message" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return
        }
        if event.keyCode == 53, !hasMarkedText() {  // Escape
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if !onPaste(.general) { pasteAsPlainText(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? MessageText.bodyFont, .foregroundColor: NSColor.placeholderTextColor]
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// Composer row: attach button, growing text view (1–6 lines) and send button.
final class ComposerView: NSView, NSTextViewDelegate {
    var onSend: (String) -> Void = { _ in }
    var onTextChange: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onAttach: () -> Void = {}
    var onPaste: (NSPasteboard) -> Bool = { _ in false } { didSet { textView.onPaste = onPaste } }
    /// Attachments can make an empty text sendable.
    var hasAttachments = false { didSet { updateSendButton() } }
    var isEnabled = true { didSet { updateSendButton(); textView.isEditable = isEnabled } }
    /// Attachments are still being prepared; nothing may be sent yet.
    var blocksSending = false { didSet { updateSendButton() } }
    var allowsAttachments = true { didSet { attachButton.isHidden = !allowsAttachments } }

    let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private let attachButton = Controls.symbolButton("paperclip", accessibility: "Attach Files", target: nil, action: #selector(attach))
    private let sendButton = Controls.symbolButton("arrow.up.circle.fill", accessibility: "Send", target: nil, action: #selector(send))
    private var heightConstraint: NSLayoutConstraint!

    private static let minHeight: CGFloat = 30
    private static let maxHeight: CGFloat = 120

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textChanged()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = MessageText.bodyFont
        textView.textContainerInset = NSSize(width: 4, height: 7)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.send() }
        textView.onEscape = { [weak self] in self?.onEscape() }
        textView.setAccessibilityLabel("Message")
        // Dropped files become attachments (handled by the window), not pasted paths.
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.string])

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let field = RoundedFieldView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(scrollView)
        scrollView.pin(to: field, insets: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))

        attachButton.target = self
        sendButton.target = self
        sendButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        sendButton.contentTintColor = .controlAccentColor
        attachButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        attachButton.contentTintColor = .secondaryLabelColor

        for view in [attachButton, field, sendButton] { addSubview(view) }
        heightConstraint = field.heightAnchor.constraint(equalToConstant: Self.minHeight)
        NSLayoutConstraint.activate([
            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            attachButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -6),
            field.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 8),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightConstraint,
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -3),
        ])
        updateSendButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    private func textChanged() {
        updateHeight()
        updateSendButton()
        onTextChange(textView.string)
    }

    private func updateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let content = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        heightConstraint.constant = min(max(ceil(content), Self.minHeight), Self.maxHeight)
    }

    private func updateSendButton() {
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = isEnabled && !blocksSending && (hasText || hasAttachments)
        sendButton.alphaValue = sendButton.isEnabled ? 1 : 0.4
    }

    @objc private func send() {
        guard isEnabled, !blocksSending else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || hasAttachments else { return }
        onSend(text)
    }

    @objc private func attach() { onAttach() }
}

/// The composer's rounded input background.
final class RoundedFieldView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
