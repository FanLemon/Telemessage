import AVKit
import Cocoa

/// Photo viewer and video player windows; one window per file.
final class MediaViewers {
    static let shared = MediaViewers()
    private var windows: [String: NSWindowController] = [:]

    func showPhoto(_ photo: Photo, title: String, services: AccountServices) {
        guard let size = MediaFiles.largestSize(of: photo) else { return }
        let key = "photo-\(size.photo.id)"
        if let existing = windows[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PhotoViewerWindowController(photo: photo, size: size, title: title, services: services)
        present(controller, key: key)
    }

    func playVideo(path: String, naturalSize: CGSize) {
        let key = "video-\(path)"
        if let existing = windows[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        present(VideoPlayerWindowController(path: path, naturalSize: naturalSize), key: key)
    }

    func closeAll() {
        for controller in windows.values { controller.close() }
        windows.removeAll()
    }

    private func present(_ controller: NSWindowController, key: String) {
        windows[key] = controller
        controller.showWindow(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[key] = nil }
        }
    }

    /// A content size for `size` that fits comfortably on the main screen.
    static func fitted(_ size: CGSize, minimum: CGSize = CGSize(width: 320, height: 240)) -> CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximum = CGSize(width: screen.width * 0.8, height: screen.height * 0.8)
        let w = max(size.width, 1), h = max(size.height, 1)
        let scale = min(maximum.width / w, maximum.height / h, 1)
        return CGSize(width: max(minimum.width, w * scale), height: max(minimum.height, h * scale))
    }
}

final class PhotoViewerWindowController: NSWindowController, NSWindowDelegate {
    private let services: AccountServices
    private let file: TDFile
    private let imageView = NSImageView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private var observation: StoreObservation?

    init(photo: Photo, size: PhotoSize, title: String, services: AccountServices) {
        self.services = services
        file = size.photo
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MediaViewers.fitted(CGSize(width: CGFloat(size.width), height: CGFloat(size.height)))),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = photo.minithumbnail.flatMap { services.images.minithumbnail($0) }
        imageView.frame = window.contentLayoutRect
        imageView.autoresizingMask = [.width, .height]
        imageView.setAccessibilityLabel("Photo")
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 6
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        window.contentView = scrollView

        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        let save = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Photo") ?? NSImage(),
                            target: self, action: #selector(saveAs(_:)))
        save.bezelStyle = .accessoryBarAction
        save.isBordered = false
        save.toolTip = "Save Photo As…"
        let accessory = NSTitlebarAccessoryViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        save.frame = NSRect(x: 4, y: 2, width: 26, height: 24)
        container.addSubview(save)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        observation = services.store.observe { [weak self] change in
            if case .file(let id) = change, id == self?.file.id { self?.load() }
        }
        window.center()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func load() {
        guard let path = services.files.localPath(file) else {
            spinner.startAnimation(nil)
            services.files.download(file, priority: .requested)
            return
        }
        spinner.stopAnimation(nil)
        let pixels = Int((NSScreen.main?.frame.width ?? 2560) * (NSScreen.main?.backingScaleFactor ?? 2))
        Task { [weak self] in
            guard let self, let image = await services.images.image(path: path, maxPixelSize: pixels) else { return }
            imageView.image = image
        }
    }

    @objc func saveAs(_ sender: Any?) {
        guard let path = services.files.localPath(file), let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Photo \(Date().formatted(.iso8601.year().month().day())).\((path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension)"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

final class VideoPlayerWindowController: NSWindowController, NSWindowDelegate {
    private let playerView = AVPlayerView()

    init(path: String, naturalSize: CGSize) {
        let size = MediaViewers.fitted(naturalSize.width > 0 ? naturalSize : CGSize(width: 1280, height: 720))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Video"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self
        playerView.controlsStyle = .floating
        playerView.player = AVPlayer(url: URL(fileURLWithPath: path))
        window.contentView = playerView
        window.contentAspectRatio = size
        window.center()
        playerView.player?.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
