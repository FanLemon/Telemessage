import CoreGraphics
import Foundation
import Testing
@testable import TelemessageCore

/// Fixtures: ball.tgs (orange ball bouncing on a transparent 512×512 canvas, hand-written Lottie)
/// and circle.webm (64×64 VP9 with an alpha stream: opaque red disc of radius 24, transparent corners).
nonisolated enum StickerFixtures {
    static func path(_ name: String) -> String {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!.path
    }

    /// RGBA of the pixel at (x, y), y measured from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (data[0], data[1], data[2], data[3])
    }
}

struct GzipTests {
    @Test func inflatesTGS() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: StickerFixtures.path("ball.tgs")))
        let json = try #require(Gzip.decompress(data, maxSize: 1_000_000))
        #expect(String(decoding: json.prefix(1), as: UTF8.self) == "{")
    }

    @Test func refusesOversizedOrInvalidInput() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: StickerFixtures.path("ball.tgs")))
        #expect(Gzip.decompress(data, maxSize: 64) == nil)
        #expect(Gzip.decompress(Data("not gzip at all, just text".utf8), maxSize: 1_000) == nil)
        #expect(Gzip.decompress(data.prefix(12), maxSize: 1_000_000) == nil)
    }
}

struct TGSTests {
    @Test func rendersTransparentAnimatedFrames() throws {
        let source = try #require(TGSFrameSource(path: StickerFixtures.path("ball.tgs"), pixelSize: 128))
        #expect(abs(source.frameDelay - 2.0 / 60) < 0.001)  // 60 fps source rendered at 30 fps
        let first = try #require(source.nextFrame())
        #expect(first.width == 128)
        // Frame 0: ball centered at (64, 32) with radius 25 at this scale.
        let ball = StickerFixtures.pixel(first, x: 64, y: 32)
        #expect(ball.a > 200)
        #expect(ball.r > ball.b)
        #expect(StickerFixtures.pixel(first, x: 3, y: 124).a == 0)
        // Half a second later the ball has moved down; its old spot is transparent.
        for _ in 0..<14 { _ = source.nextFrame() }
        let middle = try #require(source.nextFrame())
        #expect(StickerFixtures.pixel(middle, x: 64, y: 32).a == 0)
        #expect(StickerFixtures.pixel(middle, x: 64, y: 96).a > 200)
    }

    @Test func rejectsNonTGS() {
        #expect(TGSFrameSource(path: StickerFixtures.path("circle.webm"), pixelSize: 64) == nil)
    }
}

struct WebMTests {
    @Test func demuxesVP9WithAlpha() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: StickerFixtures.path("circle.webm")))
        let video = try WebMDemuxer.parse(data)
        #expect(video.width == 64)
        #expect(video.height == 64)
        #expect(video.frames.count == 15)
        #expect(video.frames.allSatisfy { $0.alpha != nil })
        #expect(abs(video.frameDuration - 1.0 / 30) < 0.005)
    }

    @Test func decodesColorAndAlpha() throws {
        let source = try #require(WebMFrameSource(path: StickerFixtures.path("circle.webm")))
        let frame = try #require(source.nextFrame())
        let center = StickerFixtures.pixel(frame, x: 32, y: 32)
        #expect(center.a > 240)
        #expect(center.r > 200)
        #expect(center.g < 60)
        #expect(StickerFixtures.pixel(frame, x: 2, y: 2).a < 16)
        // Loops past the end without failing.
        for _ in 0..<40 { #expect(source.nextFrame() != nil) }
    }

    @Test func malformedInputFailsSafely() throws {
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(Data([0x1A, 0x45, 0xDF, 0xA3, 0x88])) }
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(Data(repeating: 0, count: 64)) }
        let data = try Data(contentsOf: URL(fileURLWithPath: StickerFixtures.path("circle.webm")))
        // Truncation must not crash; it may yield fewer frames or an error.
        for length in stride(from: 10, to: data.count, by: 97) {
            _ = try? WebMDemuxer.parse(data.prefix(length))
        }
    }
}
