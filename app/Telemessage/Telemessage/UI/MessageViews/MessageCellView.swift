import Cocoa

enum BubbleColors {
    static let outgoing = NSColor(name: "BubbleOutgoing") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.17, green: 0.35, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.92, blue: 1.00, alpha: 1)
    }
    static let incoming = NSColor(name: "BubbleIncoming") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.21, green: 0.21, blue: 0.23, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    }
    static let service = NSColor(name: "BubbleService") { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Rounded rectangle drawn in `draw(_:)` so snapshots and layer-less rendering match.
final class BubbleView: NSView {
    var color: NSColor = BubbleColors.incoming { didSet { needsDisplay = true } }
    var radius: CGFloat = 14 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: min(radius, bounds.height / 2), yRadius: min(radius, bounds.height / 2)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Selectable, link-aware message text; TextKit 1 with zero insets so `TextMeasure` matches.
final class MessageTextView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The row's context menu (Reply, Copy, …) instead of the text view's own.
    override func rightMouseDown(with event: NSEvent) {
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        if let table = view { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }
}

/// Quote bar, replied-to sender and a one-line summary.
final class ReplyPreviewView: NSView {
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 12, weight: .semibold))
    private let textLabel = Controls.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private var color = NSColor.controlAccentColor

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, textLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ reply: MessageRowModel.Reply) {
        color = reply.color
        titleLabel.stringValue = reply.title
        titleLabel.textColor = reply.color
        textLabel.stringValue = reply.text
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 8, y: 1, width: bounds.width - 8, height: 16)
        textLabel.frame = CGRect(x: 8, y: 17, width: bounds.width - 8, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Time and delivery state; a dark pill when it sits on top of media.
final class FooterView: NSView {
    var text = NSAttributedString() { didSet { needsDisplay = true } }
    var drawsPill = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if drawsPill {
            NSColor(white: 0, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let size = text.size()
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        } else {
            text.draw(at: .zero)
        }
    }
}

/// Stand-in for media until it is rendered: a tinted box with the kind's symbol.
final class MediaPlaceholderView: NSView {
    var symbol = "photo" { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 28, weight: .light)) {
                let tinted = icon.tinted(.tertiaryLabelColor)
                let size = tinted.size
                tinted.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSImage {
    /// A copy of a template symbol filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

/// A message bubble row. Frames come from `MessageLayout`; nothing here uses Auto Layout.
class MessageCellView: NSTableCellView {
    let bubble = BubbleView()
    let senderLabel = Controls.label(font: MessageLayout.senderFont)
    let replyView = ReplyPreviewView()
    let textView = MessageTextView()
    let footerView = FooterView()
    let mediaContainer = NSView()
    private(set) var layoutInfo: MessageLayout?
    private(set) var model: MessageRowModel?
    /// Builds real media views; without it media shows a placeholder.
    weak var mediaController: ConversationMediaController?

    override var isFlipped: Bool { true }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        senderLabel.translatesAutoresizingMaskIntoConstraints = true
        for view in [bubble, senderLabel, replyView, mediaContainer, textView, footerView] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: MessageRowModel, layout: MessageLayout) {
        self.model = model
        layoutInfo = layout
        bubble.isHidden = !layout.drawsBubble
        bubble.color = model.isService ? BubbleColors.service : (model.isOutgoing ? BubbleColors.outgoing : BubbleColors.incoming)
        bubble.radius = model.isService ? 10 : 14

        senderLabel.isHidden = layout.sender == nil
        senderLabel.stringValue = model.senderName ?? ""
        senderLabel.textColor = model.senderColor

        replyView.isHidden = model.reply == nil
        if let reply = model.reply { replyView.configure(reply) }

        textView.isHidden = model.text == nil
        textView.textStorage?.setAttributedString(model.text ?? NSAttributedString())
        textView.linkTextAttributes = model.isOutgoing
            ? [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
            : [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.alignment = model.isService ? .center : .natural

        footerView.isHidden = model.isService
        footerView.text = model.footer
        footerView.drawsPill = layout.footerOverlaysMedia

        mediaContainer.isHidden = layout.media == nil
        configureMedia(model)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityText(model))
        needsLayout = true
    }

    /// Fills `mediaContainer` with the message's media view.
    func configureMedia(_ model: MessageRowModel) {
        guard let media = model.media else {
            mediaContainer.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if let mediaController,
           let view = mediaController.mediaView(for: model, reusing: mediaContainer.subviews.first) {
            if view.superview !== mediaContainer {
                mediaContainer.subviews.forEach { $0.removeFromSuperview() }
                mediaContainer.addSubview(view)
            }
            return
        }
        if !(mediaContainer.subviews.first is MediaPlaceholderView) {
            mediaContainer.subviews.forEach { $0.removeFromSuperview() }
        }
        let placeholder = mediaContainer.subviews.first as? MediaPlaceholderView ?? {
            let view = MediaPlaceholderView()
            mediaContainer.addSubview(view)
            return view
        }()
        placeholder.symbol = switch media.kind {
        case .photo: "photo"
        case .video, .videoNote: "video"
        case .animation: "play.rectangle"
        case .sticker: "face.smiling"
        case .card: "doc"
        }
    }

    override func layout() {
        super.layout()
        guard let layout = layoutInfo else { return }
        bubble.frame = layout.bubble
        senderLabel.frame = layout.sender ?? .zero
        replyView.frame = layout.reply ?? .zero
        textView.frame = layout.text ?? .zero
        footerView.frame = layout.footer
        mediaContainer.frame = layout.media ?? .zero
        for subview in mediaContainer.subviews { subview.frame = mediaContainer.bounds }
    }

    private func accessibilityText(_ model: MessageRowModel) -> String {
        var parts: [String] = []
        if let name = model.senderName { parts.append(name) } else if model.isOutgoing { parts.append("You") }
        if let media = model.media { parts.append("\(media.kind)") }
        if let text = model.text?.string, !text.isEmpty { parts.append(text) }
        parts.append(model.footer.string)
        return parts.joined(separator: ", ")
    }
}

/// Centered pill for day separators.
final class DaySeparatorView: NSTableCellView {
    private var text = NSAttributedString()

    override var isFlipped: Bool { true }

    func configure(_ title: String) {
        text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        let pill = CGRect(x: floor((bounds.width - size.width) / 2) - 10, y: floor((bounds.height - size.height) / 2) - 3,
                          width: ceil(size.width) + 20, height: ceil(size.height) + 6)
        BubbleColors.service.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 3))
    }
}
