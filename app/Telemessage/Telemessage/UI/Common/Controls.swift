import Cocoa

/// Small factories so programmatic views stay consistent.
enum Controls {
    static func label(_ text: String = "", font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
                      color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let label = lines == 1 ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func secondaryLabel(_ text: String = "", size: CGFloat = NSFont.smallSystemFontSize, lines: Int = 1) -> NSTextField {
        label(text, font: .systemFont(ofSize: size), color: .secondaryLabelColor, lines: lines)
    }

    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Borderless link-style button.
    static func linkButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func symbolButton(_ symbol: String, accessibility: String, target: AnyObject?, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.toolTip = accessibility
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical,
                      spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        if let alignment { stack.alignment = alignment }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

extension NSView {
    /// Pins the view to `other` with `insets` (top, left, bottom, right).
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
        ])
    }
}

extension NSEdgeInsets {
    static func all(_ value: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top: value, left: value, bottom: value, right: value) }
}
