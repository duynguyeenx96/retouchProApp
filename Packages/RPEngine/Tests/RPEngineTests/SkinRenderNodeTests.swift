import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 golden tests for the "Da" slider group.
///
/// docs/PLAN.md Phase 2 sets the bar: **golden render PSNR ≥ 45 dB**. The
/// control is `SkinReference`, a `Double` CPU implementation written from the
/// specification rather than from the shader, in the same arrangement spike S3
/// used for `GuidedFilter` (`SpikeS3Support.referenceGuidedFilter`).
///
/// Three levels, so a failure says *where*:
/// 1. `rp_skin_mask` against a `Double` affine + bilinear + max;
/// 2. `rp_skin_composite` fed the **GPU's own** `base`/`low` layers, which
///    isolates the composite from the guided filter;
/// 3. the whole node against the whole reference.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 skin sliders", .serialized)
struct SkinRenderNodeTests {
    static let width = 320
    static let height = 240

    /// The image, already quantised to half-float. The GPU reads an rgba16Float
    /// source, so a reference starting from the unquantised values would be
    /// charged 5e-4 of upload rounding that the kernel did not cause.
    static let source: [Float] = SpikeTextureIO.float16ToFloat32(
        SpikeTextureIO.float32ToFloat16(
            SpikeS3Support.syntheticImage(width: width, height: height, seed: 4242)))

    static var face: FaceRenderInput {
        SkinReference.face(imageWidth: width, imageHeight: height, faceWidth: 120)
    }

    /// Every slider at a mid value, so no term of the composite is skipped.
    static let allSliders = SkinSliders(
        smooth: 70, keepTexture: 30, evenTone: 45, redness: 55, shine: 60,
        brighten: 35, darkCircle: 50, wrinkle: 40)

    static func request(_ sliders: SkinSliders, faces: [FaceRenderInput]? = nil) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        return RenderRequest(
            editState: state, faces: faces ?? [face], quality: .preview)
    }

    // MARK: - Layout

    @Test("Shader parameter structs have the layout SkinShaders.metal declares")
    func parameterStructsMatchShaderLayout() {
        #expect(MemoryLayout<SkinMaskParams>.stride == 24)  // uint2, uint2, uint
        #expect(MemoryLayout<SkinMaskTransform>.stride == 32)  // float3, float3
        #expect(MemoryLayout<SkinCompositeParams>.stride == 40)  // uint2 + 8 floats
    }

    // MARK: - 1. Mask rasterisation

    @Test("rp_skin_mask matches a Double affine + bilinear reference")
    func maskRasterisationMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        let node = try SkinRenderNode(context: context)
        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        let layers = try #require(node.debugLayers())
        let measured = try Self.readR8(layers.mask, queue: context.commandQueue)
        let reference = SkinReference.rasterisedMask(
            faces: [Self.face], width: Self.width, height: Self.height)

        var worst = 0.0
        for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
        print("P2 skin mask vs Double reference: max abs diff = \(worst)")
        // r8Unorm quantises to 1/255 = 3.9e-3; the mask source is already 8-bit,
        // so the only new error is the bilinear tap in float32 plus that one
        // rounding step. 6e-3 can only fail on a wrong transform, which shifts
        // the mask by whole pixels and lands far above this.
        #expect(worst < 6e-3, "max abs diff \(worst)")

        // A wrong transform can also produce a *plausible* small error if it is
        // nearly right, so assert the mask is actually somewhere: it must cover
        // part of the frame and not all of it.
        let coverage = measured.reduce(0, +) / Double(measured.count)
        #expect(coverage > 0.05 && coverage < 0.95, "mask coverage \(coverage)")
    }

    @Test("A mask that is 0 everywhere leaves every pixel bit-exact")
    func zeroMaskIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        var blank = Self.face
        let mask = try #require(blank.masks[.skin])
        blank.masks[.skin] = RenderMask(
            width: mask.width, height: mask.height,
            values: [UInt8](repeating: 0, count: mask.values.count),
            maskToImage: mask.maskToImage)

        let node = try SkinRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [blank]))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    @Test("All sliders at 0 is a bit-exact identity even with a full mask")
    func allSlidersZeroIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        let node = try SkinRenderNode(context: context)
        // Straight at the node, bypassing RenderGraph's isActive short-circuit,
        // so this tests the kernel's own 0-handling and not the graph's.
        let output = try Self.runNode(
            node, context: context, request: Self.request(SkinSliders()))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    // MARK: - 2. Composite

    @Test("rp_skin_composite matches a Double reference fed the GPU's own layers")
    func compositeMatchesReferenceOnItsOwnLayers() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        let node = try SkinRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(Self.allSliders))
        let layers = try #require(node.debugLayers())
        let base = try Self.layerPixels(layers.base, context: context)
        let low = try Self.layerPixels(layers.low, context: context)
        let mask = try Self.readR8(layers.mask, queue: context.commandQueue)

        let reference = SkinReference.composite(
            source: Self.source, base: base, low: low, mask: mask,
            amounts: SkinReference.Amounts(Self.allSliders))
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 skin composite vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "composite PSNR \(psnr) dB")
    }

    /// Each slider on its own, so an error in one term cannot be hidden by the
    /// others' magnitude in the combined PSNR.
    @Test(
        "Each Da slider alone matches the reference",
        arguments: [
            ("smooth", SkinSliders(smooth: 100)),
            ("smooth+keepTexture", SkinSliders(smooth: 100, keepTexture: 60)),
            ("evenTone", SkinSliders(evenTone: 100)),
            ("redness", SkinSliders(redness: 100)),
            ("shine", SkinSliders(shine: 100)),
            ("brighten", SkinSliders(brighten: 100)),
            ("darkCircle", SkinSliders(darkCircle: 100)),
            ("wrinkle", SkinSliders(wrinkle: 100)),
        ])
    func eachSliderAloneMatchesReference(name: String, sliders: SkinSliders) throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        let node = try SkinRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(sliders))
        let layers = try #require(node.debugLayers())
        let base = try Self.layerPixels(layers.base, context: context)
        let low = try Self.layerPixels(layers.low, context: context)
        let mask = try Self.readR8(layers.mask, queue: context.commandQueue)
        let reference = SkinReference.composite(
            source: Self.source, base: base, low: low, mask: mask,
            amounts: SkinReference.Amounts(sliders))

        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 skin slider '\(name)' vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "\(name) PSNR \(psnr) dB")

        // …and it must actually do something, or a PSNR of infinity would pass.
        let change = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        #expect(change > 1e-3, "\(name) changed the picture by only \(change)")
    }

    /// An identity that holds independently of both the reference and the
    /// guided filter: `S + (I − S) · 1 == I`, so full smoothing with texture
    /// fully preserved is the original picture.
    @Test("smooth = 100 with keepTexture = 100 returns the original")
    func fullTextureCancelsSmoothing() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        let node = try SkinRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context,
            request: Self.request(SkinSliders(smooth: 100, keepTexture: 100)))
        let worst = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        print("P2 skin smooth=100 keepTexture=100 vs source: max abs diff = \(worst)")
        // Not exact: `base` is stored as half-float, so `S + (I − S)` reassembles
        // I from a rounded S. 1e-3 is ~2x half-float spacing at these values.
        #expect(worst < 1e-3, "max abs diff \(worst)")
    }

    // MARK: - 3. Whole node

    @Test("The whole Da node matches the whole Double reference at ≥ 45 dB")
    func wholeNodeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        let graph = try RenderGraph.standard(context: context)
        let (output, report) = try graph.renderPixels(
            Self.source, width: Self.width, height: Self.height,
            request: Self.request(Self.allSliders))
        #expect(report.nodes == ["skin"])

        let reference = SkinReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders,
            subsample: RenderQuality.preview.guidedSubsample)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 skin node end-to-end vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "end-to-end PSNR \(psnr) dB")
    }

    /// Two faces must combine with `max`, not with submission order, and the
    /// second face must not overwrite the first.
    @Test("Two overlapping faces combine their masks with max")
    func twoFacesCombineWithMax() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        var second = Self.face
        let mask = try #require(second.masks[.skin])
        second.masks[.skin] = RenderMask(
            width: mask.width, height: mask.height, values: mask.values,
            maskToImage: mask.maskToImage.concatenating(
                CGAffineTransform(translationX: 90, y: 25)))

        let node = try SkinRenderNode(context: context)
        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [Self.face, second]))
        let layers = try #require(node.debugLayers())
        let measured = try Self.readR8(layers.mask, queue: context.commandQueue)
        let reference = SkinReference.rasterisedMask(
            faces: [Self.face, second], width: Self.width, height: Self.height)
        var worst = 0.0
        for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
        print("P2 skin two-face mask vs Double reference: max abs diff = \(worst)")
        #expect(worst < 6e-3, "max abs diff \(worst)")

        // The property under test, stated directly: the union is the elementwise
        // max of the two faces taken separately. A `sum` comparison would also
        // pass if the second mask replaced part of the first.
        let a = SkinReference.rasterisedMask(
            faces: [Self.face], width: Self.width, height: Self.height)
        let b = SkinReference.rasterisedMask(
            faces: [second], width: Self.width, height: Self.height)
        var unionError = 0.0
        for i in 0..<a.count { unionError = max(unionError, abs(max(a[i], b[i]) - measured[i])) }
        #expect(unionError < 6e-3, "union != elementwise max, worst \(unionError)")
        // …and the two faces really do land in different places, or the above is
        // vacuous.
        #expect(measured.reduce(0, +) > a.reduce(0, +) * 1.1)
        #expect(measured.reduce(0, +) > b.reduce(0, +) * 1.1)
    }

    // MARK: - Quality → guided-filter subsample

    /// Regression test for the hardcoded `.preview` in `cache(width:height:)`.
    ///
    /// The node used to size its `GuidedFilter.Resources` from
    /// `RenderQuality.preview.guidedSubsample` while `encode` took the box radius
    /// from `request.quality.guidedSubsample`. `GuidedFilter.encode` reads the
    /// grid size out of `Resources` and the radius out of `Options`, so the two
    /// have to agree; they only did because `guidedSubsample` is 4 for both
    /// qualities today. ADR-0007/0009 flag splitting that constant by quality as
    /// plausible future work (`subsample` is a memory-driven parameter), and the
    /// day it splits, an export would filter a preview-sized grid with export's
    /// radius — wrong pixels, no crash.
    ///
    /// `SkinRenderNode`'s internal `subsampleForQuality` seam is what lets this
    /// test stand in that future without editing the shipped constant.
    @Test("The guided-filter cache follows the request's quality, not a fixed preview constant")
    func cacheFollowsTheRequestQuality() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        // The hypothetical split: export buys a finer grid than preview.
        let node = try SkinRenderNode(
            context: context, subsampleForQuality: { $0 == .preview ? 4 : 2 })

        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        #expect(node.debugGuidedSubsample == 4)

        var export = Self.request(Self.allSliders)
        export.quality = .export
        _ = try Self.runNode(node, context: context, request: export)
        // Under the old code this read 4: the resources were built once from
        // `.preview` and handed to every later quality unchanged.
        #expect(node.debugGuidedSubsample == 2)

        // …and back, so the cache invalidates in both directions rather than
        // sticking on whichever quality rendered first.
        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        #expect(node.debugGuidedSubsample == 4)
    }

    /// The bookkeeping above only matters if the pixels follow it, so this runs
    /// the whole node at `s = 2` and scores it against the `Double` reference at
    /// `s = 2`. Under the old code the GPU would have run a 4-subsampled grid
    /// with a 2-subsampled radius and missed this reference.
    @Test("Rendering at a non-default subsample still matches the Double reference")
    func alternateSubsampleMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        let node = try SkinRenderNode(context: context, subsampleForQuality: { _ in 2 })
        var export = Self.request(Self.allSliders)
        export.quality = .export
        let output = try Self.runNode(node, context: context, request: export)
        #expect(node.debugGuidedSubsample == 2)

        let reference = SkinReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders, subsample: 2)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 skin node at s=2 vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "s=2 PSNR \(psnr) dB")

        // And it is genuinely a different render from the s=4 one, or the test
        // would pass with the subsample ignored entirely.
        let atFour = SkinReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders, subsample: 4)
        #expect(SpikeTextureIO.maxAbsoluteDifference(atFour, reference) > 1e-3)
    }

    @Test("Masks of different sizes in one request are rejected, not blended wrong")
    func inconsistentMaskSizesThrow() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        let odd = SkinReference.face(
            imageWidth: Self.width, imageHeight: Self.height, maskSide: 32)
        let node = try SkinRenderNode(context: context)
        #expect(throws: RenderGraphError.self) {
            _ = try Self.runNode(
                node, context: context,
                request: Self.request(Self.allSliders, faces: [Self.face, odd]))
        }
    }

    // MARK: - Helpers

    /// Encodes one node source → destination and reads the result back as
    /// float32. Deliberately *not* through `RenderGraph`, so a test can reach the
    /// kernel with slider values the graph would short-circuit.
    static func runNode(
        _ node: SkinRenderNode, context: MetalContext, request: RenderRequest
    ) throws -> [Float] {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: Self.source, width: width, height: height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try RenderGraph.readFloat32(destination, queue: context.commandQueue)
    }

    /// One of the node's blurred layers as float32, or the source itself when
    /// the layer was never allocated — which is the right substitute, because a
    /// layer is only skipped when every slider that reads it is at 0 and the
    /// shader binds `source` in its place.
    static func layerPixels(_ texture: (any MTLTexture)?, context: MetalContext) throws -> [Float] {
        guard let texture else { return Self.source }
        return try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
    }

    /// Reads an `r8Unorm` texture back as 0…1 doubles.
    static func readR8(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [Double] {
        let bytesPerRow = texture.width
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let raw = UnsafeRawBufferPointer(
            start: buffer.contents(), count: bytesPerRow * texture.height)
        return raw.map { Double($0) / 255.0 }
    }
}
