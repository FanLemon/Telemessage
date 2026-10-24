import Cocoa
import CoreImage
import ImageIO

/// Decodes and downsamples images off the main thread, caching results by path and size.
final class ImageLoader {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    func cachedImage(path: String, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: Self.key(path, maxPixelSize) as NSString)
    }

    /// The image at `path`, downsampled so its longer side is at most `maxPixelSize` pixels.
    func image(path: String, maxPixelSize: Int) async -> NSImage? {
        let key = Self.key(path, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(path: path, maxPixelSize: maxPixelSize)
            }.value
            return decoded.map { NSImage(cgImage: $0, size: .zero) }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    /// A blurred placeholder from a Telegram minithumbnail (a tiny JPEG), decoded synchronously.
    func minithumbnail(_ thumbnail: Minithumbnail) -> NSImage? {
        let key = "mini:\(thumbnail.data.hashValue):\(thumbnail.data.count)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let source = CGImageSourceCreateWithData(thumbnail.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: input.extent)
        guard let output = Self.ciContext.createCGImage(blurred, from: input.extent) else { return nil }
        let result = NSImage(cgImage: output, size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
        cache.setObject(result, forKey: key as NSString, cost: output.width * output.height * 4)
        return result
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private nonisolated static func key(_ path: String, _ size: Int) -> String { "\(size)@\(path)" }

    /// Thumbnail decode that honors EXIF orientation and never loads the full image into memory.
    nonisolated static func decode(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
