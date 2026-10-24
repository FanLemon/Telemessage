import Cocoa

/// An attachment waiting in the composer.
struct AttachmentItem: Identifiable {
    enum State {
        case preparing
        case ready(PreparedAttachment)
        case failed(String)
    }

    let id: UUID
    let name: String
    var state: State

    var prepared: PreparedAttachment? {
        if case .ready(let attachment) = state { return attachment }
        return nil
    }
}

/// Preview strip above the composer with remove buttons and the "Send as files" option.
final class AttachmentTrayView: NSView {
    var onRemove: (UUID) -> Void = { _ in }
    var onSendAsFilesChanged: (Bool) -> Void = { _ in }

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let asFilesCheckbox = NSButton(checkboxWithTitle: "Send as files", target: nil, action: nil)
    private let summaryLabel = Controls.secondaryLabel(size: 11)

    var sendAsFiles: Bool { asFilesCheckbox.state == .on }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        stack.pin(to: document)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)])

        asFilesCheckbox.target = self
        asFilesCheckbox.action = #selector(asFilesToggled)
        asFilesCheckbox.controlSize = .small
        asFilesCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        asFilesCheckbox.toolTip = "Send originals without compression"
        let options = Controls.stack([summaryLabel, NSView(), asFilesCheckbox], orientation: .horizontal, spacing: 8)

        addSubview(scrollView)
        addSubview(options)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 72),
            options.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            options.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            options.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ items: [AttachmentItem], images: ImageLoader) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let chip = AttachmentChipView(item: item, images: images)
            chip.onRemove = { [weak self] in self?.onRemove(item.id) }
            stack.addArrangedSubview(chip)
        }
        let preparing = items.filter { if case .preparing = $0.state { return true } else { return false } }.count
        let failed = items.filter { if case .failed = $0.state { return true } else { return false } }.count
        var parts = [items.count == 1 ? "1 attachment" : "\(items.count) attachments"]
        if preparing > 0 { parts.append("preparing \(preparing)…") }
        if failed > 0 { parts.append("\(failed) can't be sent") }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        summaryLabel.textColor = failed > 0 ? .systemRed : .secondaryLabelColor
    }

    @objc private func asFilesToggled() {
        onSendAsFilesChanged(sendAsFiles)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 64-point preview of one attachment.
private final class AttachmentChipView: NSView {
    var onRemove: () -> Void = {}
    private let item: AttachmentItem
    private var image: NSImage?
    private let spinner = NSProgressIndicator()

    init(item: AttachmentItem, images: ImageLoader) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 64)])
        toolTip = item.name
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(item.name)

        switch item.state {
        case .preparing:
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
            spinner.startAnimation(nil)
        case .ready(let attachment):
            if let thumbnail = attachment.thumbnailPath {
                image = images.cachedImage(path: thumbnail, maxPixelSize: 128) ?? NSImage(contentsOfFile: thumbnail)
            }
            if image == nil { image = MediaFiles.icon(forFileName: attachment.fileName) }
        case .failed(let message):
            toolTip = "\(item.name): \(message)"
        }

        let remove = Controls.symbolButton("xmark.circle.fill", accessibility: "Remove \(item.name)", target: self, action: #selector(removeTapped))
        remove.contentTintColor = NSColor(white: 0, alpha: 0.65)
        remove.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        if let image {
            let isIcon = item.prepared?.thumbnailPath == nil
            let target = isIcon ? bounds.insetBy(dx: 12, dy: 12) : bounds
            let scale = isIcon ? min(target.width / image.size.width, target.height / image.size.height)
                               : max(target.width / image.size.width, target.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if case .failed = item.state {
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .bold))?.tinted(.white) {
                warning.draw(in: CGRect(x: bounds.midX - warning.size.width / 2, y: bounds.midY - warning.size.height / 2,
                                        width: warning.size.width, height: warning.size.height),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let attachment = item.prepared, attachment.kind == .video {
            let label = NSAttributedString(string: MediaFiles.duration(attachment.duration), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let size = label.size()
            let pill = CGRect(x: 4, y: bounds.maxY - size.height - 6, width: size.width + 8, height: size.height + 2)
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 4, y: pill.minY + 1))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    @objc private func removeTapped() { onRemove() }
}
