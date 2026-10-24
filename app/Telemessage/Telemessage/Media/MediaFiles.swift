import AVFoundation
import Cocoa
import UniformTypeIdentifiers

enum MediaFiles {
    /// The smallest photo size at least `pixels` wide, or the largest available.
    static func bestSize(of photo: Photo, forPixelWidth pixels: CGFloat) -> PhotoSize? {
        let sorted = photo.sizes.sorted { $0.width < $1.width }
        return sorted.first { CGFloat($0.width) >= pixels } ?? sorted.last
    }

    static func largestSize(of photo: Photo) -> PhotoSize? {
        photo.sizes.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Opens a downloaded file with its default app. Executables and installers are only revealed
    /// in Finder: attachments are never run, even on request.
    static func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if isPotentiallyExecutable(url) {
            reveal(path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func isPotentiallyExecutable(_ url: URL) -> Bool {
        if FileManager.default.isExecutableFile(atPath: url.path) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.executable, .application, .applicationBundle, .script, .shellScript, .package, .diskImage]
            .contains { type.conforms(to: $0) }
            || ["pkg", "mpkg", "command", "tool", "workflow", "terminal", "jar"].contains(url.pathExtension.lowercased())
    }

    static func icon(forFileName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    static func duration(_ seconds: Int32) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// One audio/voice message playing at a time across the app.
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    private var player: AVAudioPlayer?
    private(set) var playingPath: String?
    private var observers: [UUID: () -> Void] = [:]
    private var timer: Timer?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    /// Plays `path`, or pauses it when it is already playing. Returns false when the format can't be decoded.
    @discardableResult
    func toggle(_ path: String) -> Bool {
        if playingPath == path, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            notify()
            return true
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return false }
        player.delegate = self
        player.play()
        self.player = player
        playingPath = path
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.notify() }
        }
        notify()
        return true
    }

    func isPlaying(_ path: String) -> Bool { playingPath == path && player?.isPlaying == true }

    func stop() {
        player?.stop()
        player = nil
        playingPath = nil
        timer?.invalidate()
        timer = nil
        notify()
    }

    func observe(_ handler: @escaping () -> Void) -> StoreObservation {
        let id = UUID()
        observers[id] = handler
        return StoreObservation { [weak self] in self?.observers[id] = nil }
    }

    private func notify() {
        for observer in observers.values { observer() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
