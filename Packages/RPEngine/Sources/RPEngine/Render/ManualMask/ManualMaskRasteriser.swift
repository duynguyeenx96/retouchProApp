import CoreGraphics
import Foundation
import Metal

/// Turns ``BrushStamp``s into coverage in a ``ManualMaskCoverage``
/// (docs/PLAN.md §6.1).
///
/// Two pipelines, both from `ManualMaskShaders.metal`:
/// `rp_manual_mask_clear` and `rp_manual_mask_splat`. The third kernel in that
/// file, `rp_manual_mask_modulate`, is **not** here: it gates a node rather than
/// painting, every whole-frame mask source needs it, and it must not sit behind
/// this type's `manualMask` flag — see ``GateMaskCompositor``.
///
/// ## Batching
/// Stamps go to the GPU in batches of ``maximumStampsPerBatch``, one dispatch
/// per batch over the whole mask. Per-stamp dispatches would cost a thousand
/// encoder set-ups for one long stroke; one dispatch for a thousand stamps would
/// make every thread walk a thousand distances. 64 puts the per-pixel loop at 64
/// iterations worst case and a 400-stamp stroke at 7 dispatches.
///
/// The batching is invisible in the result: the splat combines with `max` (add)
/// or `min` (subtract), which are associative, commutative and idempotent, so
/// any batching of the same stamps gives the same pixels — the property the live
/// drag and the undo replay both rely on.
///
/// ## Bounding-box dispatch (2026-09-23)
///
/// Each batch is dispatched over the **bounding box of its own stamps** (their
/// discs, clamped to the mask) instead of the whole mask, then that region is
/// blitted from the scratch texture back onto the front one. ADR-0019 §7
/// recorded why: a 19-stroke replay at a 2048 px preview cost ~405–427 ms
/// because every thread of a 2.8 M-pixel grid walked every stamp of every batch,
/// almost all of them far away. That replay is now what *opening* a shot costs
/// (the strokes are the document), and what an export pays at 24 MP.
///
/// The result is **bit-identical** to the whole-mask dispatch: a pixel outside
/// every disc of a batch has coverage 0 and the kernel writes back `existing`,
/// so skipping it changes nothing. `ManualMaskTests.liveDragMatchesAReplay`
/// and the CPU-reference test still hold unchanged.
final class ManualMaskRasteriser: @unchecked Sendable {
    /// Stamps per dispatch. See the type's note.
    static let maximumStampsPerBatch = 64

    // No stored `MetalContext`: this type only encodes into command buffers its
    // caller owns, so holding the context would be a retained reference nothing
    // reads.
    private let clearPipeline: any MTLComputePipelineState
    private let splatPipeline: any MTLComputePipelineState

    init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.manualMask else {
            throw RPEngineFeatureDisabled(feature: "manualMask")
        }
        self.clearPipeline = try context.computePipeline("rp_manual_mask_clear")
        self.splatPipeline = try context.computePipeline("rp_manual_mask_splat")
    }

    /// Builds the painting pipelines up front, off the interaction path.
    /// ``GateMaskCompositor/prewarm(context:)`` covers the gating one.
    static func prewarm(context: MetalContext) throws {
        for function in ["rp_manual_mask_clear", "rp_manual_mask_splat"] {
            _ = try context.computePipeline(function)
        }
    }

    // MARK: - Painting

    /// Fills the whole mask with `value` (0 = nothing painted).
    func encodeClear(
        into commandBuffer: any MTLCommandBuffer, coverage: ManualMaskCoverage, value: Float = 0
    ) {
        coverage.swapping { _, destination in
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(clearPipeline)
            encoder.setTexture(destination, index: 0)
            var params = ManualMaskClearParams(
                size: SIMD2<UInt32>(UInt32(coverage.width), UInt32(coverage.height)),
                value: value)
            encoder.setBytes(&params, length: MemoryLayout<ManualMaskClearParams>.stride, index: 0)
            dispatch(encoder, pipeline: clearPipeline, coverage: coverage)
            encoder.endEncoding()
        }
    }

    /// Stamps `stamps` into `coverage` with one stroke's settings.
    ///
    /// Does nothing when `stamps` is empty — an empty batch must not cost a
    /// ping-pong swap, because a swap with no dispatch would leave the *stale*
    /// side in front.
    func encodeSplat(
        into commandBuffer: any MTLCommandBuffer, coverage: ManualMaskCoverage,
        stamps: [BrushStamp], hardness: Double, flow: Double, mode: BrushMode
    ) {
        guard !stamps.isEmpty else { return }
        var index = 0
        while index < stamps.count {
            let batch = Array(stamps[index..<min(stamps.count, index + Self.maximumStampsPerBatch)])
            encodeBatch(
                into: commandBuffer, coverage: coverage, stamps: batch, hardness: hardness,
                flow: flow, mode: mode)
            index += Self.maximumStampsPerBatch
        }
    }

    private func encodeBatch(
        into commandBuffer: any MTLCommandBuffer, coverage: ManualMaskCoverage,
        stamps: [BrushStamp], hardness: Double, flow: Double, mode: BrushMode
    ) {
        guard let box = Self.boundingBox(of: stamps, width: coverage.width, height: coverage.height)
        else {
            // Every disc of this batch is off the mask: nothing to paint.
            return
        }
        var payload = stamps.map {
            ManualMaskStamp(
                center: SIMD2<Float>(Float($0.center.x), Float($0.center.y)),
                radius: Float($0.radius))
        }
        let length = MemoryLayout<ManualMaskStamp>.stride * payload.count
        coverage.withScratch { front, scratch in
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(splatPipeline)
            encoder.setTexture(front, index: 0)
            encoder.setTexture(scratch, index: 1)
            encoder.setBytes(&payload, length: length, index: 0)
            var params = ManualMaskSplatParams(
                size: SIMD2<UInt32>(UInt32(coverage.width), UInt32(coverage.height)),
                hardness: Float(hardness), flow: Float(flow),
                stampCount: UInt32(payload.count),
                subtract: mode.isSubtract ? 1 : 0,
                origin: SIMD2<UInt32>(UInt32(box.x), UInt32(box.y)))
            encoder.setBytes(&params, length: MemoryLayout<ManualMaskSplatParams>.stride, index: 1)
            let size = MetalContext.threadgroups(
                forWidth: box.width, height: box.height, pipeline: splatPipeline)
            encoder.dispatchThreadgroups(
                size.threadgroups, threadsPerThreadgroup: size.threadsPerThreadgroup)
            encoder.endEncoding()

            // The region the splat wrote, back onto the front texture. Ordered
            // after the compute pass by Metal's hazard tracking (same command
            // buffer, non-heap textures).
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(
                from: scratch, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: box.x, y: box.y, z: 0),
                sourceSize: MTLSize(width: box.width, height: box.height, depth: 1),
                to: front, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: box.x, y: box.y, z: 0))
            blit.endEncoding()
        }
    }

    /// Integer pixel rectangle covering every stamp's disc, clamped to the
    /// mask; `nil` when it is empty. One pixel of margin on each side so the
    /// smoothstep's last partial pixel is never clipped by rounding.
    static func boundingBox(
        of stamps: [BrushStamp], width: Int, height: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard !stamps.isEmpty else { return nil }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for stamp in stamps {
            let r = max(stamp.radius, 1e-4)
            minX = min(minX, Double(stamp.center.x) - r)
            minY = min(minY, Double(stamp.center.y) - r)
            maxX = max(maxX, Double(stamp.center.x) + r)
            maxY = max(maxY, Double(stamp.center.y) + r)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else {
            return (0, 0, width, height)
        }
        let x0 = max(0, Int(minX.rounded(.down)) - 1)
        let y0 = max(0, Int(minY.rounded(.down)) - 1)
        let x1 = min(width, Int(maxX.rounded(.up)) + 1)
        let y1 = min(height, Int(maxY.rounded(.up)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder, pipeline: any MTLComputePipelineState,
        coverage: ManualMaskCoverage
    ) {
        let size = MetalContext.threadgroups(
            forWidth: coverage.width, height: coverage.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            size.threadgroups, threadsPerThreadgroup: size.threadsPerThreadgroup)
    }
}

// MARK: - Shader parameter structs
//
// Must match ManualMaskShaders.metal exactly; `ManualMaskTests` pins the strides.

struct ManualMaskClearParams {
    var size: SIMD2<UInt32>
    var value: Float
}

struct ManualMaskStamp {
    var center: SIMD2<Float>
    var radius: Float
}

struct ManualMaskSplatParams {
    var size: SIMD2<UInt32>
    var hardness: Float
    var flow: Float
    var stampCount: UInt32
    var subtract: UInt32
    /// Top-left of the dispatched bounding box, in mask pixels.
    var origin: SIMD2<UInt32>
}

struct ManualMaskModulateParams {
    var imageSize: SIMD2<UInt32>
    var maskSize: SIMD2<UInt32>
    var rowX: SIMD3<Float>
    var rowY: SIMD3<Float>
    var amount: Float
}
