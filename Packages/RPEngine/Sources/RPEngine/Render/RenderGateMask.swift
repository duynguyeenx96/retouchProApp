import CoreGraphics
import Foundation
import Metal

/// A whole-frame coverage texture that **narrows** what a node is allowed to
/// touch, without changing what the node does inside that region.
///
/// ## Why this is one slot and not one per feature
///
/// docs/PLAN.md §6.1 has two features that both want to hand a node a mask that
/// belongs to no face:
///
/// * **Cọ mask thủ công** — the hand-painted brush (``ManualMaskCoverage``);
/// * **Khoá nền** — the whole-frame subject mask (``BackgroundLockMaskSource``),
///   which deliberately stopped at "mask ready, not wired" precisely so that the
///   two would share one slot rather than add one each (docs/ADR-0018).
///
/// and §6.2's "đồng bộ da toàn thân" names a third: a full-frame skin mask that
/// `SkinRenderNode` must merge in the same place. Three separate
/// `RenderRequest` members would mean three `if let` chains in every node and
/// three answers to "what happens when two of them are set". One protocol and
/// one array answers it once: **gates intersect**, in order, by multiplication.
///
/// ## Intersection is the only defensible composition
///
/// If the user has painted a brush region *and* locked the background, the
/// effect belongs where both say yes. `min` would be an alternative reading, but
/// the masks are soft (a feathered brush edge, a segmentation's uncertain hair
/// boundary) and multiplying two 0…1 coverages is what
/// `rp_manual_mask_modulate` already does — it is the same arithmetic the
/// `MaskRasteriser` path has used since docs/ADR-0009, applied one more time.
///
/// ## An empty array is not an all-zero mask
///
/// No gates ⇒ the node renders exactly the pixels it rendered before Phase 6.1.
/// That is a load-bearing distinction: reading "no mask" as "select nothing"
/// would silently switch off every mask-driven slider in every document that
/// never used a brush, and it would invalidate the golden numbers in
/// ADR-0009 … ADR-0012 for every existing render.
///
/// ## Why a class protocol
///
/// A gate is repainted while the user drags a finger and the canvas re-issues
/// its `RenderRequest` tens of times a second. A value type would copy megabytes
/// of coverage per frame; a reference lets the request point at the live
/// texture. Nodes only ever read it.
public protocol RenderGateMask: AnyObject, Sendable {
    /// The `r8Unorm` coverage: 1 = the node may act here, 0 = it may not.
    ///
    /// Re-read on every encode rather than cached, because a painted mask
    /// ping-pongs between two textures as it is drawn.
    var gateTexture: any MTLTexture { get }
    var gateWidth: Int { get }
    var gateHeight: Int { get }
    /// Mask pixels (y down) → image pixels (y down).
    ///
    /// Identity when the gate was produced at the size of the texture being
    /// rendered — the live-preview case. A scale when a mask painted on the
    /// 2048 px preview is re-used against the full-resolution frame at export
    /// time, which is the whole reason this is a transform and not an assumption.
    var gateMaskToImage: CGAffineTransform { get }
    /// Bumped whenever the coverage changes, so a consumer can tell "the mask
    /// moved" from "the same mask again" without comparing pixels.
    var gateGeneration: Int { get }

    /// Whether this gate may narrow a node **right now**.
    ///
    /// Each source answers for its own feature flag, and a node skips the gates
    /// that say no. One shared `if RPEngineFeatureFlags.manualMask` in the node
    /// would be wrong in both directions: it would let a painted mask act after
    /// the brush was switched off if it were missing, and — the reason this is a
    /// per-gate question — it would silently ignore "Khoá nền"'s subject mask,
    /// which is gated by `backgroundLock` and has nothing to do with the brush.
    ///
    /// Defaults to `true`: a gate that carries no flag of its own is always
    /// live.
    var isGateEnabled: Bool { get }
}

extension RenderGateMask {
    /// Image pixels → mask pixels. What the shader needs: it walks the
    /// destination and pulls, the same direction `rp_skin_mask` goes.
    public var gateImageToMask: CGAffineTransform { gateMaskToImage.inverted() }

    public var isGateEnabled: Bool { true }
}

/// Adapts a plain coverage texture to ``RenderGateMask``.
///
/// This is the seam that lets "Khoá nền" plug into the gate slot with no rework
/// when its UI lands: `BackgroundLockMaskSource.encode(…)` already returns a
/// full-resolution `r8Unorm` texture in image space, which is exactly
/// `TextureGateMask(texture:)` with the identity transform. Nothing in
/// `BackgroundLockMaskSource` has to change, and nothing in the nodes has to
/// learn a second mask shape.
///
/// It is also what a test uses to exercise the gate path without allocating a
/// whole ``ManualMaskSession``.
public final class TextureGateMask: RenderGateMask, @unchecked Sendable {
    public let gateTexture: any MTLTexture
    public let gateMaskToImage: CGAffineTransform
    public private(set) var gateGeneration: Int

    public var gateWidth: Int { gateTexture.width }
    public var gateHeight: Int { gateTexture.height }

    /// - Parameters:
    ///   - texture: an `r8Unorm` coverage texture.
    ///   - maskToImage: identity when `texture` is already at the size of the
    ///     picture being rendered, which is the case for every mask
    ///     `MaskRasteriser` produces.
    ///   - generation: a caller that swaps the texture's contents should bump
    ///     this through ``markChanged()`` so a consumer can notice.
    public init(
        texture: any MTLTexture, maskToImage: CGAffineTransform = .identity, generation: Int = 0
    ) {
        self.gateTexture = texture
        self.gateMaskToImage = maskToImage
        self.gateGeneration = generation
    }

    public func markChanged() { gateGeneration &+= 1 }
}

/// Multiplies ``RenderGateMask``s into a node's existing coverage texture.
///
/// One kernel — `rp_manual_mask_modulate`, which lives in
/// ManualMaskShaders.metal because the brush is what first needed it — and
/// deliberately **not** behind `RPEngineFeatureFlags.manualMask`, unlike
/// ``ManualMaskRasteriser``. That flag gates *painting*: with it off no
/// `ManualMaskCoverage` can be constructed, so no painted gate can reach here
/// anyway (and ``RenderGateMask/isGateEnabled`` re-checks per gate). Gating the
/// composite on it as well would mean "Khoá nền", whose mask is a plain texture
/// under its own `backgroundLock` flag, could not be wired up without moving
/// this check — exactly the rework docs/ADR-0018 deferred this slot in order to
/// avoid.
///
/// Costs nothing when unused: a node builds one lazily, on the first request
/// that actually carries a gate.
final class GateMaskCompositor: @unchecked Sendable {
    private let pipeline: any MTLComputePipelineState

    init(context: MetalContext) throws {
        self.pipeline = try context.computePipeline("rp_manual_mask_modulate")
    }

    /// Builds the pipeline up front, off the interaction path.
    static func prewarm(context: MetalContext) throws {
        _ = try context.computePipeline("rp_manual_mask_modulate")
    }

    /// Writes `coverage x gate` into `destination`.
    ///
    /// This is the whole of "gate a node with a whole-frame mask": the node
    /// keeps its kernel, its constants and its measured behaviour, and only the
    /// coverage texture it binds changes (docs/PLAN.md §6.1 — *"không phải kỹ
    /// thuật mới, chỉ thêm 1 nguồn mask nữa"*). Calling it repeatedly,
    /// ping-ponging `coverage` and `destination`, is how several gates
    /// intersect.
    ///
    /// - Parameter amount: 0…1 cross-fade between the ungated and the gated
    ///   coverage. 1 in the product today; a cross-fade rather than a hard
    ///   switch so a future "strength" control needs no new kernel.
    func encode(
        into commandBuffer: any MTLCommandBuffer,
        coverage: any MTLTexture,
        gate: any RenderGateMask,
        destination: any MTLTexture,
        amount: Double = 1
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(coverage, index: 0)
        encoder.setTexture(gate.gateTexture, index: 1)
        encoder.setTexture(destination, index: 2)
        let t = gate.gateImageToMask
        var params = ManualMaskModulateParams(
            imageSize: SIMD2<UInt32>(UInt32(coverage.width), UInt32(coverage.height)),
            maskSize: SIMD2<UInt32>(UInt32(gate.gateWidth), UInt32(gate.gateHeight)),
            rowX: SIMD3<Float>(Float(t.a), Float(t.c), Float(t.tx)),
            rowY: SIMD3<Float>(Float(t.b), Float(t.d), Float(t.ty)),
            amount: Float(min(1, max(0, amount))))
        encoder.setBytes(&params, length: MemoryLayout<ManualMaskModulateParams>.stride, index: 0)
        let size = MetalContext.threadgroups(
            forWidth: coverage.width, height: coverage.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            size.threadgroups, threadsPerThreadgroup: size.threadsPerThreadgroup)
        encoder.endEncoding()
    }
}
