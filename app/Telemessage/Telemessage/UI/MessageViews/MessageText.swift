import Cocoa

/// Builds attributed strings from Telegram formatted text. Entity offsets are UTF-16, like NSString.
enum MessageText {
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let monospacedFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func attributed(_ text: FormattedText, color: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.text, attributes: [.font: bodyFont, .foregroundColor: color])
        let length = (text.text as NSString).length
        for entity in text.entities {
            let range = NSRange(location: Int(entity.offset), length: Int(entity.length))
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { continue }
            let substring = (text.text as NSString).substring(with: range)
            switch entity.type {
            case .bold: result.applyFontTraits(.boldFontMask, range: range)
            case .italic: result.applyFontTraits(.italicFontMask, range: range)
            case .underline: result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code, .pre: result.addAttribute(.font, value: monospacedFont, range: range)
            case .spoiler: result.addAttribute(.backgroundColor, value: NSColor.tertiaryLabelColor, range: range)
            case .blockQuote, .expandableBlockQuote:
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            case .textURL(let url):
                if let url = URL(string: url) { result.addAttribute(.link, value: url, range: range) }
            case .mentionName(let userID):
                result.addAttribute(.link, value: URL(string: "tg://user?id=\(userID)")!, range: range)
            case .customEmoji:
                break
            case .other(let type):
                if let url = autoLink(type: type, text: substring) { result.addAttribute(.link, value: url, range: range) }
            }
        }
        return result
    }

    /// Links for entities TDLib detects in plain text.
    static func autoLink(type: String, text: String) -> URL? {
        switch type {
        case "textEntityTypeUrl":
            return URL(string: text.contains("://") ? text : "https://\(text)")
        case "textEntityTypeEmailAddress":
            return URL(string: "mailto:\(text)")
        case "textEntityTypeMention":
            return URL(string: "https://t.me/\(text.dropFirst())")
        case "textEntityTypePhoneNumber":
            return URL(string: "tel:\(text.filter { $0.isNumber || $0 == "+" })")
        default:
            return nil
        }
    }

    static func italicNote(_ text: String) -> NSAttributedString {
        let font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
    }
}

/// TextKit 1 measurement matching `MessageTextView` (zero insets and line fragment padding).
enum TextMeasure {
    private static let storage = NSTextStorage()
    private static let layoutManager: NSLayoutManager = {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return manager
    }()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        return container
    }()

    struct Result {
        let size: CGSize
        /// Width of the last line, so a footer can share it when there is room.
        let lastLineWidth: CGFloat
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> Result {
        guard text.length > 0 else { return Result(size: .zero, lastLineWidth: 0) }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        let manager = layoutManager
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        var lastLine = CGRect.zero
        let glyphs = manager.numberOfGlyphs
        if glyphs > 0 {
            lastLine = manager.lineFragmentUsedRect(forGlyphAt: glyphs - 1, effectiveRange: nil)
        }
        // A trailing newline produces an empty extra line fragment.
        if manager.extraLineFragmentTextContainer != nil { lastLine = manager.extraLineFragmentUsedRect }
        return Result(size: CGSize(width: ceil(used.width), height: ceil(used.height)), lastLineWidth: ceil(lastLine.width))
    }
}
