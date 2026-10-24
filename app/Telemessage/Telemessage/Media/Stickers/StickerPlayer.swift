import Cocoa

/// Plays an animated sticker: frames are produced on a private serial queue and shown in a
/// layer-backed view. Only plays while asked to (visible, Reduce Motion off).
final class StickerPlayer: StickerAnimating {
    let view: NSView
    /// Called once the first frame is on screen, so a still placeholder can be removed.
    var onFirstFrame: (() -> Void)?

    private let queue = DispatchQueue(label: "com.Farsonic.Telemessage.sticker", qos: .userInitiated)
    private let box = SourceBox()
    private var timer: DispatchSourceTimer?
    private var isPlaying = false
    private var hasFrame = false

    /// `makeSource` runs on the player's queue so parsing never blocks the main thread.
    init(makeSource: @escaping @Sendable () -> AnimationFrameSource?) {
        view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        view.setAccessibilityElement(false)
        let box = self.box
        queue.async { [weak self] in
            box.source = makeSource()
            let first = box.source?.nextFrame()
            DispatchQueue.main.async { self?.show(first) }
        }
    }

    isolated deinit {
        timer?.cancel()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        timer?.cancel()
        timer = nil
        guard playing else { return }
        let box = self.box
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The delay is known once the source exists; poll at 30 fps until then.
        let delay = box.delay ?? 1.0 / 30
        timer.schedule(deadline: .now() + delay, repeating: delay, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let frame = box.source?.nextFrame() else { return }
            DispatchQueue.main.async { self?.show(frame) }
        }
        timer.resume()
        self.timer = timer
    }

    private func show(_ frame: CGImage?) {
        guard let frame else { return }
        view.layer?.contents = frame
        if !hasFrame {
            hasFrame = true
            onFirstFrame?()
        }
    }

    /// Holds the frame source; only touched on `queue`.
    private nonisolated final class SourceBox: @unchecked Sendable {
        var source: AnimationFrameSource?
        var delay: Double? { source?.frameDelay }
    }
}

enum StickerAnimators {
    static func make(format: Sticker.Format, path: String, pixelSize: Int) -> StickerPlayer? {
        switch format {
        case .tgs: StickerPlayer { TGSFrameSource(path: path, pixelSize: pixelSize) }
        case .webm: StickerPlayer { WebMFrameSource(path: path) }
        case .webp, .unknown: nil
        }
    }
}
