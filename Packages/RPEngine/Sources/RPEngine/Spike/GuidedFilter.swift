import Foundation
import Metal

/// Self-guided edge-preserving smoothing (He, Sun & Tang 2010), Metal compute.
///
/// docs/PLAN.md §1.3 lists "Mịn da giữ texture" as *guided filter + high-pass
/// giữ lỗ chân lông × skin mask*. This type is the first of those three: the
/// smoothed layer. The high-pass recombination and the skin mask are Phase 2 and
/// deliberately not here — a spike that also guesses at the look cannot produce
/// a trustworthy speed number for the part that is expensive.
///
/// Gated by `RPEngineFeatureFlags.guidedFilter`.
///
/// ### Why not `MPSImageGuidedFilter`
/// MPS ships one (`MPSImage/MPSImageGuidedFilter.h`). It solves a different
/// problem: its regression fits a **cross-channel** affine map from an RGB
/// guide to a single-channel source (`a.r*R + a.g*G + a.b*B + b`) and it has no
/// second box pass over `a`/`b` — the smoothing of the coefficients is supposed
/// to come from evaluating the regression at low resolution and letting
/// reconstruction upsample. That is the right shape for alpha-matte upsampling,
/// which is what it was built for; it is not the textbook filter, and running it
/// at full resolution produces the un-averaged coefficients. Spike S3 measures
/// it side by side as a control (see `Research/spikes/S3-guided-filter-mls/`)
/// rather than dismissing it on argument.
public final class GuidedFilter {
    public struct Options: Sendable, Equatable {
        /// Box radius in **full-resolution** pixels.
        public var radius: Int
        /// Regularisation. Interpreted as a variance on the pixel values, so it
        /// is tied to `SpikeTextureIO.PixelSpace`.
        public var epsilon: Float
        /// Fast-guided-filter subsampling factor `s` (He & Sun 2015).
        /// `1` is the exact filter; `4` is the paper's recommendation.
        public var subsample: Int
        /// 0 = original pixels, 1 = fully smoothed.
        public var amount: Float

        public init(radius: Int = 16, epsilon: Float = 1e-3, subsample: Int = 4,
                    amount: Float = 1.0) {
            self.radius = radius
            self.epsilon = epsilon
            self.subsample = subsample
            self.amount = amount
        }

        /// Radius actually used at the subsampled resolution. Never below 1:
        /// a zero-radius box makes the filter the identity, which would look
        /// like "the filter did nothing" rather than "s was too large".
        public var subsampledRadius: Int { max(1, Int((Double(radius) / Double(max(1, subsample))).rounded())) }
    }

    /// The six subsampled float32 intermediates, allocated once and reused.
    ///
    /// Allocating these per frame is not free at 24 MP, and a slider drag hits
    /// the filter 30–60 times a second on the *same* size, so the benchmark
    /// measures steady state with these live and reports allocation separately.
    public final class Resources {
        public let width: Int
        public let height: Int
        public let subsample: Int
        public let subWidth: Int
        public let subHeight: Int
        let textures: [any MTLTexture]

        /// Bytes of GPU memory held by the intermediates.
        public var byteCount: Int { subWidth * subHeight * 16 * textures.count }

        init(device: any MTLDevice, width: Int, height: Int, subsample: Int) throws {
            let s = max(1, subsample)
            self.width = width
            self.height = height
            self.subsample = s
            self.subWidth = (width + s - 1) / s
            self.subHeight = (height + s - 1) / s
            var made: [any MTLTexture] = []
            for _ in 0..<6 {
                made.append(
                    try SpikeTextureIO.makeTexture(
                        width: subWidth, height: subHeight, device: device,
                        pixelFormat: .rgba32Float, usage: [.shaderRead, .shaderWrite]))
            }
            self.textures = made
        }
    }

    private let context: MetalContext
    private let downsample: any MTLComputePipelineState
    private let boxH: any MTLComputePipelineState
    private let boxV: any MTLComputePipelineState
    private let coefficients: any MTLComputePipelineState
    private let reconstruct: any MTLComputePipelineState

    public init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.guidedFilter else {
            throw RPEngineFeatureDisabled(feature: "guidedFilter")
        }
        self.context = context
        self.downsample = try context.computePipeline("rp_gf_downsample")
        self.boxH = try context.computePipeline("rp_gf_box_h")
        self.boxV = try context.computePipeline("rp_gf_box_v")
        self.coefficients = try context.computePipeline("rp_gf_coefficients")
        self.reconstruct = try context.computePipeline("rp_gf_reconstruct")
    }

    public func makeResources(width: Int, height: Int, options: Options) throws -> Resources {
        try Resources(
            device: context.device, width: width, height: height, subsample: options.subsample)
    }

    /// Encodes the whole filter into `commandBuffer`. Nothing is committed or
    /// waited on here, so a caller can chain it with the rest of a frame.
    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        resources: Resources,
        options: Options
    ) {
        precondition(source.width == resources.width && source.height == resources.height)
        precondition(destination.width == source.width && destination.height == source.height)
        // The grid this pass runs on comes from `resources` (baked in when the
        // textures were allocated) but the box radius comes from
        // `options.subsampledRadius`. If the two `s` values disagree, every box
        // filter runs at the wrong scale relative to the grid it is filtering:
        // wrong pixels, no crash, no exception — so it is asserted here rather
        // than left to a golden test to notice.
        precondition(
            resources.subsample == max(1, options.subsample),
            """
            GuidedFilter.Resources was built for s=\(resources.subsample) but encode was \
            called with options.subsample=\(options.subsample). Build the resources from \
            the same Options you encode with.
            """)

        let sub = (resources.subWidth, resources.subHeight)
        let t = resources.textures

        // 1. full-res -> subsampled I and I*I
        encodeCompute(commandBuffer, downsample, width: sub.0, height: sub.1) { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(t[0], index: 1)
            encoder.setTexture(t[1], index: 2)
            var params = GFDownsampleParams(
                sourceSize: SIMD2<UInt32>(UInt32(resources.width), UInt32(resources.height)),
                subSize: SIMD2<UInt32>(UInt32(sub.0), UInt32(sub.1)),
                subsample: UInt32(resources.subsample))
            encoder.setBytes(&params, length: MemoryLayout<GFDownsampleParams>.stride, index: 0)
        }

        let r = options.subsampledRadius
        // 2-3. box(I), box(I*I)
        encodeBox(commandBuffer, sub: sub, radius: r, inA: t[0], inB: t[1],
                  tmpA: t[2], tmpB: t[3], outA: t[4], outB: t[5])

        // 4. a, b
        encodeCompute(commandBuffer, coefficients, width: sub.0, height: sub.1) { encoder in
            encoder.setTexture(t[4], index: 0)
            encoder.setTexture(t[5], index: 1)
            encoder.setTexture(t[0], index: 2)
            encoder.setTexture(t[1], index: 3)
            var params = GFCoefficientParams(
                size: SIMD2<UInt32>(UInt32(sub.0), UInt32(sub.1)), epsilon: options.epsilon)
            encoder.setBytes(&params, length: MemoryLayout<GFCoefficientParams>.stride, index: 0)
        }

        // 5-6. box(a), box(b)
        encodeBox(commandBuffer, sub: sub, radius: r, inA: t[0], inB: t[1],
                  tmpA: t[2], tmpB: t[3], outA: t[4], outB: t[5])

        // 7. q = mean_a * I + mean_b, blended by `amount`
        encodeCompute(commandBuffer, reconstruct, width: resources.width, height: resources.height) {
            encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(t[4], index: 1)
            encoder.setTexture(t[5], index: 2)
            encoder.setTexture(destination, index: 3)
            // The coefficient textures cover s*subWidth full-res columns, which
            // is >= width when width is not a multiple of s. Dividing by width
            // here would stretch the smoothed layer by up to s-1 pixels.
            var params = GFReconstructParams(
                size: SIMD2<UInt32>(UInt32(resources.width), UInt32(resources.height)),
                coefficientDenominator: SIMD2<Float>(
                    Float(resources.subsample * resources.subWidth),
                    Float(resources.subsample * resources.subHeight)),
                amount: options.amount)
            encoder.setBytes(&params, length: MemoryLayout<GFReconstructParams>.stride, index: 0)
        }
    }

    private func encodeBox(
        _ commandBuffer: any MTLCommandBuffer,
        sub: (Int, Int), radius: Int,
        inA: any MTLTexture, inB: any MTLTexture,
        tmpA: any MTLTexture, tmpB: any MTLTexture,
        outA: any MTLTexture, outB: any MTLTexture
    ) {
        var params = GFBoxParams(
            size: SIMD2<UInt32>(UInt32(sub.0), UInt32(sub.1)), radius: Int32(radius))
        encodeCompute(commandBuffer, boxH, width: sub.0, height: sub.1) { encoder in
            encoder.setTexture(inA, index: 0)
            encoder.setTexture(inB, index: 1)
            encoder.setTexture(tmpA, index: 2)
            encoder.setTexture(tmpB, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<GFBoxParams>.stride, index: 0)
        }
        encodeCompute(commandBuffer, boxV, width: sub.0, height: sub.1) { encoder in
            encoder.setTexture(tmpA, index: 0)
            encoder.setTexture(tmpB, index: 1)
            encoder.setTexture(outA, index: 2)
            encoder.setTexture(outB, index: 3)
            encoder.setBytes(&params, length: MemoryLayout<GFBoxParams>.stride, index: 0)
        }
    }

    private func encodeCompute(
        _ commandBuffer: any MTLCommandBuffer,
        _ pipeline: any MTLComputePipelineState,
        width: Int, height: Int,
        _ configure: (any MTLComputeCommandEncoder) -> Void
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let dispatch = MetalContext.threadgroups(
            forWidth: width, height: height, pipeline: pipeline)
        encoder.dispatchThreadgroups(
            dispatch.threadgroups, threadsPerThreadgroup: dispatch.threadsPerThreadgroup)
        encoder.endEncoding()
    }
}

// MARK: - Shader parameter structs
//
// Field order and padding must match Shaders.metal exactly. Swift's SIMD2<UInt32>
// is 8 bytes / 8-aligned and Metal's uint2 is the same, so these lay out
// identically; `GuidedFilterTests.parameterStructsMatchShaderLayout` pins the
// sizes so a field added on one side cannot silently shift the other.

struct GFDownsampleParams {
    var sourceSize: SIMD2<UInt32>
    var subSize: SIMD2<UInt32>
    var subsample: UInt32
}

struct GFBoxParams {
    var size: SIMD2<UInt32>
    var radius: Int32
}

struct GFCoefficientParams {
    var size: SIMD2<UInt32>
    var epsilon: Float
}

struct GFReconstructParams {
    var size: SIMD2<UInt32>
    var coefficientDenominator: SIMD2<Float>
    var amount: Float
}
