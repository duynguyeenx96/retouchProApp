import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Tóc" (hair) slider group — ``RenderStage/hair`` on ``RenderGraph``.
/// docs/PLAN.md Phase 5 *"hair: bóng, tối/sáng, đổi màu"*, docs/ADR-0026.
///
/// ## Structure
/// One rasterised mask, at most one blurred layer, one composite — the
/// ``EyesTeethRenderNode`` shape, deliberately:
///
/// | input | how | what it is |
/// |---|---|---|
/// | `hairMask` | ``MaskRasteriser`` over `RenderMaskKind.hair` | feathered CelebAMask-HQ `hair` |
/// | `low` | ``GuidedFilter``, radius `0.08 × faceWidth`, **ε = 1e6** | a double box blur — the neighbourhood a sheen band is brighter than. Only for "Bóng tóc" |
///
/// `low` is allocated on first use, so a document using only the dye or the
/// lightness sliders never pays the 192 MB + 144 MB it costs at 24 MP.
///
/// ## Why it runs before the warp
/// ``RenderStage/hair`` sits between "Da" and "Mặt". The hair mask is computed
/// on the **unwarped** frame, and "Đầu" moves the hairline by up to tens of
/// pixels (docs/ADR-0022). A colour change applied *before* the warp is carried
/// along with the hair it was applied to; applied after, the mask would be off
/// by exactly the displacement, and a recoloured band of forehead or an
/// uncoloured band of hair would be the visible result. docs/PLAN.md §2 had
/// makeup after Eyes/Teeth and no hair stage at all; ADR-0026 records the
/// change.
///
/// ## What it does not do
/// * **No gate masks.** Like ``EyesTeethRenderNode``, and unlike
///   ``SkinRenderNode``, it ignores `RenderRequest.gateMasks`: the hair mask is
///   already the whole selection, and "Khoá nền" by definition never excludes
///   the subject's hair. A painted brush restricting a hair edit is a later
///   decision, not an omission this node hides.
/// * **No flyaway hair ("tóc con bay").** That is inpainting, Phase 6 (LaMa).
/// * **Nobody has looked at a render.** Every constant is argued from what the
///   operation is (ADR-0026) and the tests prove the shader computes the
///   documented formula on the documented pixels — not that it looks good.
///
/// ## Flags
/// Gated by `RPEngineFeatureFlags.hairSliders` **and** `.guidedFilter` (the node
/// owns a ``GuidedFilter`` for the gloss layer; that kernel's gate is not
/// bypassed). `RPEngineFeatureFlags.enableHairRenderGraph()` sets both.
public final class HairRenderNode: RenderNode, @unchecked Sendable {
    public let name = "hair"
    public let stage = RenderStage.hair

    /// Radius of the gloss reference blur, as a fraction of face width. A sheen
    /// band on a head of hair is a few strands wide and a head is roughly one
    /// face wide, so ~0.08 is wide enough that the band's neighbourhood includes
    /// the darker hair on both sides of it, and narrow enough that it does not
    /// average the whole head into one tone.
    public static let localMeanRadiusFraction: CGFloat = 0.08
    /// ε for the gloss layer — far above any local variance, so the guided
    /// filter degenerates to a double box blur, the trick ``EyesTeethRenderNode``
    /// and ``SkinRenderNode`` already use (no second blur kernel).
    public static let localMeanEpsilon: Float = 1e6

    /// A hair mask whose mean coverage is below this counts as "no hair found"
    /// for ``detectionNotice(for:)``. Same order as ``SkinRenderNode``'s body
    /// threshold: well under one hair strand's worth of a 512² crop is noise.
    public static let minimumHairCoverage = 0.001

    /// The sentence ``detectionNotice(for:)`` returns.
    public static let noHairNotice = "Không phát hiện được tóc."

    /// The mask kinds this node reads — what `RenderMaskRequirements` asks the
    /// face provider for when this group is on.
    public static let maskKinds: Set<RenderMaskKind> = [.hair]

    private let context: MetalContext
    private let guidedFilter: GuidedFilter
    private let hairMask: MaskRasteriser
    private let compositePipeline: any MTLComputePipelineState
    /// Same seam and same reason as ``EyesTeethRenderNode``'s: the resources and
    /// the encode must agree on one `s`, taken from the request's quality.
    private let subsampleForQuality: @Sendable (RenderQuality) -> Int

    private let lock = NSLock()
    private var cache: Cache?
    /// Memo for ``detectionNotice(for:)``, keyed by the mask value itself: the
    /// request holds the same copy-on-write buffer every frame of a drag, so the
    /// comparison is cheap after the first scan (the ``SkinRenderNode`` pattern).
    private var lastCoverage: (mask: RenderMask, usable: Bool)?

    private final class Cache {
        let width: Int
        let height: Int
        let subsample: Int
        let device: any MTLDevice
        private let guidedFilter: GuidedFilter
        private var lowTexture: (any MTLTexture)?
        private var resources: GuidedFilter.Resources?

        init(
            width: Int, height: Int, subsample: Int, device: any MTLDevice,
            guidedFilter: GuidedFilter
        ) {
            self.width = width
            self.height = height
            self.subsample = subsample
            self.device = device
            self.guidedFilter = guidedFilter
        }

        func low() throws -> any MTLTexture {
            if let lowTexture { return lowTexture }
            let made = try SpikeTextureIO.makeTexture(
                width: width, height: height, device: device, pixelFormat: .rgba16Float,
                usage: [.shaderRead, .shaderWrite])
            lowTexture = made
            return made
        }

        func guidedResources() throws -> GuidedFilter.Resources {
            if let resources { return resources }
            let made = try guidedFilter.makeResources(
                width: width, height: height,
                options: GuidedFilter.Options(subsample: subsample))
            resources = made
            return made
        }

        /// What the most recent encode fed the composite — not "what is
        /// allocated", for the stale-layer reason ADR-0009 records.
        var lastLowUsed = false
        var lastHair: (any MTLTexture)?
        var storedLow: (any MTLTexture)? { lastLowUsed ? lowTexture : nil }

        var byteCount: Int {
            (lowTexture == nil ? 0 : width * height * 8) + (resources?.byteCount ?? 0)
        }
    }

    public convenience init(context: MetalContext) throws {
        try self.init(context: context, subsampleForQuality: { $0.guidedSubsample })
    }

    init(
        context: MetalContext,
        subsampleForQuality: @escaping @Sendable (RenderQuality) -> Int
    ) throws {
        guard RPEngineFeatureFlags.hairSliders else {
            throw RPEngineFeatureDisabled(feature: "hairSliders")
        }
        self.context = context
        self.subsampleForQuality = subsampleForQuality
        self.guidedFilter = try GuidedFilter(context: context)
        self.hairMask = try MaskRasteriser(kind: .hair, context: context)
        self.compositePipeline = try context.computePipeline("rp_hair_composite")
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        _ = try context.computePipeline("rp_skin_mask")
        _ = try context.computePipeline("rp_hair_composite")
        for function in ["rp_gf_downsample", "rp_gf_box_h", "rp_gf_box_v",
                         "rp_gf_coefficients", "rp_gf_reconstruct"] {
            _ = try context.computePipeline(function)
        }
    }

    public func isActive(for request: RenderRequest) -> Bool {
        guard !HairSliders(request.editState).isIdentity else { return false }
        // No hair mask anywhere means a full-frame pass multiplied by zero.
        return request.faces.contains { $0.masks[.hair] != nil }
    }

    /// "Không phát hiện được tóc." when the user moved a hair slider on a frame
    /// with faces but no usable hair mask — a hat, a shaved head, a parsing
    /// miss. Silent at slider 0 (nothing was asked for) and when the flag is off
    /// (nothing could have been asked for), per ``RenderNode``'s rules. A frame
    /// with no face at all is left to the panel's own `needsFace` line, which
    /// `RPUI.GroupAvailability` checks first and words more precisely.
    public func detectionNotice(for request: RenderRequest) -> String? {
        guard RPEngineFeatureFlags.hairSliders, !request.faces.isEmpty,
            !HairSliders(request.editState).isIdentity
        else { return nil }
        let usable = request.faces.contains { face in
            guard let mask = face.masks[.hair] else { return false }
            return hasUsableCoverage(mask)
        }
        return usable ? nil : Self.noHairNotice
    }

    private func hasUsableCoverage(_ mask: RenderMask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastCoverage, last.mask == mask { return last.usable }
        let usable = Self.isUsableHairCoverage(mask)
        lastCoverage = (mask, usable)
        return usable
    }

    /// `mean(values) / 255 > minimumHairCoverage`, with an early exit. Internal
    /// so a test can pin the threshold without a GPU.
    static func isUsableHairCoverage(_ mask: RenderMask) -> Bool {
        guard !mask.values.isEmpty else { return false }
        let budget = Double(mask.values.count) * 255 * minimumHairCoverage
        var sum = 0.0
        for value in mask.values {
            sum += Double(value)
            if sum > budget { return true }
        }
        return false
    }

    /// Bytes of GPU memory this node is holding for the current size.
    public var allocatedBytes: Int {
        lock.lock()
        let layers = cache?.byteCount ?? 0
        lock.unlock()
        return layers + hairMask.allocatedBytes
    }

    public func releaseIntermediates() {
        lock.lock()
        cache = nil
        lock.unlock()
        hairMask.releaseIntermediates()
    }

    /// The intermediates of the most recent encode, for the golden harness —
    /// internal. `low` is `nil` when "Bóng tóc" was 0.
    func debugLayers() -> (low: (any MTLTexture)?, hair: (any MTLTexture)?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let cache else { return nil }
        return (cache.storedLow, cache.lastHair)
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let sliders = HairSliders(request.editState)
        let width = source.width
        let height = source.height
        let hairTexture =
            sliders.isIdentity
            ? nil
            : try hairMask.encode(
                into: commandBuffer, faces: request.faces, width: width, height: height)
        guard let hairTexture else {
            // Not reachable through RenderGraph (isActive gates both cases), but
            // a direct caller must still get the picture.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        let subsample = subsampleForQuality(request.quality)
        let cache = try self.cache(width: width, height: height, subsample: subsample)
        let faceWidth = request.faces.filter { $0.masks[.hair] != nil }.map(\.faceWidth).max() ?? 0

        var lowTexture: (any MTLTexture)?
        cache.lastLowUsed = sliders.needsLocalMeanLayer
        cache.lastHair = hairTexture
        if sliders.needsLocalMeanLayer {
            let texture = try cache.low()
            lowTexture = texture
            let options = GuidedFilter.Options(
                radius: Self.localMeanRadius(faceWidth: faceWidth),
                epsilon: Self.localMeanEpsilon, subsample: subsample, amount: 1)
            guidedFilter.encode(
                into: commandBuffer, source: source, destination: texture,
                resources: try cache.guidedResources(), options: options)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        // An unused layer is bound to `source`: the gloss amount is 0, so the
        // shader never reads it, and binding nothing is undefined.
        encoder.setTexture(lowTexture ?? source, index: 1)
        encoder.setTexture(hairTexture, index: 2)
        encoder.setTexture(destination, index: 3)
        var params = HairParams(sliders: sliders, width: width, height: height)
        encoder.setBytes(&params, length: MemoryLayout<HairParams>.stride, index: 0)
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: compositePipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    // MARK: - Radius

    static func localMeanRadius(faceWidth: CGFloat) -> Int {
        let value = faceWidth * localMeanRadiusFraction
        guard value.isFinite else { return 3 }
        return min(192, max(3, Int(value.rounded())))
    }

    // MARK: - Resources

    private func cache(width: Int, height: Int, subsample: Int) throws -> Cache {
        lock.lock()
        defer { lock.unlock() }
        let s = max(1, subsample)
        if let existing = cache, existing.width == width, existing.height == height,
            existing.subsample == s
        {
            return existing
        }
        let made = Cache(
            width: width, height: height, subsample: s, device: context.device,
            guidedFilter: guidedFilter)
        cache = made
        return made
    }
}

// MARK: - Shader parameter struct
//
// Must match HairShaders.metal exactly; `HairRenderNodeTests` pins the stride.

struct HairParams {
    var size: SIMD2<UInt32>
    var gloss: Float
    var dye: Float
    var lightnessExponent: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var dyeTint: SIMD4<Float>

    init(sliders: HairSliders, width: Int, height: Int) {
        size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        gloss = Float(sliders.gloss / 100)
        dye = Float(sliders.dye / 100)
        lightnessExponent = Float(sliders.lightnessExponent)
        let tint = HairSliders.dyeTint(tone: sliders.dyeTone)
        dyeTint = SIMD4<Float>(Float(tint.x), Float(tint.y), Float(tint.z), 0)
    }
}
