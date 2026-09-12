import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Da" (skin) slider group — the first real node on ``RenderGraph``.
///
/// docs/PLAN.md Phase 2: *Mịn da, Giữ texture, Đều màu da, Khử đỏ, Khử bóng dầu,
/// Sáng da, Quầng thâm, Nếp nhăn.* All eight are 0–100, default 0, and no-ops at
/// 0.
///
/// ## Structure
/// Two blurred layers and one composite, all inside the skin mask:
///
/// | layer | how | what it is |
/// |---|---|---|
/// | `base` | ``GuidedFilter``, radius `0.030 × faceWidth`, ε = 4e-3, s = 4 | edge-preserving smooth; `source - base` is pores and fine wrinkles |
/// | `low` | ``GuidedFilter``, radius `0.150 × faceWidth`, **ε = 1e6** | a plain double box blur — with ε far above any local variance `a → 0` and `b → mean`, which `GuidedFilterTests.hugeEpsilonIsDoubleBox` proves — i.e. the colour/brightness the skin *should* have locally |
///
/// Both radii are fractions of `FaceRenderInput.faceWidth` rather than pixel
/// counts, which is what lets a preset move between a head-and-shoulders frame
/// and a full-length one (docs/PLAN.md §2).
///
/// Both take their `s` from `request.quality.guidedSubsample` — 4 today for both
/// qualities, mandatory per ADR-0007 (the exact filter needs 2.3 GB of
/// intermediates at 24 MP) — and they **share one `GuidedFilter.Resources`**: the
/// two `encode` calls land in the same command buffer, Metal's automatic hazard
/// tracking orders the second encoder's writes after the first's reads, and not
/// sharing would double the largest allocation in the node (144 MB at 24 MP).
/// Sharing is only legal because both `Options` carry the *same* `s`: `Resources`
/// bakes the subsampled grid in at allocation time while `encode` takes its box
/// radius from `Options`, so the cache is keyed on `s` as well as on size.
///
/// ## What is deliberately simple, and flagged
/// Three of the eight sliders have no counterpart in
/// `panelpts/RetouchProUXP/commands.js`, which is a manual panel — the retoucher
/// painted the mask by hand. This is Phase 2 "cốt lõi", so each gets the simplest
/// version that is *correct in the direction it moves the picture*, and the
/// limitation is stated rather than hidden:
///
/// * **Quầng thâm** lifts every local dark patch inside the skin mask, not only
///   the eye sockets — there is no under-eye class in CelebAMask-HQ and building
///   a landmark-driven region is a separate piece of work. On a face the eye
///   sockets are by far the strongest such patch, so the slider does the right
///   thing first; it will also lighten a deep nasolabial shadow.
/// * **Nếp nhăn** fills the negative half of the high-frequency residual. It
///   cannot tell a wrinkle from any other dark fine line (a stray hair, a lash),
///   and it is bounded by the guided filter's radius, so it reaches fine lines
///   and not deep folds.
/// * **Khử đỏ** works on `R − (G+B)/2` against its local mean, not on a
///   perceptual redness axis and not on the Selective Color table commands.js
///   used (that table needs a full CMYK round trip for one slider).
///
/// Gated by `RPEngineFeatureFlags.skinSliders` **and** `.guidedFilter` (the node
/// owns a `GuidedFilter`). `RPEngineFeatureFlags.enableSkinRenderGraph()` sets
/// both, and its inverse clears `skinSliders` plus `guidedFilter` *only when the
/// "Mắt / Răng" group is not also using that kernel* — the "Mặt" group's flags
/// are disjoint from these, so any group can be switched off without taking
/// another one down (docs/ADR-0010, docs/ADR-0011).
public final class SkinRenderNode: RenderNode, @unchecked Sendable {
    public let name = "skin"
    public let stage = RenderStage.skin

    /// Guided-filter radius for the edge-preserving layer, as a fraction of face
    /// width. 0.030 × a 600 px face is 18 px, which is spike S3's measured
    /// operating point at a 2048 px preview (radius 16).
    public static let smoothRadiusFraction: CGFloat = 0.030
    /// Radius of the large blur, as a fraction of face width.
    public static let lowRadiusFraction: CGFloat = 0.150
    /// ε for the edge-preserving layer, in gamma-encoded sRGB (ADR-0007).
    public static let smoothEpsilon: Float = 4e-3
    /// ε for the large blur. Far above any local variance, so `a → 0`,
    /// `b → mean_I` and the guided filter *is* a double box blur.
    public static let lowEpsilon: Float = 1e6

    /// The `RenderMask` kinds this node reads, for a caller deciding which masks
    /// are worth feathering (``RenderMaskRequirements``). The same shape as
    /// `EyesTeethRenderNode.maskKinds`, which landed first.
    public static let maskKinds: Set<RenderMaskKind> = [.skin]

    private let context: MetalContext
    private let guidedFilter: GuidedFilter
    /// Rasterises `.skin` from every face into one full-resolution coverage
    /// texture. Was this node's own `encodeMask` until the "Mắt/Răng" group
    /// needed the same thing for two more kinds — see ``MaskRasteriser``.
    private let skinMask: MaskRasteriser
    private let compositePipeline: any MTLComputePipelineState

    /// Phase 6.1: multiplies a ``RenderGateMask`` into the skin coverage.
    ///
    /// Built **lazily and only when a request actually carries a live gate**: a
    /// document with no painted mask and no background lock must not pay for a
    /// pipeline state it never dispatches, and the flags a gate answers to can be
    /// flipped after this node was constructed (the app sets them at launch, a
    /// test sets them per case), so deciding in `init` would bake in whichever
    /// order happened.
    private var gateCompositor: GateMaskCompositor?
    /// Scratch for `skin coverage x gate`, allocated at image size on first use.
    /// Separate from `MaskRasteriser`'s own output because that texture is the
    /// *ungated* coverage and the modulate pass may not read and write one
    /// texture in a single dispatch.
    ///
    /// **Two** of them, ping-ponged, once more than one gate is in play: with a
    /// brush *and* "Khoá nền" set, the second modulate reads what the first one
    /// wrote. The second is only allocated when a request actually carries two
    /// gates, so the common single-gate case still costs one r8 frame.
    private var gatedMasks: [any MTLTexture] = []
    /// The coverage texture the most recent ``encode(into:source:destination:request:)``
    /// bound to the composite — the gated one when a ``RenderGateMask`` was in play.
    /// Read by ``debugLayers()``; internal, for the golden harness.
    private var lastBoundMask: (any MTLTexture)?

    /// Where the fast-guided-filter `s` for a render comes from.
    ///
    /// In production this is exactly `RenderQuality.guidedSubsample`, which is 4
    /// for both quality levels today. It is a stored function rather than a
    /// direct call so a test can split preview and export apart — ADR-0007/0009
    /// flag that split as plausible future work (`subsample` is a memory-driven
    /// parameter, and an export has a different memory budget from a preview),
    /// and the bug this seam exists to pin is that `Resources` used to be sized
    /// from a hardcoded `.preview` while `encode` took its radius from the
    /// request's own quality. `SkinRenderNodeTests.cacheFollowsTheRequestQuality`
    /// is the regression test.
    private let subsampleForQuality: @Sendable (RenderQuality) -> Int

    private let lock = NSLock()
    private var cache: Cache?

    private final class Cache {
        let width: Int
        let height: Int
        let device: any MTLDevice
        let guidedResources: GuidedFilter.Resources

        /// Allocated on first use, not on first render.
        ///
        /// An rgba16Float layer is **192 MB at 24 MP**. A document with only
        /// "Mịn da" set never touches `low`, and one with only "Sáng da" never
        /// touches `base`; allocating both up front would charge every export
        /// 384 MB of layers on a phone that has to fit the guided filter's
        /// 144 MB of intermediates alongside them.
        private var baseTexture: (any MTLTexture)?
        private var lowTexture: (any MTLTexture)?

        init(
            width: Int, height: Int, device: any MTLDevice,
            guidedResources: GuidedFilter.Resources
        ) {
            self.width = width
            self.height = height
            self.device = device
            self.guidedResources = guidedResources
        }

        func base() throws -> any MTLTexture {
            if let baseTexture { return baseTexture }
            let made = try makeLayer()
            baseTexture = made
            return made
        }

        func low() throws -> any MTLTexture {
            if let lowTexture { return lowTexture }
            let made = try makeLayer()
            lowTexture = made
            return made
        }

        /// Which layers the **most recent** encode actually fed to the composite.
        /// A layer stays allocated once it has been used, so "is it allocated" is
        /// not the same question as "did this render use it" — reporting the
        /// former would hand a golden test a stale layer the shader did not bind.
        var lastBaseUsed = false
        var lastLowUsed = false

        var storedBase: (any MTLTexture)? { lastBaseUsed ? baseTexture : nil }
        var storedLow: (any MTLTexture)? { lastLowUsed ? lowTexture : nil }

        private func makeLayer() throws -> any MTLTexture {
            try SpikeTextureIO.makeTexture(
                width: width, height: height, device: device, pixelFormat: .rgba16Float,
                usage: [.shaderRead, .shaderWrite])
        }

        /// The blurred layers plus the guided filter's intermediates. The
        /// full-resolution mask is `MaskRasteriser`'s and is counted there;
        /// ``SkinRenderNode/allocatedBytes`` adds the two together, so the
        /// node's total is unchanged from before the rasteriser was extracted
        /// (bar the 0.26 MB/face parsing-crop array, which is now counted and
        /// was not before).
        var byteCount: Int {
            let layers = (baseTexture == nil ? 0 : 8) + (lowTexture == nil ? 0 : 8)
            return width * height * layers + guidedResources.byteCount
        }
    }

    public convenience init(context: MetalContext) throws {
        try self.init(context: context, subsampleForQuality: { $0.guidedSubsample })
    }

    /// Internal seam — see ``subsampleForQuality``. Not public: nothing outside
    /// the package has any business overriding an ADR-mandated constant.
    init(
        context: MetalContext,
        subsampleForQuality: @escaping @Sendable (RenderQuality) -> Int
    ) throws {
        guard RPEngineFeatureFlags.skinSliders else {
            throw RPEngineFeatureDisabled(feature: "skinSliders")
        }
        self.context = context
        self.subsampleForQuality = subsampleForQuality
        // Throws RPEngineFeatureDisabled(guidedFilter) when that flag is off —
        // deliberately not bypassed here: the kernel's own gate stays meaningful.
        self.guidedFilter = try GuidedFilter(context: context)
        self.skinMask = try MaskRasteriser(kind: .skin, context: context)
        self.compositePipeline = try context.computePipeline("rp_skin_composite")
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        _ = try context.computePipeline("rp_skin_mask")
        _ = try context.computePipeline("rp_skin_composite")
        for function in ["rp_gf_downsample", "rp_gf_box_h", "rp_gf_box_v",
                         "rp_gf_coefficients", "rp_gf_reconstruct"] {
            _ = try context.computePipeline(function)
        }
        // Only when a gate source is on: with both flags off these kernels are
        // never dispatched, and compiling them would charge every launch for a
        // feature the build does not have. The brush's own painting kernels are
        // separate from the gating one, because "Khoá nền" needs the second
        // without the first (see ``GateMaskCompositor``).
        if RPEngineFeatureFlags.manualMask {
            try ManualMaskRasteriser.prewarm(context: context)
        }
        if RPEngineFeatureFlags.manualMask || RPEngineFeatureFlags.backgroundLock {
            try GateMaskCompositor.prewarm(context: context)
        }
    }

    public func isActive(for request: RenderRequest) -> Bool {
        guard !SkinSliders(request.editState).isIdentity else { return false }
        // No face means no skin mask means every op is multiplied by zero. Saying
        // so here rather than dispatching a full-resolution no-op is the
        // difference between "the slider does nothing" and "the slider costs
        // 1.5 ms to do nothing".
        return request.faces.contains { $0.masks[.skin] != nil }
    }

    /// Bytes of GPU memory this node is holding for the current size.
    public var allocatedBytes: Int {
        lock.lock()
        let layers = cache?.byteCount ?? 0
        let gated = gatedMasks.reduce(0) { $0 + $1.width * $1.height }
        lock.unlock()
        return layers + gated + skinMask.allocatedBytes
    }

    public func releaseIntermediates() {
        lock.lock()
        cache = nil
        gatedMasks = []
        lastBoundMask = nil
        lock.unlock()
        skinMask.releaseIntermediates()
    }

    /// The intermediates from the most recent `encode`, so the golden harness can
    /// check the composite kernel against a `Double` reference **fed the same
    /// layers** — otherwise a composite failure and a guided-filter failure are
    /// indistinguishable. `nil` before the first encode.
    ///
    /// `base` and `low` are `nil` when no slider in the last request needed them —
    /// they are allocated on first use, so "absent" is the correct answer and not
    /// a failure.
    ///
    /// Internal, not public: nothing outside the tests should reach in here.
    func debugLayers()
        -> (base: (any MTLTexture)?, low: (any MTLTexture)?, mask: any MTLTexture)?
    {
        lock.lock()
        let cached = cache
        lock.unlock()
        // The mask the **last encode actually bound**, which is the gated one
        // when a hand-painted mask narrowed it (Phase 6.1). Reporting the
        // ungated `skinMask.output` instead would hand the golden harness a
        // different mask from the one the composite read, and a gated render
        // would fail the comparison for a reason that is not a bug.
        guard let cached, let mask = lastBoundMask ?? skinMask.output else { return nil }
        return (cached.storedBase, cached.storedLow, mask)
    }

    /// The fast-guided-filter `s` the currently cached `GuidedFilter.Resources`
    /// were allocated for, or `nil` before the first encode. Internal; the
    /// regression test for the hardcoded-`.preview` bug reads it.
    var debugGuidedSubsample: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.guidedResources.subsample
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let sliders = SkinSliders(request.editState)
        let faces = request.faces.filter { $0.masks[.skin] != nil }
        guard !sliders.isIdentity, !faces.isEmpty else {
            // Not reachable through RenderGraph (isActive gates it), but a direct
            // caller must still get the picture rather than an empty texture.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        // The `s` the resources are sized for and the `s` the two `encode` calls
        // below derive their box radius from must be the same number, so both
        // come from this one lookup.
        let subsample = subsampleForQuality(request.quality)
        let cache = try self.cache(
            width: source.width, height: source.height, subsample: subsample)
        guard
            let rawMask = try skinMask.encode(
                into: commandBuffer, faces: faces, width: source.width, height: source.height)
        else {
            // Unreachable: `faces` is filtered to those carrying `.skin`, so the
            // rasteriser always has something. Copy rather than bind nothing.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        // Phase 6.1 — the whole-frame gates (hand-painted brush, and later
        // "Khoá nền"), if the request carries any. This is the *whole* of "gate
        // this group with a mask": the node keeps its kernels, its constants and
        // its measured behaviour, and only the coverage texture bound at index 3
        // below changes (docs/PLAN.md §6.1 — "không phải kỹ thuật mới, chỉ thêm
        // 1 nguồn mask nữa"). With no gate the value is `rawMask` and this node
        // is byte-for-byte its pre-6.1 self, which is what keeps ADR-0009's
        // golden PSNR valid.
        let maskTexture = try gate(
            rawMask, with: request.gateMasks, into: commandBuffer,
            width: source.width, height: source.height)
        lock.lock()
        lastBoundMask = maskTexture
        lock.unlock()

        let faceWidth = faces.map(\.faceWidth).max() ?? 0
        var baseTexture: (any MTLTexture)?
        var lowTexture: (any MTLTexture)?
        cache.lastBaseUsed = sliders.needsSmoothLayer
        cache.lastLowUsed = sliders.needsLowFrequencyLayer
        if sliders.needsSmoothLayer {
            let texture = try cache.base()
            baseTexture = texture
            let options = GuidedFilter.Options(
                radius: Self.smoothRadius(faceWidth: faceWidth),
                epsilon: Self.smoothEpsilon, subsample: subsample,
                amount: 1)
            guidedFilter.encode(
                into: commandBuffer, source: source, destination: texture,
                resources: cache.guidedResources, options: options)
        }
        if sliders.needsLowFrequencyLayer {
            let texture = try cache.low()
            lowTexture = texture
            let options = GuidedFilter.Options(
                radius: Self.lowRadius(faceWidth: faceWidth),
                epsilon: Self.lowEpsilon, subsample: subsample,
                amount: 1)
            guidedFilter.encode(
                into: commandBuffer, source: source, destination: texture,
                resources: cache.guidedResources, options: options)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(source, index: 0)
        // An unused layer is bound to `source`: its amount is 0, so the mix() is
        // the identity whatever it contains, and binding nothing is undefined.
        encoder.setTexture(baseTexture ?? source, index: 1)
        encoder.setTexture(lowTexture ?? source, index: 2)
        encoder.setTexture(maskTexture, index: 3)
        encoder.setTexture(destination, index: 4)
        var params = SkinCompositeParams(
            size: SIMD2<UInt32>(UInt32(source.width), UInt32(source.height)),
            smoothAmount: Float(sliders.smooth / 100),
            keepTexture: Float(sliders.keepTexture / 100),
            evenTone: Float(sliders.evenTone / 100),
            redness: Float(sliders.redness / 100),
            shine: Float(sliders.shine / 100),
            brighten: Float(sliders.brighten / 100),
            darkCircle: Float(sliders.darkCircle / 100),
            wrinkle: Float(sliders.wrinkle / 100))
        encoder.setBytes(&params, length: MemoryLayout<SkinCompositeParams>.stride, index: 0)
        let dispatch = MetalContext.threadgroups(
            forWidth: source.width, height: source.height, pipeline: compositePipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }

    // MARK: - Whole-frame gate masks (docs/PLAN.md §6.1)

    /// Returns `coverage x gate₀ x gate₁ …`, or `coverage` unchanged when the
    /// request carries no gate that is live.
    ///
    /// One dispatch per gate, ping-ponging between two scratch textures, because
    /// the modulate pass may not read and write the same texture. Gates intersect
    /// — see ``RenderGateMask`` for why a product is the only defensible
    /// composition of a feathered brush and a soft segmentation.
    ///
    /// Each gate's own flag is re-read here, through
    /// ``RenderGateMask/isGateEnabled``, rather than trusted from construction
    /// time: a `RenderRequest` can only carry a `ManualMaskCoverage` that was
    /// built while `manualMask` was on, but a caller may switch it off between
    /// painting and rendering, and "off" has to mean "this group renders what it
    /// rendered before 6.1" at every moment, not only at launch.
    private func gate(
        _ coverage: any MTLTexture, with gates: [any RenderGateMask],
        into commandBuffer: any MTLCommandBuffer, width: Int, height: Int
    ) throws -> any MTLTexture {
        let live = gates.filter(\.isGateEnabled)
        guard !live.isEmpty else { return coverage }
        let compositor = try gateMaskCompositor()
        let scratch = try gatedMaskTextures(
            count: min(2, live.count), width: width, height: height)
        var current = coverage
        for (index, mask) in live.enumerated() {
            let destination = scratch[index % scratch.count]
            compositor.encode(
                into: commandBuffer, coverage: current, gate: mask, destination: destination)
            current = destination
        }
        return current
    }

    private func gateMaskCompositor() throws -> GateMaskCompositor {
        lock.lock()
        defer { lock.unlock() }
        if let gateCompositor { return gateCompositor }
        let made = try GateMaskCompositor(context: context)
        gateCompositor = made
        return made
    }

    /// `count` scratch coverage textures at the image size, reusing the ones
    /// already held when they still fit. Growing only — a request with two gates
    /// followed by one with a single gate keeps the second texture rather than
    /// churning an allocation per frame; `releaseIntermediates()` drops both.
    private func gatedMaskTextures(count: Int, width: Int, height: Int) throws
        -> [any MTLTexture]
    {
        lock.lock()
        defer { lock.unlock() }
        if let first = gatedMasks.first, first.width != width || first.height != height {
            gatedMasks = []
        }
        while gatedMasks.count < count {
            gatedMasks.append(
                try SpikeTextureIO.makeTexture(
                    width: width, height: height, device: context.device, pixelFormat: .r8Unorm,
                    usage: [.shaderRead, .shaderWrite]))
        }
        return Array(gatedMasks.prefix(count))
    }

    // MARK: - Radii

    static func smoothRadius(faceWidth: CGFloat) -> Int {
        clampRadius(faceWidth * smoothRadiusFraction, minimum: 2, maximum: 96)
    }

    static func lowRadius(faceWidth: CGFloat) -> Int {
        clampRadius(faceWidth * lowRadiusFraction, minimum: 4, maximum: 256)
    }

    private static func clampRadius(_ value: CGFloat, minimum: Int, maximum: Int) -> Int {
        guard value.isFinite else { return minimum }
        return min(maximum, max(minimum, Int(value.rounded())))
    }

    // MARK: - Resources

    /// - Parameter subsample: the fast-guided-filter `s` the *caller's* request
    ///   asked for. `GuidedFilter.Resources` bakes the subsampled grid size in at
    ///   construction time while `GuidedFilter.encode` takes the box radius from
    ///   the per-call `Options`, so a cache built for one `s` and encoded with
    ///   another filters at the wrong scale. It used to be hardcoded to
    ///   `RenderQuality.preview.guidedSubsample`, which was only harmless because
    ///   preview and export happen to share the constant.
    private func cache(width: Int, height: Int, subsample: Int) throws -> Cache {
        lock.lock()
        defer { lock.unlock() }
        let s = max(1, subsample)
        if let existing = cache, existing.width == width, existing.height == height,
            existing.guidedResources.subsample == s
        {
            return existing
        }
        let resources = try guidedFilter.makeResources(
            width: width, height: height, options: GuidedFilter.Options(subsample: s))
        let made = Cache(
            width: width, height: height, device: context.device,
            guidedResources: resources)
        cache = made
        return made
    }

}

// MARK: - Shader parameter structs
//
// Must match SkinShaders.metal exactly; `SkinRenderNodeTests` pins the strides.

struct SkinMaskParams {
    var imageSize: SIMD2<UInt32>
    var maskSize: SIMD2<UInt32>
    var faceCount: UInt32
}

struct SkinMaskTransform {
    var rowX: SIMD3<Float>
    var rowY: SIMD3<Float>
}

struct SkinCompositeParams {
    var size: SIMD2<UInt32>
    var smoothAmount: Float
    var keepTexture: Float
    var evenTone: Float
    var redness: Float
    var shine: Float
    var brighten: Float
    var darkCircle: Float
    var wrinkle: Float
}
