import CoreGraphics
import Foundation
import Metal
import Testing

@testable import RPEngine

/// Phase 0 spike S3 — guided filter correctness.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global.
@Suite("Spike S3 guided filter", .serialized)
struct GuidedFilterTests {
    /// A field added on one side of the Swift/Metal boundary silently shifts
    /// every field after it and the kernel reads garbage, which looks like a
    /// numerics bug rather than a layout bug. Pin the sizes.
    @Test("Shader parameter structs have the layout the .metal file declares")
    func parameterStructsMatchShaderLayout() {
        #expect(MemoryLayout<GFDownsampleParams>.stride == 24)  // uint2, uint2, uint
        #expect(MemoryLayout<GFBoxParams>.stride == 16)  // uint2, int
        #expect(MemoryLayout<GFCoefficientParams>.stride == 16)  // uint2, float
        #expect(MemoryLayout<GFReconstructParams>.stride == 24)  // uint2, float2, float
        #expect(MemoryLayout<MLSParams>.stride == 32)  // uint,float,uint,uint, uint2, float2
    }

    @Test("Constructing the filter with the flag off throws")
    func flagGatesConstruction() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.guidedFilter = false }
        defer { flags.leave { RPEngineFeatureFlags.guidedFilter = false } }
        #expect(throws: RPEngineFeatureDisabled.self) { try GuidedFilter(context: context) }
    }

    /// The control that says the Metal kernel is the filter from the paper.
    /// The CPU side is written from He, Sun & Tang's five lines in `Double`; the
    /// GPU side is `subsample = 1`, i.e. the exact filter with no fast-path
    /// approximation, and writes to an RGBA32Float target so the comparison is
    /// not limited by half-float output.
    @Test("Exact (subsample=1) Metal filter matches a Double CPU reference")
    func exactFilterMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 96, height = 64
        let radius = 5
        let epsilon = 1e-3

        let pixels = SpikeS3Support.syntheticImage(width: width, height: height)
        // The GPU reads a half-float source, so the reference must start from the
        // *same* quantised values, otherwise 5e-4 of upload rounding is charged
        // to the kernel.
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))

        let options = GuidedFilter.Options(
            radius: radius, epsilon: Float(epsilon), subsample: 1, amount: 1)
        let output = try SpikeS3Support.runGuidedFilter(
            context, pixels: quantised, width: width, height: height, options: options)

        var worst = 0.0
        for c in 0..<3 {
            let reference = SpikeS3Support.referenceGuidedFilter(
                SpikeS3Support.channel(quantised, c), width: width, height: height,
                radius: radius, epsilon: epsilon)
            let measured = SpikeS3Support.channel(output, c)
            for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
        }
        print("S3 guided filter vs CPU reference: max abs diff = \(worst)")
        // float32 box sums over 11 taps twice; 1e-4 is ~1000x looser than the
        // arithmetic and ~5x tighter than half-float, so it can only fail on a
        // real algorithmic difference.
        #expect(worst < 1e-4, "max abs diff \(worst)")
    }

    /// With epsilon far above any local variance, `a → 0` and `b → mean_I`, so
    /// the filter degenerates to a box blur applied twice. An independent
    /// closed form, so it catches a coefficient pass that is wired backwards.
    @Test("epsilon → ∞ degenerates to a double box blur")
    func hugeEpsilonIsDoubleBox() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 64, height = 48, radius = 3
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 7)
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))
        let options = GuidedFilter.Options(
            radius: radius, epsilon: 1e6, subsample: 1, amount: 1)
        let output = try SpikeS3Support.runGuidedFilter(
            context, pixels: quantised, width: width, height: height, options: options)

        var worst = 0.0
        for c in 0..<3 {
            let source = SpikeS3Support.channel(quantised, c)
            let twice = boxTwice(source, width: width, height: height, radius: radius)
            let measured = SpikeS3Support.channel(output, c)
            for i in 0..<twice.count { worst = max(worst, abs(twice[i] - measured[i])) }
        }
        print("S3 guided filter epsilon=1e6 vs double box: max abs diff = \(worst)")
        #expect(worst < 2e-4, "max abs diff \(worst)")
    }

    @Test("amount = 0 returns the source untouched")
    func zeroAmountIsIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 40, height = 32
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 3)
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))
        let output = try SpikeS3Support.runGuidedFilter(
            context, pixels: quantised, width: width, height: height,
            options: GuidedFilter.Options(radius: 4, epsilon: 1e-3, subsample: 2, amount: 0))
        let worst = SpikeTextureIO.maxAbsoluteDifference(quantised, output)
        #expect(worst == 0, "max abs diff \(worst)")
    }

    /// The half-texel mapping in `rp_gf_reconstruct` is easy to get wrong and
    /// the symptom is a *shift* of the smoothed layer, not a crash. A source
    /// whose width is not a multiple of `s` is the case that separates the two
    /// candidate denominators; check the fast path stays aligned with the exact
    /// one by measuring PSNR against it.
    @Test("Fast (subsampled) filter stays aligned with the exact filter")
    func fastFilterMatchesExactWithinTolerance() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 203, height = 149  // deliberately coprime with every s below
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 11)
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))

        let exact = try SpikeS3Support.runGuidedFilter(
            context, pixels: quantised, width: width, height: height,
            options: GuidedFilter.Options(radius: 12, epsilon: 4e-3, subsample: 1, amount: 1))

        var report: [String: Double] = [:]
        for s in [2, 4, 8] {
            let fast = try SpikeS3Support.runGuidedFilter(
                context, pixels: quantised, width: width, height: height,
                options: GuidedFilter.Options(radius: 12, epsilon: 4e-3, subsample: s, amount: 1))
            let psnr = SpikeTextureIO.psnr(exact, fast)
            report["s=\(s)"] = psnr
            print("S3 fast guided filter s=\(s): PSNR vs exact = \(psnr) dB")
        }
        // Not the plan's 45 dB golden-render bar — that is Phase 2's, on the
        // whole pipeline. This only asserts the fast path is the same filter and
        // not a shifted one: a half-texel misalignment on this image drops PSNR
        // below 30 dB, which was verified by deliberately breaking the
        // denominator during development.
        #expect((report["s=4"] ?? 0) > 40, "s=4 PSNR \(report["s=4"] ?? 0)")
    }

    private func boxTwice(_ src: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        func box(_ input: [Double]) -> [Double] {
            var horizontal = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    for d in -radius...radius {
                        sum += input[y * width + min(max(x + d, 0), width - 1)]
                    }
                    horizontal[y * width + x] = sum / Double(2 * radius + 1)
                }
            }
            var out = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    for d in -radius...radius {
                        sum += horizontal[min(max(y + d, 0), height - 1) * width + x]
                    }
                    out[y * width + x] = sum / Double(2 * radius + 1)
                }
            }
            return out
        }
        return box(box(src))
    }
}
