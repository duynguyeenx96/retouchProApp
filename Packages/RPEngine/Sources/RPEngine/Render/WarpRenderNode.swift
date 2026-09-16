import CoreGraphics
import Foundation
import Metal
import RPCore

/// The "Mặt" (face reshape) slider group — ``RenderStage/warp`` on
/// ``RenderGraph``, and the second real node after ``SkinRenderNode``.
///
/// docs/PLAN.md Phase 2: *Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương,
/// Mũi (thu nhỏ/sống/đầu), Mắt (to/khoảng cách/nghiêng), Miệng (to/cười),
/// Môi đầy.* Fifteen sliders, 0–100, default 0, exact no-ops at 0.
///
/// ## Structure
/// One MLS solve and one mesh draw, both from spike S3's verified kernel:
///
/// 1. ``FaceReshape`` turns the sliders and every face's 478-point mesh into
///    `(source, destination)` handles, plus the mandatory border anchors. Pure
///    CPU value maths, ~150 handles for the whole group.
/// 2. `rp_mls_grid` evaluates `f(v)` at every vertex of a
///    `RenderQuality.meshGrid` lattice — **65 preview / 129 export**, mandatory
///    per ADR-0007.
/// 3. `rp_warp_vertex` / `rp_warp_fragment` draw that lattice with the deformed
///    positions and the *undeformed* texture coordinates, so the rasteriser does
///    the inverse mapping and no per-pixel inverse is solved.
///
/// Nothing new is compiled: all three functions are already in the spike's
/// `Spike/MetalSources/Shaders.metal`, which `MetalContext` concatenates into
/// the one library. This node adds **no third `.metal` file** and no extra
/// compile — `MetalContext.shaderSources` still has two entries.
///
/// ## Why one solve for every face
/// All faces' handles go into a single `ControlPoints`. MLS's weight is
/// `1/d^(2·alpha)` with `alpha = 2`, so a handle on one face is worth
/// ~`(d₂/d₁)⁴` less at the other face than that face's own handles — and each
/// face contributes identity handles of its own. Two separate warp passes would
/// mean two full-frame resamples and two chances to soften the picture.
///
/// ## Two `MLSMeshWarp`s, not two shader libraries
/// `MLSMeshWarp` builds its `MTLRenderPipelineState` for one colour attachment
/// format at construction. The graph's destination is `rgba16Float` in
/// production and `rgba32Float` in `RenderGraph.renderPixels` (so a golden PSNR
/// is not capped by half-float output quantisation), so this node keeps one
/// instance per destination format, both built by ``prewarm()``. That is two
/// `MTLRenderPipelineState` objects and no change to the spike class — the
/// alternative, making `encodeDraw` throw and look a pipeline up per frame, is a
/// pipeline compile on the interaction path, which is the thing `prewarm()`
/// exists to prevent.
///
/// ## Everything is relative to face width
/// No displacement in this node is a pixel count; see ``FaceReshape``. That is
/// what makes a "Mặt" preset transfer between images and what makes a preview at
/// 2048 px and an export at 24 MP render the same *shape*
/// (`FaceReshapeTests.displacementsScaleWithTheFace`).
///
/// ## The "Đầu" group rides in the same solve (Phase 6.2, docs/ADR-0022)
/// `HeadSliders` adds control points the 478-point mesh cannot supply — the
/// traced hair silhouette (``HairBoundary``) and an oval ring expanded out to it
/// — and they go into **this** node's single `ControlPoints`, not a second warp
/// pass, for the reason above: two passes are two full-frame resamples. The
/// group has its own flag, `RPEngineFeatureFlags.headSliders`, read per *render*
/// rather than in `init`, so with it off this node builds, activates and solves
/// exactly the handles it solved before Phase 6.2 — bit-exact by construction,
/// not by promise (`HeadReshapeRenderTests.flagOffIsBitExactTheOldRender`).
///
/// Gated by `RPEngineFeatureFlags.warpSliders` **and** `.mlsMeshWarp` (the node
/// owns an `MLSMeshWarp`, whose own gate is not bypassed).
/// `RPEngineFeatureFlags.enableWarpRenderGraph()` sets both, and its inverse
/// clears **only** those two: no flag is shared with the "Da" group, so turning
/// this group off cannot take that one down (docs/ADR-0010).
public final class WarpRenderNode: RenderNode, @unchecked Sendable {
    public let name = "warp"
    public let stage = RenderStage.warp

    private let context: MetalContext
    private let lock = NSLock()
    private var warps: [MTLPixelFormat: MLSMeshWarp] = [:]
    private var cache: Cache?

    /// The traced hair silhouettes, memoised across renders.
    ///
    /// Its **own** lock, not ``lock``: `HeadReshape.controlPoints` is called from
    /// `encode`, which then calls `makeWarp` and `cache(width:height:grid:)`, and
    /// both of those take `lock`. `NSLock` is not recursive, so sharing one would
    /// deadlock the first head render.
    private let silhouetteLock = NSLock()
    private let silhouettes = HeadReshape.SilhouetteCache()

    /// The lattice buffers for one (size, grid). Small: a 129² grid is 266 kB of
    /// vertices plus 394 kB of indices, independent of image size — which is why
    /// this node's memory does not appear in the 24 MP budget the way
    /// `SkinRenderNode`'s 552 MB of layers does.
    private final class Cache {
        let width: Int
        let height: Int
        let grid: Int
        let resources: MLSMeshWarp.Resources

        init(width: Int, height: Int, grid: Int, resources: MLSMeshWarp.Resources) {
            self.width = width
            self.height = height
            self.grid = grid
            self.resources = resources
        }

        /// Vertices (source + deformed, `float2` each) + `uint32` indices.
        var byteCount: Int {
            let vertices = grid * grid * 8 * 2
            let indices = (grid - 1) * (grid - 1) * 6 * 4
            return vertices + indices
        }
    }

    public init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.warpSliders else {
            throw RPEngineFeatureDisabled(feature: "warpSliders")
        }
        self.context = context
        // Throws RPEngineFeatureDisabled(mlsMeshWarp) when that flag is off —
        // deliberately not bypassed: the kernel's own gate stays meaningful.
        _ = try makeWarp(for: .rgba16Float)
    }

    public func prewarm() throws {
        _ = try context.computePipeline("rp_render_copy")
        _ = try context.computePipeline("rp_mls_grid")
        // Both destination formats the graph can hand this node.
        _ = try makeWarp(for: .rgba16Float)
        _ = try makeWarp(for: .rgba32Float)
    }

    /// The masks this node reads. Empty until the "Đầu" group is on: the "Mặt"
    /// sliders are landmarks only.
    public static let maskKinds: Set<RenderMaskKind> = [.hair]

    public func isActive(for request: RenderRequest) -> Bool {
        let face = !FaceSliders(request.editState).isIdentity
        let head = Self.headSlidersEnabled(for: request)
        guard face || head else { return false }
        // A face with no mesh (the Da group only needs masks, so an empty
        // `landmarks` is legal) or a degenerate width cannot drive a reshape.
        // Saying so here rather than solving a grid of identity vertices is the
        // difference between "the slider does nothing" and "the slider costs a
        // full-frame resample to do nothing".
        return request.faces.contains {
            guard $0.landmarks.count > FaceMesh.highestIndex, $0.faceWidth > 0 else {
                return false
            }
            // A head-only edit additionally needs a **usable** silhouette, and
            // that is a question about the mask's contents, not about whether one
            // was attached.
            //
            // Asking `masks[.hair] != nil` was wrong, and wrong in the direction
            // that never shows up in a unit test: `FaceAnalysisRenderBridge`
            // attaches a `.hair` mask for **every** face whose parsing succeeded
            // and for every requested kind, so in production the key is always
            // present — including for a subject in a hat, a shaved head, or a
            // parsing miss, where the mask is real and its coverage is all below
            // `HairBoundary.coverageThreshold`. The node would then be scheduled,
            // find no silhouette inside `encode`, and fall back to
            // `RenderGraph.encodeCopy` — a real full-frame GPU copy to produce a
            // picture identical to its input, which is exactly the cost this
            // branch exists to avoid.
            //
            // So it traces. That is not an extra trace: it goes through the same
            // `SilhouetteCache` `encode` uses, keyed on the mask and the mesh by
            // value, so the first `isActive` of a shot pays the ~1.4 ms once and
            // the encode that follows it is a cache hit. A frame that is inactive
            // pays it once too, and then answers `false` for free for the rest of
            // the drag.
            return face || self.hasUsableSilhouette($0)
        }
    }

    /// "Không phát hiện được viền tóc." — the "Đầu" sliders are asking for
    /// something and no face in the frame has a traceable hairline.
    ///
    /// This is the notice that could not be derived from `isActive(for:)` alone:
    /// the state it reports is exactly the state that makes `isActive` answer
    /// `false`, so the graph skips the node, the picture does not change, and
    /// without this the user is told nothing at all. (``RenderGraph`` therefore
    /// asks every node, not just the active ones.)
    ///
    /// The "no usable silhouette" test is literally the one `isActive` runs —
    /// ``hasUsableSilhouette(_:)``, memoised through the node's own
    /// `HeadReshape.SilhouetteCache` — so asking costs a dictionary lookup per
    /// face after the first trace of the shot, and a frame that already answered
    /// `isActive` has paid for the answer.
    ///
    /// Silent when the group's flag is off (the user cannot have asked for it)
    /// and when the sliders are at 0 (nothing was asked for), which is the same
    /// pair of conditions ``headSlidersEnabled(for:)`` gates the handles with.
    /// A frame with **no faces at all** does produce the notice; in the panel
    /// that case is caught earlier and more precisely by the group's own
    /// `needsFace` check ("Không nhận diện được khuôn mặt trong ảnh này"), which
    /// `RPUI.GroupAvailability` evaluates first.
    public func detectionNotice(for request: RenderRequest) -> String? {
        guard Self.headSlidersEnabled(for: request) else { return nil }
        let usable = request.faces.contains { face in
            face.landmarks.count > FaceMesh.highestIndex && face.faceWidth > 0
                && hasUsableSilhouette(face)
        }
        return usable ? nil : Self.noHairBoundaryNotice
    }

    /// What the user is told when no face has a traceable hair silhouette.
    public static let noHairBoundaryNotice = "Không phát hiện được viền tóc."

    /// Does this face have a hair silhouette the "Đầu" group could act on?
    ///
    /// Memoised through the node's own ``HeadReshape/SilhouetteCache``, so this
    /// is the *same* trace `encode` needs rather than a second one.
    private func hasUsableSilhouette(_ input: FaceRenderInput) -> Bool {
        guard let hair = input.masks[.hair] else { return false }
        silhouetteLock.lock()
        defer { silhouetteLock.unlock() }
        return silhouettes.silhouette(
            landmarks: input.landmarks, faceWidth: input.faceWidth, hair: hair) != nil
    }

    /// Is the "Đầu" group both enabled and asking for something?
    ///
    /// Read per render, never cached: the flag is process-global and a test that
    /// flips it must not be answered from a value this node latched at `init`.
    private static func headSlidersEnabled(for request: RenderRequest) -> Bool {
        RPEngineFeatureFlags.headSliders && !HeadSliders(request.editState).isIdentity
    }

    /// Bytes of GPU memory this node is holding for the current size and grid.
    public var allocatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache?.byteCount ?? 0
    }

    public func releaseIntermediates() {
        lock.lock()
        cache = nil
        lock.unlock()
        // The silhouettes are CPU value types, not GPU memory, but this is the
        // "forget what you know about the last shot" call and a stale hairline
        // would be the wrong thing to keep across it.
        silhouetteLock.lock()
        silhouettes.clear()
        silhouetteLock.unlock()
    }

    /// The handles the given request would produce, without touching the GPU.
    /// Used by the golden harness and by the bench; also the cheapest way for a
    /// UI to show "this edit moves N landmarks".
    public func controlPoints(for request: RenderRequest, imageSize: CGSize)
        -> FaceReshape.Built?
    {
        FaceReshape.controlPoints(
            faces: request.faces, sliders: FaceSliders(request.editState),
            imageSize: imageSize)
    }

    /// The combined "Mặt" + "Đầu" handles, or `nil` when the head group is off or
    /// asleep — in which case the caller falls back to ``controlPoints(for:imageSize:)``
    /// and the solve is byte-identical to the pre-Phase-6.2 one.
    ///
    /// Public for the same reason ``controlPoints(for:imageSize:)`` is: the bench
    /// and the golden harness need the handles without a GPU.
    public func headControlPoints(for request: RenderRequest, imageSize: CGSize)
        -> HeadReshape.Built?
    {
        guard Self.headSlidersEnabled(for: request) else { return nil }
        silhouetteLock.lock()
        defer { silhouetteLock.unlock() }
        return HeadReshape.controlPoints(
            faces: request.faces, face: FaceSliders(request.editState),
            head: HeadSliders(request.editState), imageSize: imageSize,
            cache: silhouettes)
    }

    /// How many hair masks this node has actually traced. Internal; the
    /// regression test for "a slider drag does not re-trace" reads it.
    var debugTraceCount: Int {
        silhouetteLock.lock()
        defer { silhouetteLock.unlock() }
        return silhouettes.traceCount
    }

    /// The control points this node would solve for a request: head-aware when
    /// the group is on and active, the "Mặt" group's alone otherwise.
    func solvedControlPoints(for request: RenderRequest, imageSize: CGSize)
        -> MLSDeformation.ControlPoints?
    {
        if let head = headControlPoints(for: request, imageSize: imageSize) {
            return head.control
        }
        return controlPoints(for: request, imageSize: imageSize)?.control
    }

    /// The lattice the **most recent** `encode` solved, in image pixels, or `nil`
    /// before the first encode. This is what the golden test compares against
    /// `MLSDeformation.grid`'s `Double` reference.
    ///
    /// Internal, not public: nothing outside the tests should reach in here.
    func debugDeformedGrid() -> (points: [CGPoint], grid: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let cache else { return nil }
        guard let warp = warps[.rgba16Float] ?? warps.values.first else { return nil }
        return (warp.readDeformedGrid(cache.resources), cache.grid)
    }

    /// The grid the cached lattice was built for, or `nil`. Internal; the
    /// regression test for "preview and export must not share a lattice" reads it.
    var debugGrid: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.grid
    }

    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        request: RenderRequest
    ) throws {
        let imageSize = CGSize(width: source.width, height: source.height)
        guard let control = solvedControlPoints(for: request, imageSize: imageSize) else {
            // Reachable through the graph only for a degenerate mesh (isActive
            // gates the slider values), and directly for any request. Either way
            // the caller asked for the picture in `destination`.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
            return
        }

        let options = FaceReshape.options(for: request.quality)
        let cache = try self.cache(
            width: source.width, height: source.height, grid: options.gridWidth)
        let warp = try makeWarp(for: destination.pixelFormat)
        try warp.encode(
            into: commandBuffer, source: source, destination: destination,
            resources: cache.resources, control: control, options: options)
    }

    // MARK: - Resources

    private func makeWarp(for pixelFormat: MTLPixelFormat) throws -> MLSMeshWarp {
        lock.lock()
        defer { lock.unlock() }
        if let existing = warps[pixelFormat] { return existing }
        let made = try MLSMeshWarp(context: context, pixelFormat: pixelFormat)
        warps[pixelFormat] = made
        return made
    }

    /// - Parameter grid: `RenderQuality.meshGrid` for the *caller's* request.
    ///   Keyed on, not assumed: preview and export genuinely differ (65 vs 129),
    ///   unlike `guidedSubsample`, so a cache that ignored it would render an
    ///   export at preview density — the exact class of bug ADR-0009 records for
    ///   `SkinRenderNode.cache`, except here it would fire today rather than the
    ///   day a constant is split.
    private func cache(width: Int, height: Int, grid: Int) throws -> Cache {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache, existing.width == width, existing.height == height,
            existing.grid == grid
        {
            return existing
        }
        guard let warp = warps[.rgba16Float] ?? warps.values.first else {
            throw RPEngineFeatureDisabled(feature: "mlsMeshWarp")
        }
        let resources = try warp.makeResources(
            imageSize: CGSize(width: width, height: height),
            options: MLSDeformation.Options(gridWidth: grid, gridHeight: grid))
        let made = Cache(width: width, height: height, grid: grid, resources: resources)
        cache = made
        return made
    }
}
