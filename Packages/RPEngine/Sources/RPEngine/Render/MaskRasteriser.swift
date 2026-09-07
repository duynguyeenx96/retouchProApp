import CoreGraphics
import Foundation
import Metal

/// Turns every face's ``RenderMask`` of one ``RenderMaskKind`` into a single
/// full-resolution `r8Unorm` coverage texture.
///
/// ## Why this is its own type
/// Both Phase 2 mask-driven groups need exactly this: the "Da" group needs
/// `.skin`, the "Mắt/Răng" group needs `.eyes` **and** `.mouth`. The code is
/// ~80 lines of texture-array upload plus an affine table, and the two failure
/// modes it has to keep out (a per-frame re-upload of a 512² mask, and two faces
/// overwriting each other instead of combining with `max`) are the same for
/// every kind. It was `SkinRenderNode.encodeMask` until the eyes/teeth node
/// needed two more of them.
///
/// One instance rasterises **one kind**. A node that needs two kinds owns two
/// instances, so their caches invalidate independently — an eye mask that has
/// not changed is not re-uploaded because the mouth mask did.
///
/// ## What it costs
/// * one `r8Unorm` full-resolution texture (24 MB at 24 MP) — the output;
/// * one `r8Unorm` 2D array of the *parsing-crop-sized* masks (512² × faces,
///   0.26 MB per face) — the input, uploaded once per distinct mask set and not
///   per frame;
/// * one dispatch per `encode`, which walks the destination and pulls, so N
///   faces cost one pass and overlapping faces combine with `max` rather than
///   with whatever order the CPU submitted them in.
///
/// The kernel is `rp_skin_mask` in `SkinShaders.metal`. Despite the name it has
/// never had anything skin-specific in it — it takes an array of coverage maps
/// and a table of image→mask affines — and it is left where it is (and named
/// what it is named) because renaming a shader function means touching the
/// shipped `SkinRenderNode`, its golden tests and `docs/ADR-0009`'s prose for no
/// behaviour change.
final class MaskRasteriser: @unchecked Sendable {
    /// Which kind of mask this instance reads out of `FaceRenderInput.masks`.
    let kind: RenderMaskKind

    private let context: MetalContext
    private let pipeline: any MTLComputePipelineState
    private let lock = NSLock()
    private var cache: Cache?

    private final class Cache {
        let width: Int
        let height: Int
        /// Full-resolution coverage, 0…1 in `r8Unorm`.
        let output: any MTLTexture
        /// The masks the uploaded array currently holds. Comparing these — and
        /// not the whole `[FaceRenderInput]` — is what keeps an unrelated change
        /// (a landmark moving, another kind's mask being replaced) from
        /// re-uploading this kind's array.
        var masks: [RenderMask] = []
        var array: (any MTLTexture)?
        var transforms: (any MTLBuffer)?

        init(width: Int, height: Int, output: any MTLTexture) {
            self.width = width
            self.height = height
            self.output = output
        }

        var byteCount: Int {
            let slice = masks.first.map { $0.width * $0.height } ?? 0
            return width * height + slice * masks.count
        }
    }

    init(kind: RenderMaskKind, context: MetalContext) throws {
        self.kind = kind
        self.context = context
        self.pipeline = try context.computePipeline("rp_skin_mask")
    }

    /// Bytes of GPU memory held for the current size.
    var allocatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache?.byteCount ?? 0
    }

    /// The texture the most recent ``encode(into:faces:width:height:)`` wrote,
    /// or `nil` before the first one. For the golden harness.
    var output: (any MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.output
    }

    func releaseIntermediates() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
    }

    /// Encodes the rasterisation into `commandBuffer`.
    ///
    /// - Returns: the full-resolution coverage texture, or `nil` when **no** face
    ///   in `faces` carries this kind — in which case nothing is allocated and
    ///   nothing is dispatched. A caller must treat `nil` as "this kind
    ///   contributes zero everywhere"; there is deliberately no all-zero texture
    ///   handed back, because allocating and clearing 24 MB to multiply it by an
    ///   amount that is already 0 is work nobody asked for.
    /// - Throws: ``RenderGraphError/inconsistentMaskSize`` when two faces carry
    ///   masks of different pixel sizes for this kind. They all come from one
    ///   parsing crop size, so that can only be a caller bug, and blending them
    ///   as if they matched would put one face's mask on the wrong scale.
    @discardableResult
    func encode(
        into commandBuffer: any MTLCommandBuffer, faces: [FaceRenderInput],
        width: Int, height: Int
    ) throws -> (any MTLTexture)? {
        let masks = faces.compactMap { $0.masks[kind] }
        guard let first = masks.first else { return nil }
        let expectedWidth: Int = first.width
        let expectedHeight: Int = first.height
        let consistent = masks.allSatisfy { (mask: RenderMask) -> Bool in
            mask.width == expectedWidth && mask.height == expectedHeight
        }
        guard consistent else { throw RenderGraphError.inconsistentMaskSize }

        lock.lock()
        defer { lock.unlock() }

        let cache = try self.cache(width: width, height: height)
        if cache.masks != masks || cache.array == nil {
            try upload(masks, into: cache)
        }
        guard let array = cache.array, let transforms = cache.transforms,
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return cache.output }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(array, index: 0)
        encoder.setTexture(cache.output, index: 1)
        encoder.setBuffer(transforms, offset: 0, index: 0)
        var params = SkinMaskParams(
            imageSize: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            maskSize: SIMD2<UInt32>(UInt32(first.width), UInt32(first.height)),
            faceCount: UInt32(masks.count))
        encoder.setBytes(&params, length: MemoryLayout<SkinMaskParams>.stride, index: 1)
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
        return cache.output
    }

    // MARK: - Resources

    /// Caller must hold ``lock``.
    private func cache(width: Int, height: Int) throws -> Cache {
        if let existing = cache, existing.width == width, existing.height == height {
            return existing
        }
        let output = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .r8Unorm,
            usage: [.shaderRead, .shaderWrite])
        let made = Cache(width: width, height: height, output: output)
        cache = made
        return made
    }

    /// Caller must hold ``lock``. Uploads through a shared staging buffer and one
    /// blit, on its own command buffer, because the masks are `[UInt8]` on the
    /// CPU and a `.private` array texture cannot be written from the host.
    private func upload(_ masks: [RenderMask], into cache: Cache) throws {
        guard let first = masks.first else { return }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r8Unorm
        descriptor.width = first.width
        descriptor.height = first.height
        descriptor.arrayLength = masks.count
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let array = context.device.makeTexture(descriptor: descriptor) else {
            throw RenderGraphError.cannotAllocate(bytes: first.width * first.height * masks.count)
        }
        let sliceBytes = first.width * first.height
        guard
            let staging = context.device.makeBuffer(
                length: sliceBytes * masks.count, options: .storageModeShared)
        else { throw RenderGraphError.cannotAllocate(bytes: sliceBytes * masks.count) }
        let raw = staging.contents()
        for (index, mask) in masks.enumerated() {
            mask.values.withUnsafeBytes {
                raw.advanced(by: index * sliceBytes)
                    .copyMemory(from: $0.baseAddress!, byteCount: sliceBytes)
            }
        }
        guard
            let upload = context.commandQueue.makeCommandBuffer(),
            let blit = upload.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        for index in 0..<masks.count {
            blit.copy(
                from: staging, sourceOffset: index * sliceBytes,
                sourceBytesPerRow: first.width, sourceBytesPerImage: sliceBytes,
                sourceSize: MTLSize(width: first.width, height: first.height, depth: 1),
                to: array, destinationSlice: index, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        upload.commit()
        upload.waitUntilCompleted()

        var transforms: [SkinMaskTransform] = masks.map { mask in
            let t = mask.imageToMask
            return SkinMaskTransform(
                rowX: SIMD3<Float>(Float(t.a), Float(t.c), Float(t.tx)),
                rowY: SIMD3<Float>(Float(t.b), Float(t.d), Float(t.ty)))
        }
        let length = MemoryLayout<SkinMaskTransform>.stride * transforms.count
        guard
            let buffer = context.device.makeBuffer(
                bytes: &transforms, length: length, options: .storageModeShared)
        else { throw RenderGraphError.cannotAllocate(bytes: length) }

        cache.array = array
        cache.transforms = buffer
        cache.masks = masks
    }
}
