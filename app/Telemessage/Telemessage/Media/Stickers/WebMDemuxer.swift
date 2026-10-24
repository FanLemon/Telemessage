import Foundation

/// The VP9 frames of a WebM video sticker. Alpha travels in each block's BlockAdditional.
nonisolated struct WebMVideo: Sendable {
    struct Frame: Sendable {
        let timestamp: Double
        let data: Data
        let alpha: Data?
    }

    let width: Int
    let height: Int
    let frames: [Frame]
    /// Seconds per frame.
    let frameDuration: Double
}

/// A small Matroska/EBML reader covering what Telegram video stickers use: one VP9 track, simple
/// or grouped blocks without lacing, optional alpha in BlockAdditions.
nonisolated enum WebMDemuxer {
    enum DemuxError: Error, Equatable {
        case malformed
        case noVP9Track
        case tooLarge
    }

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let timecodeScale: UInt32 = 0x2A_D7B1
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let codecID: UInt32 = 0x86
        static let defaultDuration: UInt32 = 0x23_E383
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let cluster: UInt32 = 0x1F43_B675
        static let timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockAdditions: UInt32 = 0x75A1
        static let blockMore: UInt32 = 0xA6
        static let blockAddID: UInt32 = 0xEE
        static let blockAdditional: UInt32 = 0xA5
    }

    static let maxFrames = 1_200
    static let maxDimension = 2_048

    static func parse(_ data: Data) throws -> WebMVideo {
        var parser = Parser(bytes: [UInt8](data))
        try parser.parse(0..<parser.bytes.count)
        guard let track = parser.videoTrack else { throw DemuxError.noVP9Track }
        guard (1...maxDimension).contains(parser.width), (1...maxDimension).contains(parser.height) else { throw DemuxError.tooLarge }
        let scale = Double(parser.timecodeScale) / 1_000_000_000
        let frames = parser.blocks
            .filter { $0.track == track }
            .map { WebMVideo.Frame(timestamp: Double($0.timecode) * scale, data: $0.data, alpha: $0.alpha) }
        guard !frames.isEmpty else { throw DemuxError.malformed }
        var duration = parser.defaultDuration.map { Double($0) / 1_000_000_000 } ?? 0
        if duration <= 0, frames.count > 1 {
            duration = (frames[frames.count - 1].timestamp - frames[0].timestamp) / Double(frames.count - 1)
        }
        if duration <= 0 || duration > 1 { duration = 1.0 / 30 }
        return WebMVideo(width: parser.width, height: parser.height, frames: frames, frameDuration: duration)
    }

    private struct Block {
        let track: UInt64
        let timecode: Int64
        let data: Data
        var alpha: Data?
    }

    private struct Parser {
        let bytes: [UInt8]
        var timecodeScale: UInt64 = 1_000_000
        var videoTrack: UInt64?
        var width = 0
        var height = 0
        var defaultDuration: UInt64?
        var blocks: [Block] = []
        private var clusterTimecode: Int64 = 0
        private var trackNumber: UInt64 = 0
        private var trackCodec = ""
        private var trackDuration: UInt64?
        private var trackWidth = 0
        private var trackHeight = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parse(_ range: Range<Int>) throws {
            var offset = range.lowerBound
            while offset < range.upperBound {
                let (id, idLength) = try readVint(at: offset, keepMarker: true)
                let (size, sizeLength, unknown) = try readSize(at: offset + idLength)
                let start = offset + idLength + sizeLength
                // Unknown sizes (live-style segments/clusters) extend to the parent's end.
                let end = unknown ? range.upperBound : min(start + Int(clamping: size), range.upperBound)
                guard start <= end else { throw DemuxError.malformed }
                try element(UInt32(truncatingIfNeeded: id), start..<end)
                offset = end
            }
        }

        private mutating func element(_ id: UInt32, _ body: Range<Int>) throws {
            switch id {
            case ID.segment, ID.info, ID.tracks, ID.video, ID.blockAdditions, ID.blockMore:
                try parse(body)
            case ID.ebml:
                break
            case ID.timecodeScale:
                timecodeScale = max(1, readUInt(body))
            case ID.trackEntry:
                trackNumber = 0
                trackCodec = ""
                trackDuration = nil
                trackWidth = 0
                trackHeight = 0
                try parse(body)
                if videoTrack == nil, trackCodec == "V_VP9" {
                    videoTrack = trackNumber
                    width = trackWidth
                    height = trackHeight
                    defaultDuration = trackDuration
                }
            case ID.trackNumber: trackNumber = readUInt(body)
            case ID.codecID: trackCodec = String(decoding: bytes[body], as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            case ID.defaultDuration: trackDuration = readUInt(body)
            case ID.pixelWidth: trackWidth = Int(clamping: readUInt(body))
            case ID.pixelHeight: trackHeight = Int(clamping: readUInt(body))
            case ID.cluster:
                clusterTimecode = 0
                try parse(body)
            case ID.timecode:
                clusterTimecode = Int64(clamping: readUInt(body))
            case ID.simpleBlock, ID.block:
                guard blocks.count < WebMDemuxer.maxFrames else { throw DemuxError.tooLarge }
                if let block = try readBlock(body) { blocks.append(block) }
            case ID.blockGroup:
                let count = blocks.count
                try parse(body)
                // BlockAdditions may precede or follow the Block within its group.
                if blocks.count > count, let alpha = pendingAlpha { blocks[blocks.count - 1].alpha = alpha }
                pendingAlpha = nil
                pendingAddID = 1
            case ID.blockAddID:
                pendingAddID = readUInt(body)
            case ID.blockAdditional:
                if pendingAddID == 1 { pendingAlpha = Data(bytes[body]) }
            default:
                break
            }
        }

        private var pendingAlpha: Data?
        private var pendingAddID: UInt64 = 1

        private func readBlock(_ body: Range<Int>) throws -> Block? {
            let (track, trackLength) = try readVint(at: body.lowerBound, keepMarker: false)
            let header = body.lowerBound + trackLength
            guard header + 3 <= body.upperBound else { throw DemuxError.malformed }
            let relative = Int16(bitPattern: UInt16(bytes[header]) << 8 | UInt16(bytes[header + 1]))
            let flags = bytes[header + 2]
            guard (flags >> 1) & 0x03 == 0 else { return nil }  // laced blocks are not used by stickers
            return Block(track: track, timecode: clusterTimecode + Int64(relative),
                         data: Data(bytes[(header + 3)..<body.upperBound]), alpha: nil)
        }

        private func readVint(at offset: Int, keepMarker: Bool) throws -> (UInt64, Int) {
            guard offset < bytes.count else { throw DemuxError.malformed }
            let first = bytes[offset]
            guard first != 0 else { throw DemuxError.malformed }
            let length = first.leadingZeroBitCount + 1
            guard offset + length <= bytes.count else { throw DemuxError.malformed }
            var value = UInt64(keepMarker ? first : first & (0xFF >> length))
            for index in 1..<length { value = value << 8 | UInt64(bytes[offset + index]) }
            return (value, length)
        }

        private func readSize(at offset: Int) throws -> (UInt64, Int, Bool) {
            let (value, length) = try readVint(at: offset, keepMarker: false)
            let allOnes = (UInt64(1) << (7 * UInt64(length))) - 1
            return (value, length, value == allOnes)
        }

        private func readUInt(_ body: Range<Int>) -> UInt64 {
            bytes[body].prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
    }
}
