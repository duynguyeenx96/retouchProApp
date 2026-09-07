import Accelerate
import CoreGraphics
import Foundation
import Metal

/// CGImage ↔ MTLTexture for the Phase 0 spike S3 harness, with the pixel value
/// space made explicit.
///
/// **Deliberately not Core Image.** `CIImage(mtlTexture:)` and
/// `CIContext.render(_:to:)` disagree with `CGImage` about which end of the
/// buffer row 0 is, and a silent vertical flip in a *measurement* harness is
/// exactly the class of bug that makes a warp number meaningless. This path is
/// CoreGraphics + vImage only: a `CGBitmapContext` lays out row 0 at the top,
/// a Metal texture's `(0, 0)` is the top-left texel, so the two agree by
/// construction and `SpikeTextureIOTests.roundTripKeepsOrientation` pins it.
public enum SpikeTextureIO {
    /// What the numbers inside the texture *mean*.
    ///
    /// The guided filter's `epsilon` is a variance threshold on these values, so
    /// the same `epsilon` behaves differently in the two spaces: in linear light
    /// a mid-grey edge has ~2.2× less numerical contrast than in sRGB. Phase 2
    /// has to pick one and stay there; spike S3 measures the difference rather
    /// than assuming it is small.
    public enum PixelSpace: String, Sendable, CaseIterable {
        /// sRGB with its transfer function applied — display-referred values in
        /// 0…1. This is what the Photoshop panel (`panelpts/commands.js`) that
        /// the retouch logic is ported from operated on.
        case sRGBEncoded
        /// Linear-light sRGB primaries, extended range. What `CIRAWFilter`
        /// produces before an output transfer function is applied.
        case linearSRGB

        public var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGBEncoded:
                CGColorSpace(name: CGColorSpace.sRGB)!
            case .linearSRGB:
                CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotMakeBitmapContext
        case cannotMakeTexture

        public var description: String {
            switch self {
            case .cannotMakeBitmapContext: "Could not create the float32 CGBitmapContext."
            case .cannotMakeTexture: "Could not create the MTLTexture."
            }
        }
    }

    /// Interleaved RGBA float32, row 0 at the top.
    public static func floatPixels(
        of image: CGImage, space: PixelSpace, width: Int? = nil, height: Int? = nil
    ) throws -> (pixels: [Float], width: Int, height: Int) {
        let w = width ?? image.width
        let h = height ?? image.height
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let bitmapInfo =
            CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        try pixels.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32,
                    bytesPerRow: w * 16, space: space.cgColorSpace, bitmapInfo: bitmapInfo)
            else { throw Failure.cannotMakeBitmapContext }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (pixels, w, h)
    }

    /// RGBA16Float texture from interleaved RGBA float32, row 0 at the top.
    public static func makeTexture(
        fromFloatPixels pixels: [Float],
        width: Int,
        height: Int,
        device: any MTLDevice,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
    ) throws -> any MTLTexture {
        let halves = float32ToFloat16(pixels)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.cannotMakeTexture
        }
        // .private storage cannot be written from the CPU, so stage through a
        // shared buffer and blit. On Apple silicon this is a copy inside the
        // same memory, but it keeps the same code path valid on a discrete GPU.
        let bytesPerRow = width * 8
        guard
            let staging = halves.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }),
            let queue = device.makeCommandQueue(),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw Failure.cannotMakeTexture }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// Empty RGBA16Float texture of the same shape.
    public static func makeTexture(
        width: Int, height: Int, device: any MTLDevice,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget],
        storageMode: MTLStorageMode = .private
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.cannotMakeTexture
        }
        return texture
    }

    /// Reads an RGBA16Float texture back as interleaved float32, row 0 at the top.
    public static func floatPixels(
        of texture: any MTLTexture, queue: any MTLCommandQueue
    ) throws -> [Float] {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw Failure.cannotMakeTexture }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var halves = [UInt16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(
                start: buffer.contents(), count: bytesPerRow * height))
        }
        return float16ToFloat32(halves)
    }

    // MARK: - float16 <-> float32

    public static func float32ToFloat16(_ input: [Float]) -> [UInt16] {
        var output = [UInt16](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                    width: vImagePixelCount(input.count), rowBytes: input.count * 4)
                var destination = vImage_Buffer(
                    data: dst.baseAddress!, height: 1,
                    width: vImagePixelCount(input.count), rowBytes: input.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0)
            }
        }
        return output
    }

    public static func float16ToFloat32(_ input: [UInt16]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                    width: vImagePixelCount(input.count), rowBytes: input.count * 2)
                var destination = vImage_Buffer(
                    data: dst.baseAddress!, height: 1,
                    width: vImagePixelCount(input.count), rowBytes: input.count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
        }
        return output
    }

    /// PSNR in dB between two interleaved RGBA float32 buffers, over RGB only.
    /// `.infinity` when the buffers are identical.
    public static func psnr(_ a: [Float], _ b: [Float], peak: Double = 1.0) -> Double {
        precondition(a.count == b.count)
        var sum = 0.0
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 {
                let d = Double(a[i + c]) - Double(b[i + c])
                sum += d * d
                n += 1
            }
        }
        guard n > 0 else { return .infinity }
        let mse = sum / Double(n)
        if mse == 0 { return .infinity }
        return 10 * log10(peak * peak / mse)
    }

    /// Largest absolute RGB difference between two interleaved buffers.
    public static func maxAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var worst = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 {
                worst = max(worst, abs(Double(a[i + c]) - Double(b[i + c])))
            }
        }
        return worst
    }
}
