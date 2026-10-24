import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An outgoing file, copied into app-owned staging and inspected.
nonisolated struct PreparedAttachment: Sendable, Identifiable, Equatable {
    enum Kind: Sendable, Equatable {
        case photo, video, document
    }

    let id: UUID
    let kind: Kind
    let fileName: String
    /// The staged copy of the original; sent when "Send as files" is chosen.
    let originalPath: String
    /// What to upload as a photo/video (converted when needed); equals `originalPath` for documents.
    let mediaPath: String
    let width: Int32
    let height: Int32
    let duration: Int32
    /// A JPEG at most 320 px on its longer side, used as the upload thumbnail and tray preview.
    let thumbnailPath: String?
    let thumbnailSize: CGSize
    let byteCount: Int64

    var allPaths: [String] { Array(Set([originalPath, mediaPath] + (thumbnailPath.map { [$0] } ?? []))) }

    /// The message content to send; `asFile` sends the original as a document.
    func content(asFile: Bool, caption: FormattedText) -> InputMessageContent {
        let thumbnail = thumbnailPath.map {
            InputMessageContent.InputThumbnail(path: $0, width: Int32(thumbnailSize.width), height: Int32(thumbnailSize.height))
        }
        if asFile || kind == .document {
            return .document(path: originalPath, thumbnail: thumbnail, caption: caption)
        }
        switch kind {
        case .photo: return .photo(path: mediaPath, thumbnail: nil, width: width, height: height, caption: caption)
        case .video: return .video(path: mediaPath, thumbnail: thumbnail, duration: duration, width: width, height: height, caption: caption)
        case .document: return .document(path: originalPath, thumbnail: thumbnail, caption: caption)
        }
    }

    /// Paths TDLib will read for `asFile`; the rest can be deleted once sent.
    func uploadPaths(asFile: Bool) -> [String] {
        let main = asFile || kind == .document ? originalPath : mediaPath
        return Array(Set([main] + (thumbnailPath.map { [$0] } ?? [])))
    }
}

nonisolated enum AttachmentPreparer {
    enum PreparationError: LocalizedError {
        case unreadable(String)
        case tooLarge(String)
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” couldn't be read."
            case .tooLarge(let name): "“\(name)” is larger than Telegram's 2 GB limit."
            case .conversionFailed(let name): "“\(name)” couldn't be prepared for sending."
            }
        }
    }

    static let maxFileSize: Int64 = 2_000 * 1024 * 1024
    /// Telegram's photo limits: at most 10 MB and width + height at most 10,000.
    static let maxPhotoBytes: Int64 = 10 * 1024 * 1024
    static let maxPhotoSide = 2_560

    /// Copies `source` into `stagingDirectory` and prepares it. Call off the main thread.
    static func prepare(source: URL, stagingDirectory: URL) async throws -> PreparedAttachment {
        let name = source.lastPathComponent
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { throw PreparationError.unreadable(name) }
        let size = Int64(values?.fileSize ?? 0)
        guard size <= maxFileSize else { throw PreparationError.tooLarge(name) }

        let id = UUID()
        let folder = stagingDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appending(path: name)
        do {
            try FileManager.default.copyItem(at: source, to: original)
        } catch {
            throw PreparationError.unreadable(name)
        }
        let type = values?.contentType ?? UTType(filenameExtension: source.pathExtension) ?? .data
        do {
            if type.conforms(to: .image), !type.conforms(to: .gif) {
                return try preparePhoto(id: id, original: original, folder: folder, type: type, size: size)
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return try await prepareVideo(id: id, original: original, folder: folder, size: size)
            }
        } catch {
            // Media that can't be interpreted still goes out as a file.
        }
        return document(id: id, original: original, size: size)
    }

    /// Stages pasted image data (e.g. a screenshot on the clipboard) as a PNG photo.
    static func prepare(imageData: Data, stagingDirectory: URL) async throws -> PreparedAttachment {
        let id = UUID()
        let folder = stagingDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Pasted Image \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "."))"
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PreparationError.unreadable("Pasted image") }
        let original = folder.appending(path: "\(name).png")
        try write(image, to: original, type: .png)
        let size = Int64((try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return try preparePhoto(id: id, original: original, folder: folder, type: .png, size: size)
    }

    // MARK: Photos

    private static func preparePhoto(id: UUID, original: URL, folder: URL, type: UTType, size: Int64) throws -> PreparedAttachment {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PreparationError.unreadable(original.lastPathComponent)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5–8 rotate by 90°, swapping width and height.
        var (width, height) = orientation >= 5 ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
        var mediaPath = original.path
        let sendable = (type.conforms(to: .jpeg) || type.conforms(to: .png)) && orientation == 1
            && size <= maxPhotoBytes && max(width, height) <= maxPhotoSide * 2 && width + height <= 10_000
        if !sendable {
            // Re-encode as an upright JPEG Telegram accepts as a photo.
            guard let upright = thumbnail(source, maxPixels: maxPhotoSide) else {
                throw PreparationError.conversionFailed(original.lastPathComponent)
            }
            let converted = folder.appending(path: "photo.jpg")
            try write(upright, to: converted, type: .jpeg, quality: 0.88)
            mediaPath = converted.path
            width = upright.width
            height = upright.height
        }
        let (thumbPath, thumbSize) = try makeThumbnail(source: source, folder: folder)
        return PreparedAttachment(id: id, kind: .photo, fileName: original.lastPathComponent, originalPath: original.path,
                                  mediaPath: mediaPath, width: Int32(width), height: Int32(height), duration: 0,
                                  thumbnailPath: thumbPath, thumbnailSize: thumbSize, byteCount: size)
    }

    // MARK: Videos

    private static func prepareVideo(id: UUID, original: URL, folder: URL, size: Int64) async throws -> PreparedAttachment {
        let asset = AVURLAsset(url: original)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreparationError.unreadable(original.lastPathComponent)
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = naturalSize.applying(transform)
        let duration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let isMP4 = ["mp4", "m4v"].contains(original.pathExtension.lowercased())
        let isCompatibleCodec = codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC

        var mediaPath = original.path
        if !(isMP4 && isCompatibleCodec) {
            let output = folder.appending(path: "video.mp4")
            let rewrapped = isCompatibleCodec ? try? await export(asset, preset: AVAssetExportPresetPassthrough, to: output) : nil
            if rewrapped == nil {
                try? FileManager.default.removeItem(at: output)
                guard (try? await export(asset, preset: AVAssetExportPreset1920x1080, to: output)) != nil else {
                    throw PreparationError.conversionFailed(original.lastPathComponent)
                }
            }
            mediaPath = output.path
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        var thumbPath: String?
        var thumbSize = CGSize.zero
        if let frame = try? await generator.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)).image {
            let url = folder.appending(path: "thumbnail.jpg")
            try write(frame, to: url, type: .jpeg, quality: 0.8)
            thumbPath = url.path
            thumbSize = CGSize(width: frame.width, height: frame.height)
        }
        return PreparedAttachment(id: id, kind: .video, fileName: original.lastPathComponent, originalPath: original.path,
                                  mediaPath: mediaPath, width: Int32(abs(oriented.width)), height: Int32(abs(oriented.height)),
                                  duration: Int32(duration.rounded()), thumbnailPath: thumbPath, thumbnailSize: thumbSize,
                                  byteCount: size)
    }

    private static func export(_ asset: AVAsset, preset: String, to url: URL) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw PreparationError.conversionFailed(url.lastPathComponent)
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: url, as: .mp4)
        return url
    }

    // MARK: Documents

    private static func document(id: UUID, original: URL, size: Int64) -> PreparedAttachment {
        var thumbPath: String?
        var thumbSize = CGSize.zero
        // Images sent as files still get a preview thumbnail.
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           let made = try? makeThumbnail(source: source, folder: original.deletingLastPathComponent()) {
            thumbPath = made.0
            thumbSize = made.1
        }
        return PreparedAttachment(id: id, kind: .document, fileName: original.lastPathComponent, originalPath: original.path,
                                  mediaPath: original.path, width: 0, height: 0, duration: 0,
                                  thumbnailPath: thumbPath, thumbnailSize: thumbSize, byteCount: size)
    }

    // MARK: Image helpers

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    private static func makeThumbnail(source: CGImageSource, folder: URL) throws -> (String, CGSize) {
        guard let image = thumbnail(source, maxPixels: 320) else { throw PreparationError.conversionFailed("thumbnail") }
        let url = folder.appending(path: "thumbnail.jpg")
        try write(image, to: url, type: .jpeg, quality: 0.8)
        return (url.path, CGSize(width: image.width, height: image.height))
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 1) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PreparationError.conversionFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.conversionFailed(url.lastPathComponent) }
    }
}

/// Splits attachments into sendable groups: up to 10 consecutive photos/videos per album, up to
/// 10 consecutive documents per album, preserving order.
nonisolated enum AlbumGrouping {
    static func groups(_ attachments: [PreparedAttachment], asFiles: Bool) -> [[PreparedAttachment]] {
        var groups: [[PreparedAttachment]] = []
        for attachment in attachments {
            let isDocument = asFiles || attachment.kind == .document
            if let last = groups.last, last.count < 10,
               let first = last.first, (asFiles || first.kind == .document) == isDocument {
                groups[groups.count - 1].append(attachment)
            } else {
                groups.append([attachment])
            }
        }
        return groups
    }
}
