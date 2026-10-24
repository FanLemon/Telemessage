import Foundation

/// Minimal gzip reader for TGS stickers (gzipped Lottie JSON), with a hard size bound.
nonisolated enum Gzip {
    /// Inflates `data`, or nil if it isn't gzip or would exceed `maxSize` bytes.
    static func decompress(_ data: Data, maxSize: Int) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        let end = bytes.count - 8
        guard offset < end else { return nil }
        // ISIZE: uncompressed length modulo 2^32, little-endian.
        let isize = Int(bytes[end + 4]) | Int(bytes[end + 5]) << 8 | Int(bytes[end + 6]) << 16 | Int(bytes[end + 7]) << 24
        guard isize <= maxSize else { return nil }
        let deflated = Data(bytes[offset..<end]) as NSData
        guard let inflated = try? deflated.decompressed(using: .zlib) as Data, inflated.count <= maxSize else { return nil }
        return inflated
    }
}
