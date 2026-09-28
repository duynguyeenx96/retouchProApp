import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Trang điểm" (makeup) slider group — ``RenderStage/makeup`` on
/// ``RenderGraph``. docs/PLAN.md Phase 5, docs/ADR-0027.
///
/// ## Structure
/// Up to three rasterised parsing masks (lips, brows, skin), a handful of blush
/// lobes in a small constant buffer, one composite. **No blurred layer**: every
/// step is per-pixel, so unlike "Tóc" and "Mắt / Răng" the node needs neither a
/// ``GuidedFilter`` nor the `guidedFilter` kernel flag, and holds at most three
/// `r8` masks (72 MB at 24 MP, only for the sliders in use).
///
/// ## Runs before the warp
/// ``RenderStage/makeup`` is 270, between "Tóc" and "Mặt". The lips mask comes
/// from the unwarped frame; "Môi đầy" and "Rộng miệng" move the lips. Applied
/// after the warp, lipstick would miss exactly the lip edge those sliders move
/// out — so it is applied first and the warp carries it. That reverses the
/// position docs/PLAN.md §2 first gave makeup (after Eyes/Teeth); ADR-0027
/// records why.
///
/// ## Absent masks
/// The ``EyesTeethRenderNode`` rule: a slider whose mask no face carries is
/// forced to 0, and another real, correctly sized mask texture is bound in its
/// place, so no full-resolution texture is ever allocated only to be zero.
///
/// ## Not measured
/// Nobody has looked at a render and nothing has been timed (docs/PLAN.md
/// Phase 5, local work). Flag `RPEngineFeatureFlags.makeupSliders`, default off.
public final class MakeupRenderNode: RenderNode, @unchecked Sendable {
    public let name = "makeup"
    public let stage = RenderStage.makeup

    /// The mask kinds this node reads.
    public static let maskKinds: Set<RenderMaskKind> = [.lips, .brows, .skin]

    private let context: MetalContext
    private let lipsMask: MaskRasteriser
    private let browsMask: MaskRasteriser
    private let skinMask: MaskRasteriser
    private let compositePipeline: any MTLComputePipelineState

    private let lock = NSLock()
    /// The masks and lobes the most recent encode used, for the golden harness.
    private var last: (lips: (any MTLTexture)?, brows: (any MTLTexture)?,
                       skin: (any MTLTexture)?, lobes: [ContourLobe])?

    public init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.makeupSliders else {
            throw RPEngineFeatureDisabled(feature: "makeupSliders")
        }
        self.context = context
        self.lipsMask = try MaskRasteriser(kind: .lips, context: context)
        self.browsMask = try MaskRasteriser(kind: .brows, context: context)
        self.skinMask = try MaskRasteriser(kind: .skin, context: context)
        self.compositePipeline = try context.computePipeline("rp_makeup_composite")
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        _ = try context.computePipeline("rp_skin_mask")
        _ = try context.computePipeline("rp_makeup_composite")
    }

    /// What each slider can actually reach in this request.
    private struct Reach {
        var lips = false
        var brows = false
        var blush = false
        var any: Bool { lips || brows || blush }
    }

    private func reach(_ sliders: MakeupSliders, faces: [FaceRenderInput]) -> Reach {
        var r = Reach()
        r.lips = sliders.lipstick > 0 && faces.contains { $0.masks[.lips] != nil }
        r.brows = sliders.brows > 0 && faces.contains { $0.masks[.brows] != nil }
        // Blush needs both the mesh (where) and the skin mask (only on skin).
        r.blush = sliders.blush > 0 && faces.contains {
            $0.masks[.skin] != nil
                && FaceMeshFrame(landmarks: $0.landmarks, faceWidth: $0.faceWidth) != nil
        }
        return r
    }

    public func isActive(for request: RenderRequest) -> Bool {
        let sliders = MakeupSliders(request.editState)
        guard !sliders.isIdentity else { return false }
        return reach(sliders, faces: request.faces).any
    }

    public var allocatedBytes: Int {
        lipsMask.allocatedBytes + browsMask.allocatedBytes + skinMask.allocatedBytes
    }

    public func releaseIntermediates() {
        lipsMask.releaseIntermediates()
        browsMask.releaseIntermediates()
        skinMask.releaseIntermediates()
        lock.lock()
        last = nil
        lock.unlock()
    }

    /// Internal, for the tests: the masks bound as *real* inputs in the last
    /// encode (`nil` for a slider that was off or had no mask) and its lobes.
    func debugLayers() -> (lips: (any MTLTexture)?, brows: (any MTLTexture)?,
                           skin: (any MTLTexture)?, lobes: [ContourLobe])?
    {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let sliders = MakeupSliders(request.editState)
        let reach = sliders.isIdentity ? Reach() : self.reach(sliders, faces: request.faces)
        guard reach.any else {
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }
        let width = source.width
        let height = source.height
        let lips = reach.lips
            ? try lipsMask.encode(into: commandBuffer, faces: request.faces, width: width, height: height)
            : nil
        let brows = reach.brows
            ? try browsMask.encode(into: commandBuffer, faces: request.faces, width: width, height: height)
            : nil
        let skin = reach.blush
            ? try skinMask.encode(into: commandBuffer, faces: request.faces, width: width, height: height)
            : nil
        let lobes = reach.blush ? BlushMask.lobes(faces: request.faces) : []
        lock.lock()
        last = (lips, brows, skin, lobes)
        lock.unlock()

        // At least one of the three is real (reach.any), and each substitute is
        // multiplied by an amount forced to 0 below.
        guard let fallback = lips ?? brows ?? skin else {
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(lips ?? fallback, index: 1)
        encoder.setTexture(brows ?? fallback, index: 2)
        encoder.setTexture(skin ?? fallback, index: 3)
        encoder.setTexture(destination, index: 4)
        var params = MakeupParams(
            sliders: sliders, width: width, height: height,
            hasLips: lips != nil, hasBrows: brows != nil,
            blushLobeCount: skin == nil ? 0 : lobes.count)
        encoder.setBytes(&params, length: MemoryLayout<MakeupParams>.stride, index: 0)
        // A buffer must be bound at index 1 even with no lobe; one zero lobe is
        // never read because the count is 0.
        let bound =
            lobes.isEmpty
            ? [ContourLobe(centre: .zero, axisU: .zero, halfExtent: SIMD2(1, 1), strength: 0)]
            : lobes
        bound.withUnsafeBytes { raw in
            if let base = raw.baseAddress { encoder.setBytes(base, length: raw.count, index: 1) }
        }
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: compositePipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }
}

// MARK: - Shader parameter struct
//
// Must match MakeupShaders.metal exactly; `MakeupRenderNodeTests` pins the layout.

struct MakeupParams {
    var size: SIMD2<UInt32>
    var lipstick: Float
    var blush: Float
    var browsExponent: Float
    var blushLobeCount: UInt32
    var lipTintLuma: Float
    var pad0: Float = 0
    var lipTint: SIMD4<Float>
    var blushTint: SIMD4<Float>

    init(
        sliders: MakeupSliders, width: Int, height: Int, hasLips: Bool, hasBrows: Bool,
        blushLobeCount: Int
    ) {
        size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        lipstick = hasLips ? Float(sliders.lipstick / 100) : 0
        blush = blushLobeCount > 0 ? Float(sliders.blush / 100) : 0
        browsExponent = hasBrows ? Float(sliders.browsLumaExponent) : 1
        self.blushLobeCount = UInt32(blushLobeCount)
        let lip = MakeupSliders.lipTint(tone: sliders.lipTone)
        lipTintLuma = Float(lip.luma)
        lipTint = SIMD4<Float>(Float(lip.normalised.x), Float(lip.normalised.y), Float(lip.normalised.z), 0)
        let rose = MakeupSliders.blushTint
        blushTint = SIMD4<Float>(Float(rose.x), Float(rose.y), Float(rose.z), 0)
    }
}
