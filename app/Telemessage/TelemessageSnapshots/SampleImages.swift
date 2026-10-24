import Cocoa

/// Generated image files standing in for downloaded media.
@MainActor
enum SampleImages {
    static let directory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "telemessage-samples")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func png(_ name: String, size: CGSize, draw: (CGRect) -> Void) -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appending(path: "\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    static var landscape: String {
        png("landscape", size: CGSize(width: 1280, height: 960)) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                       ending: NSColor(srgbRed: 0.35, green: 0.45, blue: 0.85, alpha: 1))?.draw(in: rect, angle: 90)
            NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 820, y: 560, width: 220, height: 220)).fill()
            NSColor(srgbRed: 0.15, green: 0.25, blue: 0.3, alpha: 1).setFill()
            let hills = NSBezierPath()
            hills.move(to: .zero)
            hills.curve(to: CGPoint(x: 1280, y: 260), controlPoint1: CGPoint(x: 400, y: 520), controlPoint2: CGPoint(x: 800, y: 80))
            hills.line(to: CGPoint(x: 1280, y: 0))
            hills.close()
            hills.fill()
        }
    }

    static var sticker: String {
        png("sticker", size: CGSize(width: 512, height: 512)) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 40, dy: 40)).fill()
            NSColor(srgbRed: 0.35, green: 0.2, blue: 0.05, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 170, y: 290, width: 50, height: 70)).fill()
            NSBezierPath(ovalIn: CGRect(x: 292, y: 290, width: 50, height: 70)).fill()
            let smile = NSBezierPath()
            smile.appendArc(withCenter: CGPoint(x: 256, y: 230), radius: 110, startAngle: 200, endAngle: 340)
            smile.lineWidth = 22
            smile.lineCapStyle = .round
            NSColor(srgbRed: 0.35, green: 0.2, blue: 0.05, alpha: 1).setStroke()
            smile.stroke()
        }
    }

    static var poster: String {
        png("poster", size: CGSize(width: 640, height: 360)) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.1, green: 0.5, blue: 0.45, alpha: 1),
                       ending: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.3, alpha: 1))?.draw(in: rect, angle: 30)
        }
    }
}
