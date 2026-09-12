import Accelerate
import CoreGraphics
import Foundation
import Metal

/// `MTLTexture` → `CGImage` for the export path, in row bands.
///
/// ## Why not `SpikeTextureIO.floatPixels(of:queue:)`
///
/// That method is the right one for a golden test: it returns interleaved
/// **float32**, which is what a PSNR wants. For an export it is the wrong shape
/// twice over. At 24 MP a float32 read-back is a 384 MB Swift array *on top of*
/// the 192 MB float16 staging buffer, and on an iPhone that allocation is the
/// difference between an export and a jetsam kill. And the very next thing that
/// happens to those floats is a conversion to 8 or 16 bits, so the wide
/// intermediate buys nothing.
///
/// So this walks the texture in bands: one staging `MTLBuffer` of
/// `bandRows × width` texels is reused for every band, each band is converted
/// straight from float16 to the output depth with vImage, and the only
/// full-size allocation is the output buffer itself (96 MB at 24 MP for 8 bits,
/// 192 MB for 16).
///
/// Row 0 is the top in both a Metal texture and a `CGBitmapContext`, the
/// convention `SpikeTextureIO` documents and `SpikeTextureIOTests`
/// pins — nothing here flips anything.
enum ExportImageBuilder {

    enum Failure: Error, CustomStringConvertible {
        case unsupportedPixelFormat(MTLPixelFormat)
        case cannotAllocateStaging(bytes: Int)
        case cannotMakeImage

        var description: String {
            switch self {
            case .unsupportedPixelFormat(let format):
                "ExportImageBuilder needs an rgba16Float texture, got \(format.rawValue)."
            case .cannotAllocateStaging(let bytes):
                "Could not allocate a \(bytes)-byte read-back band."
            case .cannotMakeImage: "Could not create the output CGImage."
            }
        }
    }

    /// Default band height. 256 rows of a 6000 px frame is a 12 MB staging
    /// buffer — small enough to be irrelevant next to the textures, big enough
    /// that the per-band command buffer overhead disappears.
    static let defaultBandRows = 256

    /// `CGImage` → `rgba16Float` texture, also in bands.
    ///
    /// `SpikeTextureIO.makeTexture(fromFloatPixels:…)` is the same operation for
    /// the preview, and at 2048 px its intermediates are irrelevant. At 24 MP
    /// they are not: a full-frame float32 draw is 384 MB and the float16 copy is
    /// another 192 MB, both alive at once, before the texture itself. Here one
    /// band's float32 buffer and one band's float16 buffer are reused for the
    /// whole image, so the only 24 MP allocation is the texture.
    ///
    /// Bit-identical to the full-frame path: the band context has the same
    /// colour space, the same `floatComponents | byteOrder32Little |
    /// premultipliedLast` layout and the same `.high` interpolation, and the
    /// image is drawn at its native size so no resampling happens at all.
    /// `ExportImageBuilderTests.bandedUploadMatchesTheFullFrameUpload` pins it.
    static func makeTexture(
        from image: CGImage,
        space: SpikeTextureIO.PixelSpace,
        device: any MTLDevice,
        queue: any MTLCommandQueue,
        bandRows: Int = defaultBandRows,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> any MTLTexture {
        let width = image.width
        let height = image.height
        let rows = max(1, min(bandRows, height))
        let texture = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: device, pixelFormat: .rgba16Float,
            usage: usage)

        let componentsPerBand = width * 4 * rows
        var floats = [Float](repeating: 0, count: componentsPerBand)
        var halves = [UInt16](repeating: 0, count: componentsPerBand)
        let bytesPerRow = width * 8
        guard
            let staging = device.makeBuffer(
                length: bytesPerRow * rows, options: .storageModeShared)
        else { throw Failure.cannotAllocateStaging(bytes: bytesPerRow * rows) }

        let bitmapInfo =
            CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        var y = 0
        while y < height {
            let bandHeight = min(rows, height - y)
            let componentCount = width * 4 * bandHeight
            try floats.withUnsafeMutableBytes { raw in
                // Zero the band: a partial last band would otherwise carry the
                // previous band's rows in its tail.
                memset(raw.baseAddress!, 0, componentCount * 4)
                guard
                    let bandContext = CGContext(
                        data: raw.baseAddress, width: width, height: bandHeight,
                        bitsPerComponent: 32, bytesPerRow: width * 16,
                        space: space.cgColorSpace, bitmapInfo: bitmapInfo)
                else { throw Failure.cannotMakeImage }
                bandContext.interpolationQuality = .high
                // CGContext's origin is bottom-left and the band's *top* row is
                // image row `y`, so the image is drawn shifted down by the rows
                // below the band. Derivation: image row i sits at context
                // y = originY + height - 1 - i; wanting row `y` at the band's
                // top row (bandHeight - 1) gives originY = bandHeight - height + y.
                bandContext.draw(
                    image,
                    in: CGRect(
                        x: 0, y: CGFloat(bandHeight - height + y),
                        width: CGFloat(width), height: CGFloat(height)))
            }
            floats.withUnsafeBufferPointer { source in
                halves.withUnsafeMutableBufferPointer { destination in
                    var input = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                        height: 1, width: vImagePixelCount(componentCount),
                        rowBytes: componentCount * 4)
                    var output = vImage_Buffer(
                        data: destination.baseAddress!, height: 1,
                        width: vImagePixelCount(componentCount),
                        rowBytes: componentCount * 2)
                    _ = vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
                }
            }
            halves.withUnsafeBytes { raw in
                staging.contents().copyMemory(
                    from: raw.baseAddress!, byteCount: componentCount * 2)
            }
            guard let commandBuffer = queue.makeCommandBuffer(),
                let blit = commandBuffer.makeBlitCommandEncoder()
            else { throw Failure.cannotMakeImage }
            blit.copy(
                from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                sourceBytesPerImage: bytesPerRow * bandHeight,
                sourceSize: MTLSize(width: width, height: bandHeight, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            y += bandHeight
        }
        return texture
    }

    /// Builds an 8- or 16-bit-per-channel `CGImage` from an `rgba16Float`
    /// texture holding sRGB-encoded values in 0…1.
    ///
    /// Values outside 0…1 are clamped, which is the correct behaviour for a
    /// display-referred export: the pipeline works in `RenderQuality.pixelSpace`
    /// = `.sRGBEncoded` and a JPEG has nowhere to put 1.4.
    static func makeCGImage(
        from texture: any MTLTexture,
        queue: any MTLCommandQueue,
        bitsPerComponent: Int,
        colorSpace: CGColorSpace,
        bandRows: Int = defaultBandRows
    ) throws -> CGImage {
        guard texture.pixelFormat == .rgba16Float else {
            throw Failure.unsupportedPixelFormat(texture.pixelFormat)
        }
        let width = texture.width
        let height = texture.height
        let rows = max(1, min(bandRows, height))
        let sourceBytesPerRow = width * 8
        let stagingBytes = sourceBytesPerRow * rows
        guard
            let staging = texture.device.makeBuffer(
                length: stagingBytes, options: .storageModeShared)
        else { throw Failure.cannotAllocateStaging(bytes: stagingBytes) }

        let bytesPerComponent = bitsPerComponent / 8
        let destinationBytesPerRow = width * 4 * bytesPerComponent
        var output = Data(count: destinationBytesPerRow * height)

        // One float32 scratch band, reused: vImage has no direct 16F → 8U or
        // 16F → 16U converter, so every band goes 16F → F → target.
        var scratch = [Float](repeating: 0, count: width * 4 * rows)

        try output.withUnsafeMutableBytes { raw -> Void in
            guard let base = raw.baseAddress else { throw Failure.cannotMakeImage }
            var y = 0
            while y < height {
                let bandHeight = min(rows, height - y)
                guard let commandBuffer = queue.makeCommandBuffer(),
                    let blit = commandBuffer.makeBlitCommandEncoder()
                else { throw Failure.cannotMakeImage }
                blit.copy(
                    from: texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: y, z: 0),
                    sourceSize: MTLSize(width: width, height: bandHeight, depth: 1),
                    to: staging, destinationOffset: 0,
                    destinationBytesPerRow: sourceBytesPerRow,
                    destinationBytesPerImage: sourceBytesPerRow * bandHeight)
                blit.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                let componentCount = width * 4 * bandHeight
                scratch.withUnsafeMutableBufferPointer { floats in
                    var source = vImage_Buffer(
                        data: staging.contents(), height: 1,
                        width: vImagePixelCount(componentCount),
                        rowBytes: componentCount * 2)
                    var destination = vImage_Buffer(
                        data: floats.baseAddress!, height: 1,
                        width: vImagePixelCount(componentCount),
                        rowBytes: componentCount * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)

                    let outOffset = destinationBytesPerRow * y
                    var floatSource = vImage_Buffer(
                        data: floats.baseAddress!, height: 1,
                        width: vImagePixelCount(componentCount),
                        rowBytes: componentCount * 4)
                    if bytesPerComponent == 1 {
                        var eight = vImage_Buffer(
                            data: base.advanced(by: outOffset), height: 1,
                            width: vImagePixelCount(componentCount),
                            rowBytes: componentCount)
                        _ = vImageConvert_PlanarFtoPlanar8(
                            &floatSource, &eight, 1.0, 0.0, 0)
                    } else {
                        // vImage has no PlanarF → Planar16U (it stops at 8 bits
                        // and at 16F), so the 16-bit path is vDSP: clamp to
                        // 0…1, scale to 0…65535, round to the nearest integer.
                        // Same three steps `vImageConvert_PlanarFtoPlanar8`
                        // performs internally for 8 bits.
                        var low: Float = 0
                        var high: Float = 1
                        var scale: Float = 65535
                        let count = vDSP_Length(componentCount)
                        vDSP_vclip(
                            floats.baseAddress!, 1, &low, &high, floats.baseAddress!, 1, count)
                        vDSP_vsmul(
                            floats.baseAddress!, 1, &scale, floats.baseAddress!, 1, count)
                        vDSP_vfixru16(
                            floats.baseAddress!, 1,
                            base.advanced(by: outOffset).assumingMemoryBound(to: UInt16.self),
                            1, count)
                        _ = floatSource
                    }
                }
                y += bandHeight
            }
        }

        // `noneSkipLast`: the pipeline's alpha is 1 everywhere (the source came
        // from an opaque photo) and an exported JPEG/TIFF should not claim an
        // alpha channel. The fourth component stays in the buffer — dropping it
        // would mean a second full-size repack — and is ignored by CoreGraphics.
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if bytesPerComponent == 2 {
            bitmapInfo.insert(.byteOrder16Little)
        }
        guard let provider = CGDataProvider(data: output as CFData),
            let image = CGImage(
                width: width, height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerComponent * 4,
                bytesPerRow: destinationBytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw Failure.cannotMakeImage }
        return image
    }
}
