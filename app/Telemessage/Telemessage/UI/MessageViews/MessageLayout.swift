import Cocoa

/// How a message's media is laid out; rendered by `MediaContentView` (M5).
struct MediaSpec: Equatable {
    enum Kind: Equatable {
        case photo, video, animation, sticker, videoNote
        /// Document, audio and voice cards.
        case card
    }

    let kind: Kind
    let size: CGSize

    /// Stickers and round video notes stand alone without a bubble.
    var isBubbleless: Bool { kind == .sticker || kind == .videoNote }

    static func make(for content: MessageContent, maxWidth: CGFloat) -> MediaSpec? {
        func fit(_ width: Int32, _ height: Int32, box: CGSize, minimum: CGSize = CGSize(width: 120, height: 80)) -> CGSize {
            let w = CGFloat(width > 0 ? width : 16), h = CGFloat(height > 0 ? height : 9)
            let scale = min(box.width / w, box.height / h, 1.5)
            return CGSize(width: max(minimum.width, floor(w * scale)), height: max(minimum.height, floor(h * scale)))
        }
        let box = CGSize(width: min(maxWidth, 320), height: 340)
        switch content {
        case .photo(let photo, _):
            let largest = photo.sizes.max { $0.width * $0.height < $1.width * $1.height }
            return MediaSpec(kind: .photo, size: fit(largest?.width ?? 0, largest?.height ?? 0, box: box))
        case .video(let video, _):
            return MediaSpec(kind: .video, size: fit(video.width, video.height, box: box))
        case .animation(let animation, _):
            return MediaSpec(kind: .animation, size: fit(animation.width, animation.height, box: box))
        case .sticker(let sticker):
            return MediaSpec(kind: .sticker, size: fit(sticker.width, sticker.height, box: CGSize(width: 160, height: 160),
                                                       minimum: CGSize(width: 60, height: 60)))
        case .videoNote:
            return MediaSpec(kind: .videoNote, size: CGSize(width: 200, height: 200))
        case .document, .audio, .voiceNote:
            return MediaSpec(kind: .card, size: CGSize(width: min(maxWidth, 260), height: 44))
        case .text, .unsupported:
            return nil
        }
    }
}

/// Everything a message row displays, resolved from store state.
struct MessageRowModel {
    struct Reply: Equatable {
        let title: String
        let text: String
        let color: NSColor
    }

    let message: Message
    let senderName: String?
    let senderColor: NSColor
    let reply: Reply?
    let text: NSAttributedString?
    let media: MediaSpec?
    let footer: NSAttributedString
    let continuesGroup: Bool
    let isService: Bool

    var id: Int64 { message.id }
    var isOutgoing: Bool { message.isOutgoing }
}

/// Frames for one message row at a given width, in flipped row coordinates.
struct MessageLayout {
    let rowHeight: CGFloat
    let bubble: CGRect
    let drawsBubble: Bool
    let sender: CGRect?
    let reply: CGRect?
    let media: CGRect?
    let text: CGRect?
    let footer: CGRect
    /// The footer sits on top of media (dark pill) instead of in the bubble.
    let footerOverlaysMedia: Bool

    static let sideInset: CGFloat = 12
    static let padding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    static let mediaInset: CGFloat = 3
    static let replyHeight: CGFloat = 34

    static func maxBubbleWidth(rowWidth: CGFloat) -> CGFloat {
        min(floor((rowWidth - 2 * sideInset) * 0.82), 480)
    }

    init(model: MessageRowModel, width rowWidth: CGFloat) {
        if model.isService {
            let size = TextMeasure.measure(model.text ?? NSAttributedString(), width: rowWidth - 80).size
            let pill = CGRect(x: floor((rowWidth - size.width) / 2) - 10, y: 6, width: size.width + 20, height: size.height + 8)
            self.init(rowHeight: pill.maxY + 6, bubble: pill, drawsBubble: true, sender: nil, reply: nil, media: nil,
                      text: pill.insetBy(dx: 10, dy: 4), footer: .zero, footerOverlaysMedia: false)
            return
        }

        let p = Self.padding
        let maxBubble = Self.maxBubbleWidth(rowWidth: rowWidth)
        let contentMax = maxBubble - p.left - p.right
        let topMargin: CGFloat = model.continuesGroup ? 2 : 8
        let bubbleless = model.media?.isBubbleless == true && model.text == nil && model.reply == nil
        let footerSize = model.footer.size()
        let footerWidth = ceil(footerSize.width), footerHeight = ceil(footerSize.height)

        var y = p.top
        var contentWidth: CGFloat = 0
        var senderFrame: CGRect?, replyFrame: CGRect?, mediaFrame: CGRect?, textFrame: CGRect?
        var footerFrame = CGRect.zero
        var overlay = false

        if let name = model.senderName, !bubbleless {
            // +4 covers NSTextField's internal cell padding.
            let width = min(ceil(NSAttributedString(string: name, attributes: [.font: Self.senderFont]).size().width) + 4, contentMax)
            senderFrame = CGRect(x: p.left, y: y, width: width, height: 16)
            contentWidth = max(contentWidth, width)
            y += 18
        }
        if model.reply != nil {
            replyFrame = CGRect(x: p.left, y: y, width: 0, height: Self.replyHeight)  // width settled below
            contentWidth = max(contentWidth, min(contentMax, 200))
            y += Self.replyHeight + 4
        }

        var mediaWidth: CGFloat = 0
        if let media = model.media {
            mediaWidth = min(media.size.width, maxBubble - 2 * Self.mediaInset)
            let height = media.kind == .card ? media.size.height : floor(media.size.height * mediaWidth / media.size.width)
            let top = (senderFrame == nil && replyFrame == nil && !bubbleless) ? Self.mediaInset : y
            mediaFrame = CGRect(x: bubbleless ? 0 : Self.mediaInset, y: bubbleless ? 0 : top, width: mediaWidth, height: height)
            if media.kind == .card {
                mediaFrame!.origin.x = p.left
                mediaWidth = min(mediaWidth, contentMax)
                mediaFrame!.size.width = mediaWidth
                contentWidth = max(contentWidth, mediaWidth)
            }
            y = mediaFrame!.maxY + (model.text == nil ? 0 : p.top)
        }

        if let text = model.text {
            let measured = TextMeasure.measure(text, width: contentMax)
            textFrame = CGRect(x: p.left, y: y, width: measured.size.width, height: measured.size.height)
            if measured.lastLineWidth + 8 + footerWidth <= contentMax {
                // Footer shares the last text line.
                contentWidth = max(contentWidth, measured.size.width, measured.lastLineWidth + 8 + footerWidth)
                y += measured.size.height
                footerFrame = CGRect(x: 0, y: y - footerHeight, width: footerWidth, height: footerHeight)
            } else {
                contentWidth = max(contentWidth, measured.size.width, footerWidth)
                y += measured.size.height + 1
                footerFrame = CGRect(x: 0, y: y, width: footerWidth, height: footerHeight)
                y += footerHeight
            }
            y += p.bottom
        } else if model.media != nil, model.media?.kind != .card {
            overlay = true
            y += bubbleless ? 0 : Self.mediaInset
        } else {
            contentWidth = max(contentWidth, footerWidth)
            footerFrame = CGRect(x: 0, y: y + 1, width: footerWidth, height: footerHeight)
            y += footerHeight + 1 + p.bottom
        }

        var bubbleWidth = contentWidth + p.left + p.right
        if let media = model.media, media.kind != .card {
            bubbleWidth = max(bubbleWidth, mediaWidth + (bubbleless ? 0 : 2 * Self.mediaInset))
        }
        bubbleWidth = min(max(bubbleWidth, 44), maxBubble)
        let bubbleHeight = y

        if var frame = mediaFrame, model.media?.kind != .card {
            frame.origin.x = floor((bubbleWidth - frame.width) / 2)
            mediaFrame = frame
        }
        if overlay, let media = mediaFrame {
            let pill = CGSize(width: footerWidth + 12, height: footerHeight + 4)
            footerFrame = CGRect(x: media.maxX - pill.width - 6, y: media.maxY - pill.height - 6, width: pill.width, height: pill.height)
        } else {
            footerFrame.origin.x = bubbleWidth - p.right - footerWidth
        }
        replyFrame?.size.width = bubbleWidth - p.left - p.right

        let x = model.isOutgoing ? rowWidth - Self.sideInset - bubbleWidth : Self.sideInset
        let offset = CGPoint(x: x, y: topMargin)
        func shifted(_ rect: CGRect?) -> CGRect? { rect?.offsetBy(dx: offset.x, dy: offset.y) }
        self.init(rowHeight: topMargin + bubbleHeight + 2,
                  bubble: CGRect(x: x, y: topMargin, width: bubbleWidth, height: bubbleHeight),
                  drawsBubble: !bubbleless,
                  sender: shifted(senderFrame), reply: shifted(replyFrame), media: shifted(mediaFrame),
                  text: shifted(textFrame), footer: footerFrame.offsetBy(dx: offset.x, dy: offset.y),
                  footerOverlaysMedia: overlay)
    }

    private init(rowHeight: CGFloat, bubble: CGRect, drawsBubble: Bool, sender: CGRect?, reply: CGRect?, media: CGRect?,
                 text: CGRect?, footer: CGRect, footerOverlaysMedia: Bool) {
        self.rowHeight = rowHeight
        self.bubble = bubble
        self.drawsBubble = drawsBubble
        self.sender = sender
        self.reply = reply
        self.media = media
        self.text = text
        self.footer = footer
        self.footerOverlaysMedia = footerOverlaysMedia
    }

    static let senderFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let footerFont = NSFont.systemFont(ofSize: 10.5)
}
