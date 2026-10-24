import Accelerate
import CoreGraphics
import CRLottie
import CVPX
import Foundation

/// Produces animation frames in order. Confined to one serial queue by `StickerPlayer`.
nonisolated protocol AnimationFrameSource: AnyObject {
    /// Seconds between frames.
    var frameDelay: Double { get }
    /// The next frame, looping at the end.
    func nextFrame() -> CGImage?
}

/// TGS: gzipped Lottie JSON rendered with rlottie.
nonisolated final class TGSFrameSource: AnimationFrameSource {
    private let animation: OpaquePointer
    private let width: Int
    private let height: Int
    private let totalFrames: Int
    private let step: Int
    private var index = 0
    private var buffer: [UInt32]

    let frameDelay: Double

    static let maxJSONSize = 8 * 1024 * 1024

    init?(path: String, pixelSize: Int) {
        guard let compressed = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              compressed.count <= 2 * 1024 * 1024,
              let json = Gzip.decompress(compressed, maxSize: Self.maxJSONSize) else { return nil }
        let text = String(decoding: json, as: UTF8.self)
        guard let animation = lottie_animation_from_data(text, path, "") else { return nil }
        self.animation = animation
        let frames = lottie_animation_get_totalframe(animation)
        let rate = lottie_animation_get_framerate(animation)
        guard frames > 0, frames < 10_000, rate > 0 else {
            lottie_animation_destroy(animation)
            return nil
        }
        totalFrames = frames
        // Render at most 30 fps; Telegram stickers are usually 60.
        step = max(1, Int((rate / 30).rounded()))
        frameDelay = Double(step) / rate
        let side = max(16, min(pixelSize, 1024))
        width = side
        height = side
        buffer = [UInt32](repeating: 0, count: side * side)
    }

    deinit {
        lottie_animation_destroy(animation)
    }

    func nextFrame() -> CGImage? {
        if index >= totalFrames { index = 0 }
        let frame = index
        index += step
        buffer.withUnsafeMutableBufferPointer { pointer in
            lottie_animation_render(animation, frame, pointer.baseAddress, width, height, width * 4)
        }
        // rlottie writes premultiplied ARGB as native-endian 32-bit words.
        let data = buffer.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One libvpx VP9 decoder instance.
nonisolated final class VP9Decoder {
    private let context: UnsafeMutablePointer<vpx_codec_ctx_t>

    init?() {
        context = .allocate(capacity: 1)
        context.initialize(to: vpx_codec_ctx_t())
        guard tm_vp9_decoder_init(context, 1) == VPX_CODEC_OK else {
            context.deallocate()
            return nil
        }
    }

    deinit {
        vpx_codec_destroy(context)
        context.deallocate()
    }

    /// Decodes one compressed frame. The image is valid until the next call.
    func decode(_ data: Data) -> UnsafeMutablePointer<vpx_image_t>? {
        let status = data.withUnsafeBytes { raw -> vpx_codec_err_t in
            vpx_codec_decode(context, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count), nil, 0)
        }
        guard status == VPX_CODEC_OK else { return nil }
        var iterator: vpx_codec_iter_t?
        return vpx_codec_get_frame(context, &iterator)
    }
}

/// WebM: VP9 color frames plus an optional VP9 alpha stream, composited into premultiplied ARGB.
nonisolated final class WebMFrameSource: AnimationFrameSource {
    private let video: WebMVideo
    private let color: VP9Decoder
    private let alpha: VP9Decoder
    private var index = 0
    private var conversion = vImage_YpCbCrToARGB()

    var frameDelay: Double { video.frameDuration }

    init?(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count <= 4 * 1024 * 1024,
              let video = try? WebMDemuxer.parse(data),
              let color = VP9Decoder(), let alpha = VP9Decoder() else { return nil }
        self.video = video
        self.color = color
        self.alpha = alpha
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &conversion,
                                                            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888,
                                                            vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
    }

    func nextFrame() -> CGImage? {
        if index >= video.frames.count { index = 0 }
        let frame = video.frames[index]
        index += 1
        guard let image = color.decode(frame.data), image.pointee.fmt == VPX_IMG_FMT_I420 else { return nil }
        let alphaImage = frame.alpha.flatMap { alpha.decode($0) }
        return compose(image.pointee, alpha: alphaImage?.pointee)
    }

    private func compose(_ image: vpx_image_t, alpha alphaImage: vpx_image_t?) -> CGImage? {
        let width = Int(image.d_w), height = Int(image.d_h)
        guard width > 0, height > 0, width <= WebMDemuxer.maxDimension, height <= WebMDemuxer.maxDimension,
              let yPlane = image.planes.0, let uPlane = image.planes.1, let vPlane = image.planes.2 else { return nil }
        let rowBytes = width * 4
        var output = Data(count: rowBytes * height)
        let ok = output.withUnsafeMutableBytes { raw -> Bool in
            var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: rowBytes)
            var y = vImage_Buffer(data: yPlane, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                  rowBytes: Int(image.stride.0))
            var u = vImage_Buffer(data: uPlane, height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2),
                                  rowBytes: Int(image.stride.1))
            var v = vImage_Buffer(data: vPlane, height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2),
                                  rowBytes: Int(image.stride.2))
            var permute: [UInt8] = [0, 1, 2, 3]
            guard vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&y, &u, &v, &destination, &conversion, &permute, 255,
                                                         vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            if let alphaImage, Int(alphaImage.d_w) == width, Int(alphaImage.d_h) == height, let alphaPlane = alphaImage.planes.0 {
                // The alpha stream's luma plane is the alpha channel.
                var alphaBuffer = vImage_Buffer(data: alphaPlane, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                                rowBytes: Int(alphaImage.stride.0))
                vImageOverwriteChannels_ARGB8888(&alphaBuffer, &destination, &destination, 0x8, vImage_Flags(kvImageNoFlags))
                vImagePremultiplyData_ARGB8888(&destination, &destination, vImage_Flags(kvImageNoFlags))
            }
            return true
        }
        guard ok, let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
