import Cocoa

/// Accepts dropped files and images for the chat, with a highlight while dragging over it.
final class DropTargetView: NSView {
    var acceptsDrops: () -> Bool = { false }
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onDropImage: (Data) -> Void = { _ in }

    private let overlay = DropOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        overlay.isHidden = true
        overlay.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops(), hasContent(sender.draggingPasteboard) else { return [] }
        overlay.frame = bounds
        if overlay.superview == nil { addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        overlay.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        overlay.isHidden = true
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles(urls)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            onDropImage(data)
            return true
        }
        return false
    }

    private func hasContent(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }
}

private final class DropOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        bounds.fill()
        let inset = bounds.insetBy(dx: 16, dy: 16)
        let path = NSBezierPath(roundedRect: inset, xRadius: 14, yRadius: 14)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let text = NSAttributedString(string: "Drop to attach", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.controlAccentColor,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
