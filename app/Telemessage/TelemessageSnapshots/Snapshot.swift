import Cocoa
@testable import TelemessageCore

/// A TDLib stand-in that never answers; snapshots feed the store directly.
nonisolated final class SilentTransport: TDTransport {
    func send(_ request: String) {}
    func receive(timeout: Double) -> String? {
        Thread.sleep(forTimeInterval: timeout)
        return nil
    }
}

@MainActor
enum Snapshot {
    static var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    static func makeSession() -> TelegramSession {
        let configuration = TelegramSession.Configuration(
            secrets: TelegramSecrets(apiID: 1, apiHash: "x"),
            dataDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            databaseKey: Data(),
            applicationVersion: "snapshot"
        )
        return TelegramSession(transport: SilentTransport(), configuration: configuration)
    }

    static func update(_ json: String) -> Update {
        do {
            return try TDCoding.decoder.decode(Update.self, from: Data(json.utf8))
        } catch {
            fatalError("Bad sample update: \(error)\n\(json)")
        }
    }

    /// Renders `controller`'s view in a window of `size` (light and dark) to `<name>-light.png` / `-dark.png`.
    static func render(_ name: String, size: NSSize, dark: Bool = false, settle: Double = 0.2,
                       _ makeController: () -> NSViewController) {
        for appearanceName in dark ? [NSAppearance.Name.aqua, .darkAqua] : [.aqua] {
            let controller = makeController()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentViewController = controller
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
            // Let async work (image decoding, deferred layout) finish.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: settle))
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            write(view, appearance: window.appearance!, to: "\(name)-\(appearanceName == .darkAqua ? "dark" : "light").png")
            window.orderOut(nil)
            window.close()
        }
    }

    private static func write(_ view: NSView, appearance: NSAppearance, to fileName: String) {
        let bounds = view.bounds
        guard let content = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: content)
        }
        let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        output.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            content.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = outputDirectory.appending(path: fileName)
        try? output.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
