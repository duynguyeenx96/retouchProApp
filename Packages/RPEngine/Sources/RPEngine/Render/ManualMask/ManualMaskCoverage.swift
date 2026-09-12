import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// The hand-painted mask itself: one `r8Unorm` coverage texture plus the affine
/// that puts it back on the photo (docs/PLAN.md §6.1).
///
/// ## Why this is a GPU handle and not a `RenderMask`
///
/// `RenderMask` — the value type every *parsed* mask arrives as — carries its
/// coverage as `[UInt8]` on the CPU, which is right for a mask that is produced
/// once per shot by Core ML and then uploaded once. A painted mask is produced
/// **while the user is dragging a finger across it**: a CPU-side value type would
/// mean a texture read-back plus a re-upload of the whole mask on every frame of
/// the drag (2.8 MB each way at a 2048 px preview), to hand the GPU back
/// something it had already computed. So the painted mask lives on the GPU, and
/// the CPU only reads it when it is actually needed on the CPU — once, when the
/// stroke ends and the PNG is written.
///
/// It is a **class**: the stroke rasteriser mutates it in place and the
/// `RenderRequest` that the canvas re-issues 60 times a second refers to the same
/// object rather than copying megabytes. ``generation`` is bumped on every
/// mutation so a caller can tell "the mask changed" from "the same mask again"
/// without comparing pixels.
///
/// ## Ping-pong
///
/// Two textures, not one. `rp_manual_mask_splat` reads one and writes the other
/// (the shader file explains why: `access::read_write` on r8Unorm needs
/// `MTLReadWriteTextureTier2`, which not every Mac has, and read+write bindings
/// of one texture in one dispatch is undefined behaviour). ``texture`` is
/// whichever side currently holds the truth.
public final class ManualMaskCoverage: RenderGateMask, @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Mask pixels (y down) → image pixels (y down). Identity when the mask was
    /// painted at the size of the picture being edited, which is the live-preview
    /// case; a scale when a mask painted on the 2048 px preview is re-used
    /// against the full-resolution frame at export time.
    public var maskToImage: CGAffineTransform
    /// Image pixels → mask pixels. What the shader needs — it walks the image and
    /// has to find the mask sample for each pixel.
    public var imageToMask: CGAffineTransform { maskToImage.inverted() }

    /// Bumped on every mutation. `LivePreviewController` redraws when it moves.
    public private(set) var generation: Int = 0

    private let context: MetalContext
    private let lock = NSLock()
    private var front: any MTLTexture
    private var back: any MTLTexture

    /// Creates an empty (nothing painted) mask.
    ///
    /// - Throws: ``RPEngineFeatureDisabled`` when `RPEngineFeatureFlags.manualMask`
    ///   is off. The gate is here, at the producer, so that with the flag off no
    ///   `RenderRequest` can carry a manual mask at all and every node is
    ///   bit-identical to its pre-Phase-6.1 self.
    public init(context: MetalContext, width: Int, height: Int) throws {
        guard RPEngineFeatureFlags.manualMask else {
            throw RPEngineFeatureDisabled(feature: "manualMask")
        }
        guard width > 0, height > 0 else {
            throw RenderGraphError.cannotAllocate(bytes: 0)
        }
        self.context = context
        self.width = width
        self.height = height
        self.maskToImage = .identity
        self.front = try Self.makeTexture(width: width, height: height, device: context.device)
        self.back = try Self.makeTexture(width: width, height: height, device: context.device)
    }

    /// The texture holding the current coverage.
    public var texture: any MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        return front
    }

    /// Bytes of GPU memory this mask holds (both ping-pong sides).
    public var allocatedBytes: Int { width * height * 2 }

    // MARK: - RenderGateMask
    //
    // The painted mask is one of the gate sources a node can be narrowed by; the
    // others are "Khoá nền"'s subject mask and (§6.2) the full-frame skin mask.
    // See ``RenderGateMask`` for why they share one slot.

    public var gateTexture: any MTLTexture { texture }
    public var gateWidth: Int { width }
    public var gateHeight: Int { height }
    public var gateMaskToImage: CGAffineTransform { maskToImage }
    public var gateGeneration: Int { generation }

    /// The painted mask answers to `manualMask`, and re-reads it on every
    /// encode: this object could only be built while the flag was on, but a
    /// caller may switch it off afterwards, and "off" has to mean "no node is
    /// narrowed" at that moment too, not only at launch.
    public var isGateEnabled: Bool { RPEngineFeatureFlags.manualMask }

    // MARK: - Mutation (package-internal; go through ``ManualMaskSession``)

    /// Hands the caller the read side and the write side, then swaps them.
    ///
    /// Called by ``ManualMaskRasteriser`` once per encoded pass. The swap happens
    /// on the CPU at *encode* time, which is correct because the passes of one
    /// command buffer execute in submission order and Metal's automatic hazard
    /// tracking orders each pass's writes before the next pass's reads.
    func swapping<T>(_ body: (_ source: any MTLTexture, _ destination: any MTLTexture) throws -> T)
        rethrows -> T
    {
        lock.lock()
        let source = front
        let destination = back
        front = destination
        back = source
        generation &+= 1
        lock.unlock()
        return try body(source, destination)
    }

    /// Uploads CPU coverage into the current texture. Off the interaction path:
    /// loading a saved PNG, or seeding a test.
    ///
    /// Through a staging buffer and a blit, on its own command buffer, because
    /// the textures are `.private` (`SpikeTextureIO.makeTexture`'s default) and a
    /// private texture cannot be written from the host — the same route
    /// `MaskRasteriser.upload` takes.
    func upload(_ values: [UInt8]) throws {
        precondition(values.count == width * height, "manual mask buffer size mismatch")
        lock.lock()
        let destination = front
        generation &+= 1
        lock.unlock()
        guard
            let staging = values.withUnsafeBytes({
                context.device.makeBuffer(
                    bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw RenderGraphError.cannotAllocate(bytes: values.count) }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: width,
            sourceBytesPerImage: width * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Read-back

    /// The coverage as `width * height` bytes, row 0 at the top.
    ///
    /// Stalls the GPU — call it when a stroke ends (to write the PNG), not per
    /// frame.
    public func readValues() throws -> [UInt8] {
        let source = texture
        let bytesPerRow = width
        guard
            let buffer = context.device.makeBuffer(
                length: bytesPerRow * height, options: .storageModeShared),
            let commandBuffer = context.commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let raw = UnsafeRawBufferPointer(start: buffer.contents(), count: bytesPerRow * height)
        return [UInt8](raw)
    }

    /// The mask as a compressed 8-bit grayscale PNG — what goes into
    /// `masks/<shot id>/<mask id>.png`.
    public func pngData() throws -> Data {
        try ManualMaskImage.pngData(values: try readValues(), width: width, height: height)
    }

    /// Replaces the coverage with a decoded PNG.
    ///
    /// The PNG's own size wins: a mask painted on a 2048 px preview stays a
    /// 2048 px mask, and ``maskToImage`` is what maps it onto whatever the
    /// picture's size is now. Resampling it here would throw away exactly the
    /// soft edge the brush exists to produce.
    public func load(pngData data: Data) throws {
        let decoded = try ManualMaskImage.decode(pngData: data)
        guard decoded.width == width, decoded.height == height else {
            throw ManualMaskError.sizeMismatch(
                expected: CGSize(width: width, height: height),
                found: CGSize(width: decoded.width, height: decoded.height))
        }
        try upload(decoded.values)
    }

    private static func makeTexture(width: Int, height: Int, device: any MTLDevice) throws
        -> any MTLTexture
    {
        try SpikeTextureIO.makeTexture(
            width: width, height: height, device: device, pixelFormat: .r8Unorm,
            usage: [.shaderRead, .shaderWrite])
    }
}

public enum ManualMaskError: Error, CustomStringConvertible {
    case sizeMismatch(expected: CGSize, found: CGSize)
    case cannotEncodePNG
    case cannotDecodePNG

    public var description: String {
        switch self {
        case .sizeMismatch(let expected, let found):
            "This mask is \(Int(found.width))x\(Int(found.height)) but the picture needs "
                + "\(Int(expected.width))x\(Int(expected.height))."
        case .cannotEncodePNG: "Could not encode the mask as a PNG."
        case .cannotDecodePNG: "Could not read the mask PNG."
        }
    }
}

/// PNG in, PNG out, for an 8-bit single-channel coverage buffer.
///
/// ImageIO rather than `UIImage`/`NSImage`: RPEngine must not import UIKit or
/// AppKit (docs/ADR-0001 §2), and one grayscale PNG needs neither.
enum ManualMaskImage {
    /// Device gray, on both the encode and the decode side.
    ///
    /// The mask is **coverage, not a picture**: 128 means "half selected", not
    /// "mid gray". Any colour-managed space would invite CoreGraphics to apply a
    /// transfer function on one side and not the other, and 0.5 coverage would
    /// come back as 0.73. One unmanaged space used symmetrically round-trips the
    /// bytes exactly — `ManualMaskTests.pngRoundTripIsExact` asserts it.
    static let space = CGColorSpaceCreateDeviceGray()

    static func pngData(values: [UInt8], width: Int, height: Int) throws -> Data {
        precondition(values.count == width * height, "manual mask buffer size mismatch")
        guard let provider = CGDataProvider(data: Data(values) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { throw ManualMaskError.cannotEncodePNG }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw ManualMaskError.cannotEncodePNG }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ManualMaskError.cannotEncodePNG
        }
        return data as Data
    }

    /// Decodes back to one byte per pixel.
    ///
    /// Drawn into an explicit 8-bit gray context rather than trusting the
    /// decoded `CGImage`'s own layout: a PNG that has been through another tool
    /// may come back as RGBA, or with a row stride that is not the width, and a
    /// mask read with the wrong stride is a mask sheared across the frame.
    static func decode(pngData data: Data) throws -> (values: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ManualMaskError.cannotDecodePNG }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ManualMaskError.cannotDecodePNG }
        var values = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = values.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: space,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw ManualMaskError.cannotDecodePNG }
        return (values, width, height)
    }
}
