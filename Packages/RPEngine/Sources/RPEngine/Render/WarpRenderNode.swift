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

    public func isActive(for request: RenderRequest) -> Bool {
        guard !FaceSliders(request.editState).isIdentity else { return false }
        // A face with no mesh (the Da group only needs masks, so an empty
        // `landmarks` is legal) or a degenerate width cannot drive a reshape.
        // Saying so here rather than solving a grid of identity vertices is the
        // difference between "the slider does nothing" and "the slider costs a
        // full-frame resample to do nothing".
        return request.faces.contains {
            $0.landmarks.count > FaceMesh.highestIndex && $0.faceWidth > 0
        }
    }

    /// Bytes of GPU memory this node is holding for the current size and grid.
    public var allocatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache?.byteCount ?? 0
    }

    public func releaseIntermediates() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
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
        guard let built = controlPoints(for: request, imageSize: imageSize) else {
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
            resources: cache.resources, control: built.control, options: options)
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
