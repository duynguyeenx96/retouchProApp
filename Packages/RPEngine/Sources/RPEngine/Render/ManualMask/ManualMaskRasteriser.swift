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
        var payload = stamps.map {
            ManualMaskStamp(
                center: SIMD2<Float>(Float($0.center.x), Float($0.center.y)),
                radius: Float($0.radius))
        }
        let length = MemoryLayout<ManualMaskStamp>.stride * payload.count
        coverage.swapping { source, destination in
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(splatPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&payload, length: length, index: 0)
            var params = ManualMaskSplatParams(
                size: SIMD2<UInt32>(UInt32(coverage.width), UInt32(coverage.height)),
                hardness: Float(hardness), flow: Float(flow),
                stampCount: UInt32(payload.count),
                subtract: mode.isSubtract ? 1 : 0)
            encoder.setBytes(&params, length: MemoryLayout<ManualMaskSplatParams>.stride, index: 1)
            dispatch(encoder, pipeline: splatPipeline, coverage: coverage)
            encoder.endEncoding()
        }
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
}

struct ManualMaskModulateParams {
    var imageSize: SIMD2<UInt32>
    var maskSize: SIMD2<UInt32>
    var rowX: SIMD3<Float>
    var rowY: SIMD3<Float>
    var amount: Float
}
