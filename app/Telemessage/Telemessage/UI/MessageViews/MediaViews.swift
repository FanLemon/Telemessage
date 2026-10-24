import AVFoundation
import Cocoa

/// Base for media inside a message row. Views are reused across rows; `configure` may be called
/// with a different message at any time, and file progress arrives through `refresh()`.
class MediaContentView: NSView {
    weak var controller: ConversationMediaController?
    private(set) var model: MessageRowModel?

    override var isFlipped: Bool { true }

    var services: AccountServices? { controller?.services }
    var message: Message? { model?.message }

    /// Files whose updates should call `refresh()`.
    var watchedFileIDs: [Int32] { [] }

    func configure(_ model: MessageRowModel) {
        let changedMessage = self.model?.id != model.id
        self.model = model
        if changedMessage { prepareForNewMessage() }
        refresh()
    }

    /// Reset per-message state (stop playback, forget loaded images).
    func prepareForNewMessage() {}

    /// Re-read file state and update the view.
    func refresh() {}

    /// The row scrolled in or out of view, or the window's visibility changed.
    func visibilityChanged() {}

    func stopPlayback() {}

    /// Pixel size to decode images at for this view's spec size.
    var displayPixels: Int {
        let size = model?.media?.size ?? bounds.size
        return Int(ceil(max(size.width, size.height) * (window?.backingScaleFactor ?? 2)))
    }

    /// The message is outgoing and still being sent.
    var isUploading: Bool { message?.isOutgoing == true && message?.sendingState == .pending }

    /// Upload progress of `file` while the message is being sent.
    func uploadProgress(of file: TDFile) -> Double? {
        guard isUploading, let services else { return nil }
        let current = services.files.latest(file)
        let total = max(current.size, current.expectedSize)
        guard total > 0 else { return 0 }
        return min(1, Double(current.remote.uploadedSize) / Double(total))
    }

    var isOnScreen: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !visibleRect.isEmpty
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }

    /// The user clicked the media.
    func activate() {}
}

/// Media drawn from a still image (photo, poster, sticker), with an optional progress ring.
class ImageMediaView: MediaContentView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isCircular = false
    var fillsBounds = true
    var drawsBackground = true
    let progressRing = ProgressRingView()
    private var loadedPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        progressRing.isHidden = true
        addSubview(progressRing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForNewMessage() {
        image = nil
        loadedPath = nil
    }

    override func layout() {
        super.layout()
        progressRing.frame = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44)
    }

    /// Shows `file` once downloaded (downloading it when `download`), the minithumbnail meanwhile.
    func showImage(file: TDFile?, minithumbnail: Minithumbnail?, download: Bool) {
        guard let services else { return }
        if image == nil, let minithumbnail { image = services.images.minithumbnail(minithumbnail) }
        guard let file else { return }
        guard let path = services.files.localPath(file) else {
            if download { services.files.download(file, priority: .visible) }
            return
        }
        guard path != loadedPath else { return }
        let pixels = displayPixels
        if let cached = services.images.cachedImage(path: path, maxPixelSize: pixels) {
            image = cached
            loadedPath = path
            return
        }
        let messageID = message?.id
        Task { [weak self] in
            let loaded = await services.images.image(path: path, maxPixelSize: pixels)
            guard let self, message?.id == messageID, let loaded else { return }
            image = loaded
            loadedPath = path
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = isCircular
            ? NSBezierPath(ovalIn: bounds)
            : NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            let scale = fillsBounds
                ? max(bounds.width / image.size.width, bounds.height / image.size.height)
                : min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if drawsBackground {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func showProgress(for file: TDFile, idleSymbol: String?) {
        guard let services else { return }
        if let upload = uploadProgress(of: file) {
            progressRing.isHidden = false
            progressRing.symbol = "xmark"
            progressRing.progress = upload
            return
        }
        let current = services.files.latest(file)
        if current.local.isDownloadingActive {
            progressRing.isHidden = false
            progressRing.symbol = "xmark"
            progressRing.progress = services.files.progress(file) ?? 0
        } else if current.completedPath == nil, let idleSymbol {
            progressRing.isHidden = false
            progressRing.symbol = idleSymbol
            progressRing.progress = nil
        } else {
            progressRing.isHidden = true
        }
    }
}

final class PhotoMediaView: ImageMediaView {
    private var file: TDFile? {
        guard case .photo(let photo, _)? = message?.content else { return nil }
        return MediaFiles.bestSize(of: photo, forPixelWidth: CGFloat(displayPixels))?.photo
    }

    override var watchedFileIDs: [Int32] { file.map { [$0.id] } ?? [] }

    override func refresh() {
        guard case .photo(let photo, _)? = message?.content, let file else { return }
        let automatic = AppSettings.shared.autoDownloadPhotos
        showImage(file: file, minithumbnail: photo.minithumbnail, download: automatic || requested)
        showProgress(for: file, idleSymbol: automatic || requested ? nil : "arrow.down")
        setAccessibilityRole(.image)
        setAccessibilityLabel("Photo")
    }

    /// The user asked for this photo while automatic downloads are off.
    private var requested = false

    override func prepareForNewMessage() {
        super.prepareForNewMessage()
        requested = false
    }

    override func activate() {
        guard let message, let file else { return }
        if isUploading {
            controller?.cancelSending(message)
        } else if services?.files.localPath(file) == nil, !AppSettings.shared.autoDownloadPhotos, !requested {
            requested = true
            refresh()
        } else {
            controller?.openPhoto(message)
        }
    }
}

/// Video poster with duration; downloads on click and opens the player when ready.
final class VideoMediaView: ImageMediaView {
    private let durationPill = PillLabel()
    private var video: Video? {
        if case .video(let video, _)? = message?.content { return video }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(durationPill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var watchedFileIDs: [Int32] { [video?.video.id, video?.thumbnail?.file.id].compactMap { $0 } }

    override func layout() {
        super.layout()
        let size = durationPill.fittingSize
        durationPill.frame = CGRect(x: 8, y: 8, width: size.width, height: size.height)
    }

    override func refresh() {
        guard let video else { return }
        let poster = video.thumbnail.flatMap { $0.format.isImage ? $0.file : nil }
        showImage(file: poster, minithumbnail: video.minithumbnail, download: true)
        let downloaded = services?.files.localPath(video.video) != nil
        showProgress(for: video.video, idleSymbol: "play.fill")
        if downloaded, !isUploading {
            progressRing.isHidden = false
            progressRing.symbol = "play.fill"
            progressRing.progress = nil
        }
        durationPill.text = MediaFiles.duration(video.duration) + (downloaded ? "" : " · " + MediaFiles.size(video.video.size))
        needsLayout = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Video, \(MediaFiles.duration(video.duration))")
    }

    override func activate() {
        guard let video, let controller, let message else { return }
        if isUploading {
            controller.cancelSending(message)
        } else if services?.files.latest(video.video).local.isDownloadingActive == true {
            controller.cancelDownload(video.video)
        } else {
            controller.whenDownloaded(video.video) { [weak controller] path in
                controller?.playVideo(path: path, size: CGSize(width: CGFloat(video.width), height: CGFloat(video.height)))
            }
        }
        refresh()
    }
}

/// Looping silent animation (GIF / MPEG-4), playing only while visible.
final class AnimationMediaView: ImageMediaView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private let gifView = NSImageView()
    private let badge = PillLabel()
    /// The user's explicit play/pause choice; without one, animations play unless Reduce Motion is on.
    private var userWantsPlayback: Bool?

    private var animation: Animation? {
        if case .animation(let animation, _)? = message?.content { return animation }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gifView.animates = true
        gifView.imageScaling = .scaleProportionallyUpOrDown
        gifView.isHidden = true
        addSubview(gifView, positioned: .below, relativeTo: progressRing)
        badge.text = "GIF"
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var watchedFileIDs: [Int32] { [animation?.animation.id, animation?.thumbnail?.file.id].compactMap { $0 } }

    override func prepareForNewMessage() {
        super.prepareForNewMessage()
        stopPlayback()
        userWantsPlayback = nil
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        gifView.frame = bounds
        let size = badge.fittingSize
        badge.frame = CGRect(x: 8, y: 8, width: size.width, height: size.height)
    }

    override func refresh() {
        guard let animation, let services else { return }
        let poster = animation.thumbnail.flatMap { $0.format.isImage ? $0.file : nil }
        showImage(file: poster, minithumbnail: animation.minithumbnail, download: true)
        // Small animations download automatically; they are the message's content.
        if animation.animation.size < 10_000_000 { services.files.download(animation.animation, priority: .visible) }
        showProgress(for: animation.animation, idleSymbol: animation.animation.size >= 10_000_000 ? "arrow.down" : nil)
        visibilityChanged()
        setAccessibilityRole(.image)
        setAccessibilityLabel("GIF")
    }

    private var wantsPlayback: Bool { userWantsPlayback ?? !MediaFiles.reduceMotion }

    override func visibilityChanged() {
        // Until downloaded, the ring shows download state (set in refresh).
        guard let animation, let path = services?.files.localPath(animation.animation) else { return }
        if wantsPlayback && isOnScreen { play(path: path, mimeType: animation.mimeType) } else { pause() }
        progressRing.isHidden = wantsPlayback
        progressRing.symbol = "play.fill"
        progressRing.progress = nil
    }

    private func play(path: String, mimeType: String) {
        if mimeType == "image/gif" {
            if gifView.image == nil { gifView.image = NSImage(contentsOfFile: path) }
            gifView.isHidden = false
            gifView.animates = true
            return
        }
        if let player {
            player.play()
            return
        }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = 11
        layer.masksToBounds = true
        layer.frame = bounds
        self.layer?.insertSublayer(layer, below: progressRing.layer)
        playerLayer = layer
        self.player = player
        player.play()
    }

    private func pause() {
        player?.pause()
        gifView.animates = false
    }

    override func stopPlayback() {
        player?.pause()
        looper = nil
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        gifView.image = nil
        gifView.isHidden = true
    }

    override func activate() {
        guard let animation, let services else { return }
        if services.files.localPath(animation.animation) == nil {
            services.files.download(animation.animation, priority: .requested)
            userWantsPlayback = true
        } else {
            userWantsPlayback = !wantsPlayback
        }
        visibilityChanged()
    }
}

/// Sticker without a bubble. Static WebP decodes through ImageIO; animated formats render through
/// `StickerPlayer` when available, otherwise their still thumbnail.
final class StickerMediaView: ImageMediaView {
    private var animator: StickerAnimating?

    private var sticker: Sticker? {
        if case .sticker(let sticker)? = message?.content { return sticker }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillsBounds = false
        drawsBackground = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var watchedFileIDs: [Int32] { [sticker?.sticker.id, sticker?.thumbnail?.file.id].compactMap { $0 } }

    override func prepareForNewMessage() {
        super.prepareForNewMessage()
        stopPlayback()
    }

    override func layout() {
        super.layout()
        animator?.view.frame = bounds
    }

    override func refresh() {
        guard let sticker, let services else { return }
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(sticker.emoji) sticker")
        switch sticker.format {
        case .webp, .unknown:
            showImage(file: sticker.sticker, minithumbnail: nil, download: true)
        case .tgs, .webm:
            services.files.download(sticker.sticker, priority: .visible)
            if let path = services.files.localPath(sticker.sticker), animator == nil,
               let player = StickerAnimators.make(format: sticker.format, path: path, pixelSize: displayPixels) {
                animator = player
                player.view.frame = bounds
                addSubview(player.view)
                // Keep the still thumbnail until the first frame replaces it.
                player.onFirstFrame = { [weak self] in self?.image = nil }
            }
            if animator == nil {
                let still = sticker.thumbnail.flatMap { $0.format.isImage ? $0.file : nil }
                showImage(file: still, minithumbnail: nil, download: true)
            }
            visibilityChanged()
        }
    }

    override func visibilityChanged() {
        animator?.setPlaying(isOnScreen && !MediaFiles.reduceMotion)
    }

    override func stopPlayback() {
        animator?.setPlaying(false)
        animator?.view.removeFromSuperview()
        animator = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if image == nil, animator == nil, let sticker {
            // Nothing decoded yet: show the emoji the sticker stands for.
            let text = NSAttributedString(string: sticker.emoji.isEmpty ? "🖼" : sticker.emoji,
                                          attributes: [.font: NSFont.systemFont(ofSize: min(bounds.width, bounds.height) * 0.5)])
            let size = text.size()
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        super.draw(dirtyRect)
    }
}

/// Animated sticker playback, provided by the sticker renderers (M5b).
protocol StickerAnimating: AnyObject {
    var view: NSView { get }
    func setPlaying(_ playing: Bool)
}

/// Round video message: circular poster; plays in the video player.
final class VideoNoteMediaView: ImageMediaView {
    private let durationPill = PillLabel()
    private var note: VideoNote? {
        if case .videoNote(let note)? = message?.content { return note }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isCircular = true
        addSubview(durationPill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var watchedFileIDs: [Int32] { [note?.video.id, note?.thumbnail?.file.id].compactMap { $0 } }

    override func layout() {
        super.layout()
        let size = durationPill.fittingSize
        durationPill.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 10, width: size.width, height: size.height)
    }

    override func refresh() {
        guard let note else { return }
        let poster = note.thumbnail.flatMap { $0.format.isImage ? $0.file : nil }
        showImage(file: poster, minithumbnail: note.minithumbnail, download: true)
        showProgress(for: note.video, idleSymbol: "play.fill")
        if services?.files.localPath(note.video) != nil {
            progressRing.isHidden = false
            progressRing.symbol = "play.fill"
            progressRing.progress = nil
        }
        durationPill.text = MediaFiles.duration(note.duration)
        needsLayout = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Video message, \(MediaFiles.duration(note.duration))")
    }

    override func activate() {
        guard let note, let controller else { return }
        controller.whenDownloaded(note.video) { [weak controller] path in
            controller?.playVideo(path: path, size: CGSize(width: 480, height: 480))
        }
        refresh()
    }
}

/// Document, audio and voice messages: icon/play button, name and size or duration.
final class FileCardView: MediaContentView {
    private let iconView = NSImageView()
    private let ring = ProgressRingView()
    private let titleLabel = Controls.label(font: .systemFont(ofSize: 13, weight: .medium))
    private let subtitleLabel = Controls.secondaryLabel(size: 11)
    private var playbackObservation: StoreObservation?

    private enum Kind {
        case document(Document), audio(Audio), voice(VoiceNote)

        var file: TDFile {
            switch self {
            case .document(let document): document.document
            case .audio(let audio): audio.audio
            case .voice(let voice): voice.voice
            }
        }
    }

    private var kind: Kind? {
        switch message?.content {
        case .document(let document, _)?: .document(document)
        case .audio(let audio, _)?: .audio(audio)
        case .voiceNote(let voice, _)?: .voice(voice)
        default: nil
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        for view in [iconView, ring, titleLabel, subtitleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        playbackObservation = AudioPlayback.shared.observe { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var watchedFileIDs: [Int32] { kind.map { [$0.file.id] } ?? [] }

    override func layout() {
        super.layout()
        iconView.frame = CGRect(x: 0, y: (bounds.height - 40) / 2, width: 40, height: 40)
        ring.frame = iconView.frame
        titleLabel.frame = CGRect(x: 50, y: bounds.midY - 18, width: bounds.width - 50, height: 18)
        subtitleLabel.frame = CGRect(x: 50, y: bounds.midY + 1, width: bounds.width - 50, height: 16)
    }

    override func refresh() {
        guard let kind, let services else { return }
        let file = services.files.latest(kind.file)
        let path = file.completedPath
        let downloading = file.local.isDownloadingActive
        let total = max(file.size, file.expectedSize)
        var progressText = downloading ? "\(MediaFiles.size(file.local.downloadedSize)) of \(MediaFiles.size(total))" : nil
        let upload = uploadProgress(of: kind.file)
        if upload != nil { progressText = "Uploading \(MediaFiles.size(file.remote.uploadedSize)) of \(MediaFiles.size(total))" }

        switch kind {
        case .document(let document):
            titleLabel.stringValue = document.fileName.isEmpty ? "File" : document.fileName
            subtitleLabel.stringValue = progressText ?? MediaFiles.size(total)
            iconView.image = MediaFiles.icon(forFileName: document.fileName)
            iconView.isHidden = false
            // The ring covers the icon until the file is on disk.
            ring.isHidden = path != nil && !downloading
            ring.drawsFill = true
            ring.symbol = downloading ? "xmark" : "arrow.down"
            ring.progress = downloading ? services.files.progress(file) : nil
        case .audio(let audio):
            let name = [audio.performer, audio.title].filter { !$0.isEmpty }.joined(separator: " – ")
            titleLabel.stringValue = name.isEmpty ? (audio.fileName.isEmpty ? "Audio" : audio.fileName) : name
            subtitleLabel.stringValue = progressText ?? playbackText(path: path, duration: audio.duration)
            configurePlayButton(path: path, downloading: downloading, file: file)
        case .voice(let voice):
            titleLabel.stringValue = "Voice message"
            subtitleLabel.stringValue = progressText ?? playbackText(path: path, duration: voice.duration)
            configurePlayButton(path: path, downloading: downloading, file: file)
        }
        if let upload {
            ring.isHidden = false
            ring.drawsFill = true
            ring.symbol = "xmark"
            ring.progress = upload
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(titleLabel.stringValue), \(subtitleLabel.stringValue)")
    }

    private func configurePlayButton(path: String?, downloading: Bool, file: TDFile) {
        iconView.isHidden = true
        ring.isHidden = false
        ring.drawsFill = true
        if downloading {
            ring.symbol = "xmark"
            ring.progress = services?.files.progress(file)
        } else {
            ring.symbol = path.map { AudioPlayback.shared.isPlaying($0) ? "pause.fill" : "play.fill" } ?? "arrow.down"
            ring.progress = nil
        }
    }

    private func playbackText(path: String?, duration: Int32) -> String {
        guard let path, AudioPlayback.shared.playingPath == path else { return MediaFiles.duration(duration) }
        return "\(MediaFiles.duration(Int32(AudioPlayback.shared.currentTime))) / \(MediaFiles.duration(duration))"
    }

    override func activate() {
        guard let kind, let controller, let services, let message else { return }
        if isUploading {
            controller.cancelSending(message)
            return
        }
        let file = kind.file
        if services.files.latest(file).local.isDownloadingActive {
            controller.cancelDownload(file)
            return
        }
        switch kind {
        case .document:
            controller.whenDownloaded(file) { path in MediaFiles.open(path) }
        case .audio, .voice:
            controller.whenDownloaded(file) { [weak controller] path in
                if !AudioPlayback.shared.toggle(path) { controller?.reportUnplayable(path: path) }
            }
        }
        refresh()
    }

    override func stopPlayback() {}
}

/// Circular button-like progress indicator with a center symbol.
final class ProgressRingView: NSView {
    var progress: Double? { didSet { needsDisplay = true } }
    var symbol = "arrow.down" { didSet { needsDisplay = true } }
    var drawsFill = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1.5, dy: 1.5)
        if drawsFill {
            NSColor(white: 0, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        if let progress {
            let path = NSBezierPath()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let start: CGFloat = -90
            path.appendArc(withCenter: center, radius: circle.width / 2 - 2, startAngle: start,
                           endAngle: start + 360 * CGFloat(max(0.02, progress)), clockwise: false)
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            (drawsFill ? NSColor.white : NSColor.controlAccentColor).setStroke()
            path.stroke()
        }
        let color: NSColor = drawsFill ? .white : .controlAccentColor
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.width * 0.32, weight: .bold))?.tinted(color) {
            let size = image.size
            image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Small dark capsule label used over media (durations, "GIF").
final class PillLabel: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                                                      .foregroundColor: NSColor.white])
    }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize {
        let size = attributed.size()
        return NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        attributed.draw(at: CGPoint(x: 6, y: 2))
    }
}
