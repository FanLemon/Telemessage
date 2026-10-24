import Cocoa

/// Round avatar: the profile photo when downloaded, its blurred minithumbnail meanwhile, or
/// initials on the Telegram accent color.
final class AvatarView: NSView {
    private var image: NSImage? { didSet { needsDisplay = true } }
    private var initials = "" { didSet { needsDisplay = true } }
    private var color = NSColor.systemBlue { didSet { needsDisplay = true } }
    private var fileID: Int32?

    override var isFlipped: Bool { true }

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(chat: Chat, services: AccountServices) {
        configure(title: services.presentation.title(of: chat), accentColorID: chat.accentColorID,
                  small: chat.photo?.small, minithumbnail: chat.photo?.minithumbnail, services: services)
    }

    func configure(user: User, services: AccountServices) {
        configure(title: user.fullName, accentColorID: user.accentColorID,
                  small: user.profilePhoto?.small, minithumbnail: user.profilePhoto?.minithumbnail, services: services)
    }

    func configure(title: String, accentColorID: Int32, small: TDFile?, minithumbnail: Minithumbnail?,
                   services: AccountServices) {
        initials = ChatPresentation.initials(title)
        color = Self.accentColor(accentColorID)
        fileID = small?.id
        guard let small else {
            image = nil
            return
        }
        let pixels = Int(ceil(bounds.width * 2))
        if let path = services.files.localPath(small) {
            if let cached = services.images.cachedImage(path: path, maxPixelSize: pixels) {
                image = cached
                return
            }
            image = minithumbnail.flatMap { services.images.minithumbnail($0) }
            Task { [weak self] in
                let loaded = await services.images.image(path: path, maxPixelSize: pixels)
                guard let self, fileID == small.id else { return }
                image = loaded ?? image
            }
        } else {
            image = minithumbnail.flatMap { services.images.minithumbnail($0) }
            services.files.download(small, priority: .avatar)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            // Aspect-fill.
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let gradient = NSGradient(starting: color.blended(withFraction: 0.25, of: .white) ?? color, ending: color)
            gradient?.draw(in: bounds, angle: 90)
            let font = NSFont.systemFont(ofSize: bounds.height * 0.38, weight: .semibold)
            let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Telegram's built-in accent colors (ids 0–6); higher ids are profile palettes, folded onto these.
    static func accentColor(_ id: Int32) -> NSColor {
        let palette: [NSColor] = [.systemRed, .systemOrange, .systemPurple, .systemGreen, .systemTeal, .systemBlue, .systemPink]
        return palette[Int(abs(id)) % palette.count]
    }
}

/// Capsule with an unread count; gray when the chat is muted.
final class BadgeView: NSView {
    var count: Int32 = 0 {
        didSet {
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel("\(count) unread")
        }
    }
    var isMuted = false { didSet { needsDisplay = true } }

    private var text: NSAttributedString {
        let label = count > 999 ? "999+" : "\(count)"
        return NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(20, text.size().width + 12), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isMuted ? NSColor.systemGray : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
