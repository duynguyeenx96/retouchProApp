import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Mắt / Răng" (eyes / teeth) slider group — ``RenderStage/eyesTeeth`` on
/// ``RenderGraph``, and the third real node after ``SkinRenderNode`` and
/// ``WarpRenderNode``.
///
/// docs/PLAN.md Phase 2: *Sáng mắt, Trắng lòng trắng, Nét mắt, Trắng răng.*
/// Four sliders, 0–100, default 0, exact no-ops at 0.
///
/// ## Structure
/// Two rasterised masks, at most one blurred layer, one composite:
///
/// | input | how | what it is |
/// |---|---|---|
/// | `eyeMask` | ``MaskRasteriser`` over `RenderMaskKind.eyes` | feathered `l_eye + r_eye`, i.e. the whole eye opening |
/// | `mouthMask` | ``MaskRasteriser`` over `RenderMaskKind.mouth` | feathered `mouth`, i.e. the mouth **interior** |
/// | `low` | ``GuidedFilter``, radius `0.050 × faceWidth`, **ε = 1e6** | a plain double box blur (`GuidedFilterTests.hugeEpsilonIsDoubleBox`), about half an eye / half a mouth wide — the local reference |
///
/// The radius is a fraction of `FaceRenderInput.faceWidth`, never a pixel count,
/// which is what lets a preset move between a head-and-shoulders frame and a
/// full-length one and makes a 2048 px preview agree with a 24 MP export
/// (docs/PLAN.md §2).
///
/// `low` is **allocated on first use**: a document with only "Sáng mắt" set
/// never touches it, and the layer plus the guided filter's intermediates are
/// 192 MB + 144 MB at 24 MP.
///
/// ## The masks are always feathered, and that is not this node's choice
/// Spike S2 measured eye IoU at 0.84 against a 0.85 bar and proved it is the
/// checkpoint's ceiling — a ~1 px boundary error on a ~15 px object. A hard mask
/// shows that error as a visible edge; a feathered one hides it
/// (`FaceParsingGroup.requiresFeatheredMask`, docs/ADR-0006). `RenderMask` is a
/// plain value type, so this node cannot tell a feathered mask from a hard one —
/// the guarantee lives in `App/FaceAnalysisRenderBridge.swift`, which only ever
/// calls `ParsedFace.feathered(_:)`, and in
/// `FaceAnalysisRenderBridgeTests.everyMaskIsFeathered` /
/// `.eyesTeethNodeMaskKindsAreFeathered`.
///
/// ## There is no teeth mask and no sclera mask
/// CelebAMask-HQ has 19 classes and **no teeth class**: `mouth` is the gap
/// between the lips, so it also contains gums, tongue and shadow. It equally has
/// no sclera class: `l_eye`/`r_eye` are the whole eye opening, sclera *and* iris
/// *and* pupil. `RenderMaskKind` deliberately has no `.teeth` case so a node
/// cannot quietly assume a mask nothing can produce.
///
/// So both whitening sliders derive their target from **luminance and
/// saturation inside the mask they do have** (spike S2 §3c makes this mandatory
/// for teeth; the same argument produces sclera):
///
/// ```
/// lift    = saturate((luma(c) − luma(local mean)) / 0.06)
/// sat     = (max(rgb) − min(rgb)) / max(rgb)
/// neutral = saturate(1 − sat / satKnee)         // 0.60 sclera, 0.40 teeth
/// weight  = lift · neutral
/// ```
///
/// Teeth are brighter and less saturated than lips, gums, tongue and the shadow
/// of an open mouth; sclera is brighter and less saturated than the iris and the
/// lash line. "Brighter" is measured against the **local mean**, not an absolute
/// threshold, so the heuristic survives exposure and skin tone.
///
/// ### What that heuristic gets wrong, stated rather than hidden
/// * A **specular catchlight on the iris** is bright and neutral, so it scores
///   as sclera and gets whitened. It is already near-white, so the visible
///   effect is nil — but the slider is not doing what its name says there.
/// * A **pale grey or blue iris in bright light** partially qualifies and will
///   be slightly desaturated at high slider values. A brown iris does not.
/// * A **bloodshot sclera** is the case the slider exists for, and its own
///   redness pushes `neutral` down, so the slider under-corrects exactly where
///   it is wanted most. The sclera knee is set loose (0.60) to limit this; it
///   does not remove it.
/// * **Metal fillings, and teeth in deep shadow**, score low and are left alone;
///   a bright lower lip highlight inside the mouth mask can score high. The
///   mouth mask is the interior only, so the lip body itself is out of scope.
/// * Every constant above is argued from what the objects physically are and is
///   **not tuned against a retoucher's eye** — the same disclosure the "Mặt"
///   group makes about its amplitudes (docs/ADR-0010). What is measured is that
///   the shader computes the documented formula (`EyesTeethReference`), not that
///   the formula is the prettiest one.
///
/// ## Nét mắt is local contrast, not a pixel-scale sharpen
/// It pushes the pixel away from the same `low` layer the whitening uses —
/// radius ~half an eye — so it separates iris from sclera and lashes from lid.
/// It cannot add detail the lens did not resolve, and it will not crisp a lash
/// at pixel scale. A true unsharp mask would need a *second* blurred layer at a
/// small radius: another 192 MB at 24 MP for one slider, which is not a trade
/// this group can make on an iPhone. Stated here rather than implied by the
/// slider's name.
///
/// ## Flags
/// Gated by `RPEngineFeatureFlags.eyesTeethSliders` **and** `.guidedFilter` (the
/// node owns a `GuidedFilter`, whose own gate is not bypassed).
/// `RPEngineFeatureFlags.enableEyesTeethRenderGraph()` sets both.
/// `.eyesTeethSliders` is owned entirely by this group — no flag is shared with
/// the "Da" or "Mặt" groups, and `disableSkinRenderGraph()` will not clear
/// `.guidedFilter` while this group still wants it (see that method).
public final class EyesTeethRenderNode: RenderNode, @unchecked Sendable {
    public let name = "eyesTeeth"
    public let stage = RenderStage.eyesTeeth

    /// Radius of the local-mean blur, as a fraction of face width.
    ///
    /// An eye opening is roughly 0.22 × face width and a mouth roughly 0.35, so
    /// 0.050 gives a 101-pixel box on a 1000 px face: wide enough that a sclera
    /// pixel's neighbourhood contains the iris and the lid, narrow enough that
    /// it does not reach the far side of the face.
    public static let localMeanRadiusFraction: CGFloat = 0.050
    /// ε for the local-mean layer. Far above any local variance, so `a → 0`,
    /// `b → mean_I` and the guided filter *is* a double box blur — the same
    /// trick ``SkinRenderNode`` uses for its `low` layer, so this group adds no
    /// second blur kernel.
    public static let localMeanEpsilon: Float = 1e6

    /// The mask kinds this node reads. Public so the app-target bridge (and its
    /// test) can ask for exactly these rather than hard-coding a list that could
    /// drift from what the node binds.
    public static let maskKinds: Set<RenderMaskKind> = [.eyes, .mouth]

    private let context: MetalContext
    private let guidedFilter: GuidedFilter
    private let eyeMask: MaskRasteriser
    private let mouthMask: MaskRasteriser
    private let compositePipeline: any MTLComputePipelineState

    /// Where the fast-guided-filter `s` for a render comes from.
    ///
    /// In production exactly `RenderQuality.guidedSubsample`, which is 4 for both
    /// qualities today (ADR-0007). It is a stored function rather than a direct
    /// call for the same reason ``SkinRenderNode`` has one: `Resources` bakes the
    /// subsampled grid in at allocation time while `encode` takes its box radius
    /// from `Options`, so a cache built for one `s` and encoded with another
    /// filters at the wrong scale — the bug ADR-0009 records. The seam lets
    /// `EyesTeethRenderNodeTests.cacheFollowsTheRequestQuality` stand in the
    /// future where the constant is split by quality, without editing the
    /// shipped constant.
    private let subsampleForQuality: @Sendable (RenderQuality) -> Int

    private let lock = NSLock()
    private var cache: Cache?

    private final class Cache {
        let width: Int
        let height: Int
        let subsample: Int
        let device: any MTLDevice
        private let guidedFilter: GuidedFilter

        /// Both of these are allocated on first use, not on first render — see
        /// the type's doc comment. A document with only "Sáng mắt" set allocates
        /// neither, and pays nothing but the two mask textures.
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

        /// What the **most recent** encode actually fed to the composite.
        ///
        /// A layer and a mask stay allocated once used, so "is it allocated" is
        /// not the same question as "did this render bind it" — reporting the
        /// former would hand a golden test a stale layer from an earlier render
        /// with different sliders. That is the bug ADR-0009 records for
        /// `SkinRenderNode.storedBase`; the two masks have the same exposure
        /// here, because a node instance is reused across requests whose sliders
        /// need different masks.
        var lastLowUsed = false
        var lastEye: (any MTLTexture)?
        var lastMouth: (any MTLTexture)?
        var storedLow: (any MTLTexture)? { lastLowUsed ? lowTexture : nil }

        var byteCount: Int {
            (lowTexture == nil ? 0 : width * height * 8) + (resources?.byteCount ?? 0)
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
        guard RPEngineFeatureFlags.eyesTeethSliders else {
            throw RPEngineFeatureDisabled(feature: "eyesTeethSliders")
        }
        self.context = context
        self.subsampleForQuality = subsampleForQuality
        // Throws RPEngineFeatureDisabled(guidedFilter) when that flag is off —
        // deliberately not bypassed here: the kernel's own gate stays meaningful.
        self.guidedFilter = try GuidedFilter(context: context)
        self.eyeMask = try MaskRasteriser(kind: .eyes, context: context)
        self.mouthMask = try MaskRasteriser(kind: .mouth, context: context)
        self.compositePipeline = try context.computePipeline("rp_eyes_teeth_composite")
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        _ = try context.computePipeline("rp_skin_mask")
        _ = try context.computePipeline("rp_eyes_teeth_composite")
        for function in ["rp_gf_downsample", "rp_gf_box_h", "rp_gf_box_v",
                         "rp_gf_coefficients", "rp_gf_reconstruct"] {
            _ = try context.computePipeline(function)
        }
    }

    public func isActive(for request: RenderRequest) -> Bool {
        let sliders = EyesTeethSliders(request.editState)
        guard !sliders.isIdentity else { return false }
        // A slider whose mask no face carries is multiplied by zero everywhere.
        // Saying so here rather than dispatching a full-resolution no-op is the
        // difference between "the slider does nothing" and "the slider costs a
        // full-frame pass to do nothing".
        let hasEyes = request.faces.contains { $0.masks[.eyes] != nil }
        let hasMouth = request.faces.contains { $0.masks[.mouth] != nil }
        return (sliders.needsEyeMask && hasEyes) || (sliders.needsMouthMask && hasMouth)
    }

    /// Bytes of GPU memory this node is holding for the current size.
    public var allocatedBytes: Int {
        lock.lock()
        let layers = cache?.byteCount ?? 0
        lock.unlock()
        return layers + eyeMask.allocatedBytes + mouthMask.allocatedBytes
    }

    public func releaseIntermediates() {
        lock.lock()
        cache = nil
        lock.unlock()
        eyeMask.releaseIntermediates()
        mouthMask.releaseIntermediates()
    }

    /// The intermediates from the most recent `encode`, so the golden harness can
    /// check the composite against a `Double` reference **fed the same layer**;
    /// otherwise a composite failure and a guided-filter failure would be
    /// indistinguishable. `nil` before the first encode.
    ///
    /// `low` is `nil` when no slider in the last request needed it, and either
    /// mask is `nil` when no face carried that kind — in both cases "absent" is
    /// the correct answer and not a failure.
    ///
    /// Internal, not public: nothing outside the tests should reach in here.
    func debugLayers()
        -> (low: (any MTLTexture)?, eyes: (any MTLTexture)?, mouth: (any MTLTexture)?)?
    {
        lock.lock()
        defer { lock.unlock() }
        guard let cache else { return nil }
        return (cache.storedLow, cache.lastEye, cache.lastMouth)
    }

    /// The fast-guided-filter `s` the cached resources were built for, or `nil`
    /// before the first encode that needed them. Internal; the regression test
    /// for the hardcoded-`.preview` bug class reads it.
    var debugGuidedSubsample: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.subsample
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let sliders = EyesTeethSliders(request.editState)
        guard !sliders.isIdentity else {
            // Not reachable through RenderGraph (isActive gates it), but a direct
            // caller must still get the picture rather than an empty texture.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        let width = source.width
        let height = source.height
        let eyeTexture =
            sliders.needsEyeMask
            ? try eyeMask.encode(
                into: commandBuffer, faces: request.faces, width: width, height: height)
            : nil
        let mouthTexture =
            sliders.needsMouthMask
            ? try mouthMask.encode(
                into: commandBuffer, faces: request.faces, width: width, height: height)
            : nil
        guard eyeTexture != nil || mouthTexture != nil else {
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        // The `s` the resources are sized for and the `s` the encode below
        // derives its box radius from must be the same number, so both come from
        // this one lookup.
        let subsample = subsampleForQuality(request.quality)
        let cache = try self.cache(width: width, height: height, subsample: subsample)

        // The blur radius follows the largest face present, exactly as the Da
        // group's does: one full-frame layer serves every face, and using the
        // largest keeps the smaller faces' neighbourhoods from being too tight.
        let faceWidth = request.faces.map(\.faceWidth).max() ?? 0
        var lowTexture: (any MTLTexture)?
        cache.lastLowUsed = sliders.needsLocalMeanLayer
        cache.lastEye = eyeTexture
        cache.lastMouth = mouthTexture
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
        // An unused layer is bound to `source`: its amounts are 0, so the mix()
        // is the identity whatever it contains, and binding nothing is undefined.
        encoder.setTexture(lowTexture ?? source, index: 1)
        // Same for an absent mask. When one kind has no mask anywhere, its
        // amounts below are forced to 0 and the *other* kind's texture is bound
        // in its place — a valid, correctly-sized r8 texture whose contents are
        // then multiplied by zero. Both being absent was rejected above, so at
        // least one is real. This avoids allocating and clearing a
        // full-resolution 24 MB texture whose only job would be to be zero.
        let boundEye = eyeTexture ?? mouthTexture
        let boundMouth = mouthTexture ?? eyeTexture
        encoder.setTexture(boundEye, index: 2)
        encoder.setTexture(boundMouth, index: 3)
        encoder.setTexture(destination, index: 4)
        var params = EyesTeethParams(
            size: SIMD2<UInt32>(UInt32(width), UInt32(height)),
            eyeBrighten: eyeTexture == nil ? 0 : Float(sliders.eyeBrighten / 100),
            eyeDefinition: eyeTexture == nil ? 0 : Float(sliders.eyeDefinition / 100),
            scleraWhiten: eyeTexture == nil ? 0 : Float(sliders.scleraWhiten / 100),
            teethWhiten: mouthTexture == nil ? 0 : Float(sliders.teethWhiten / 100))
        encoder.setBytes(&params, length: MemoryLayout<EyesTeethParams>.stride, index: 0)
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
        // A 0-radius box is the identity, which would read as "the slider did
        // nothing"; 192 is the same order of cap as the Da group's 256.
        return min(192, max(3, Int(value.rounded())))
    }

    // MARK: - Resources

    /// - Parameter subsample: the fast-guided-filter `s` the *caller's* request
    ///   asked for, never a hardcoded quality. See ``subsampleForQuality``.
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
// Must match EyesTeethShaders.metal exactly; `EyesTeethRenderNodeTests` pins the
// stride.

struct EyesTeethParams {
    var size: SIMD2<UInt32>
    var eyeBrighten: Float
    var eyeDefinition: Float
    var scleraWhiten: Float
    var teethWhiten: Float
}
