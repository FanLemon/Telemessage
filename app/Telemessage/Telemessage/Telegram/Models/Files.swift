import Foundation

// Files and media objects from td_api.tl. Only fields the app uses are decoded.

nonisolated struct TDFile: Decodable, Sendable, Identifiable, Equatable {
    let id: Int32
    var size: Int64
    var expectedSize: Int64
    var local: LocalFile
    var remote: RemoteFile

    nonisolated struct LocalFile: Decodable, Sendable, Equatable {
        var path: String
        var canBeDownloaded: Bool
        var isDownloadingActive: Bool
        var isDownloadingCompleted: Bool
        var downloadedSize: Int64
    }

    nonisolated struct RemoteFile: Decodable, Sendable, Equatable {
        var id: String
        var uniqueID: String
        var isUploadingActive: Bool
        var isUploadingCompleted: Bool
        var uploadedSize: Int64
    }

    /// Local path once the whole file is on disk.
    var completedPath: String? {
        local.isDownloadingCompleted && !local.path.isEmpty ? local.path : nil
    }
}

nonisolated struct Minithumbnail: Decodable, Sendable, Equatable {
    let width: Int32
    let height: Int32
    /// Tiny JPEG, decoded from base64.
    let data: Data
}

nonisolated struct Thumbnail: Decodable, Sendable, Equatable {
    let format: Format
    let width: Int32
    let height: Int32
    let file: TDFile

    /// The constructor name without its `thumbnailFormat` prefix: Jpeg, Png, Webp, Gif, Tgs, Mpeg4, Webm.
    nonisolated struct Format: Decodable, Sendable, Equatable {
        let name: String

        init(name: String) { self.name = name }

        init(from decoder: any Decoder) throws {
            name = String(try TDTypeTag.read(decoder).trimmingPrefix("thumbnailFormat"))
        }

        /// Formats ImageIO decodes to a still image.
        var isImage: Bool { ["Jpeg", "Png", "Webp", "Gif"].contains(name) }
    }
}

nonisolated struct PhotoSize: Decodable, Sendable, Equatable {
    let type: String
    let photo: TDFile
    let width: Int32
    let height: Int32
}

nonisolated struct Photo: Decodable, Sendable, Equatable {
    let minithumbnail: Minithumbnail?
    let sizes: [PhotoSize]
}

nonisolated struct Video: Decodable, Sendable, Equatable {
    let duration: Int32
    let width: Int32
    let height: Int32
    let fileName: String
    let mimeType: String
    let supportsStreaming: Bool
    let minithumbnail: Minithumbnail?
    let thumbnail: Thumbnail?
    let video: TDFile
}

nonisolated struct Animation: Decodable, Sendable, Equatable {
    let duration: Int32
    let width: Int32
    let height: Int32
    let fileName: String
    let mimeType: String
    let minithumbnail: Minithumbnail?
    let thumbnail: Thumbnail?
    let animation: TDFile
}

nonisolated struct Sticker: Decodable, Sendable, Equatable {
    let id: TDInt64
    let setID: TDInt64
    let width: Int32
    let height: Int32
    let emoji: String
    let format: Format
    let thumbnail: Thumbnail?
    let sticker: TDFile

    nonisolated enum Format: Decodable, Sendable, Equatable {
        case webp, tgs, webm
        case unknown(String)

        init(from decoder: any Decoder) throws {
            switch try TDTypeTag.read(decoder) {
            case "stickerFormatWebp": self = .webp
            case "stickerFormatTgs": self = .tgs
            case "stickerFormatWebm": self = .webm
            case let other: self = .unknown(other)
            }
        }
    }
}

nonisolated struct Document: Decodable, Sendable, Equatable {
    let fileName: String
    let mimeType: String
    let minithumbnail: Minithumbnail?
    let thumbnail: Thumbnail?
    let document: TDFile
}

nonisolated struct VoiceNote: Decodable, Sendable, Equatable {
    let duration: Int32
    let waveform: Data
    let mimeType: String
    let voice: TDFile
}

nonisolated struct Audio: Decodable, Sendable, Equatable {
    let duration: Int32
    let title: String
    let performer: String
    let fileName: String
    let mimeType: String
    let audio: TDFile
}

nonisolated struct VideoNote: Decodable, Sendable, Equatable {
    let duration: Int32
    let length: Int32
    let minithumbnail: Minithumbnail?
    let thumbnail: Thumbnail?
    let video: TDFile
}
