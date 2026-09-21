import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6 — files the canvas histogram's numbers (docs/ADR-0024).
///
/// One `RPBENCH-P6HIST ` line of JSON, scraped by `Scripts/bench-histogram.sh`
/// into `Research/bench/p6-histogram-*.json`: the number filed under
/// `Research/` is always a number a test measured (docs/PLAN.md §5).
///
/// Three questions, and the throttling decision in ADR-0024 rests on all three:
///
/// * `pass` — the histogram dispatch on its own, GPU-timed
///   (`waitUntilCompleted` around a command buffer that does nothing else) at
///   the 2048 px preview the canvas renders. This is the cost the GPU pays.
/// * `drag` — 60 back-to-back redraws of the real `LivePreviewRenderer` with a
///   changing slider value, **with** and **without** the histogram sample
///   attached, in the same run on the same fixture. The version without is the
///   control; the difference is what a live histogram actually costs a drag.
/// * `stall` — main-thread milliseconds per redraw spent *encoding* the
///   histogram, i.e. the part that is not hidden by the GPU. The whole claim
///   of `HistogramSampler` is that this is not a readback, so this number is
///   the one that proves it — compared against
///   `LivePreviewRenderer.readOutputPixels()`, the stalling path the sampler
///   exists to avoid, measured here as the control.
@Suite("Phase 6 histogram bench", .serialized)
struct HistogramBenchTests {
    /// The size the canvas renders at: `RenderQuality.preview`'s long edge,
    /// 3:2 like the a6300's frame.
    static let width = 2048
    static let height = 1365
    /// A real drag's worth of redraws, matching `LivePreviewBenchTests`.
    static let dragFrames = 60
    static let iterations = 30

    @Test("Files the histogram pass, drag and stall milliseconds")
    func measure() throws {
        // The strict guard, not the usual `else { return }`: a library that
        // failed to compile must not file a green "skipped" result. See
        // `HistogramTests.requireContext()`.
        guard let context = try HistogramTests.requireContext() else {
            print("RPBENCH-P6HIST-SKIP no Metal device")
            return
        }

        var report: [String: Any] = [
            "suite": "Phase 6 canvas histogram (biểu đồ màu)",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "preview_pixels": [Self.width, Self.height],
            "bins": ImageHistogram.binCount,
            "channels": ImageHistogram.channelCount,
            "threadgroup_edge": HistogramSampler.threadgroupEdge,
            "binning": "encoded sRGB code value, min(floor(v * 256), 255), clamped to [0,1]",
            "adr": "docs/ADR-0024-canvas-histogram.md",
            "measures": [
                "pass": "ms for the clear + accumulate dispatch alone, GPU-timed",
                "drag": "ms/redraw over 60 redraws, with and without a histogram sample",
                "stall": "main-thread ms/redraw to encode+commit, vs the stalling readback",
            ],
        ]
        #if targetEnvironment(simulator)
            report["environment"] = "iOS Simulator (executes on the host Mac's GPU)"
            report["is_real_device"] = false
        #elseif os(iOS)
            report["environment"] = "iOS device"
            report["is_real_device"] = true
        #else
            report["environment"] = "macOS host"
            report["is_real_device"] = true
        #endif

        report["pass"] = try Self.passNumbers(context: context)
        let drag = try Self.dragNumbers(context: context)
        report["drag"] = drag
        report["stall"] = try Self.stallNumbers(context: context)

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6HIST \(String(decoding: data, as: UTF8.self))")

        // The bar the throttling decision rests on: a histogram per redraw must
        // not push the interactive loop below the 30 fps `docs/PLAN.md` §1.4
        // demands of the *lowest* tier. Asserted, not merely filed.
        let withHistogram = try #require(drag["with_histogram_ms_per_frame"] as? Double)
        #expect(withHistogram < 33, "\(withHistogram) ms/redraw with the histogram attached")
    }

    // MARK: - 1. The pass on its own

    static func passNumbers(context: MetalContext) throws -> [String: Any] {
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 31)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let sampler = try HistogramSampler(context: context)

        func median(step: Int) throws -> Double {
            var samples: [Double] = []
            for iteration in 0...iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try sampler.sampleSynchronously(texture: texture, step: step)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                if iteration > 0 { samples.append(elapsed) }
            }
            samples.sort()
            return samples[samples.count / 2]
        }

        let full = try median(step: 1)
        let quarter = try median(step: 2)
        return [
            "iterations": iterations,
            "every_pixel_median_ms": full,
            "every_pixel_fps": 1000 / max(full, 0.0001),
            "stride_2_median_ms": quarter,
            "pixels": width * height,
            "note":
                "includes the commit + waitUntilCompleted round trip, so it is an upper bound on the GPU time",
        ]
    }

    // MARK: - 2. A drag, with and without

    /// The real interaction path: `LivePreviewRenderer` over an uploaded shot,
    /// one redraw per slider value, exactly as `LivePreviewBenchTests` does it —
    /// then the same loop again with a non-blocking histogram sample attached to
    /// each redraw.
    static func dragNumbers(context: MetalContext) throws -> [String: Any] {
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let renderer = try LivePreviewRenderer(context: context)
        try renderer.prewarm()
        try renderer.setSource(
            LivePreviewFixture.sRGBImage(width: width, height: height, seed: 77))
        let sampler = try HistogramSampler(context: context)

        func request(_ value: Double) -> RenderRequest {
            var state = EditState()
            ColorSliders(exposure: value, contrast: value / 2).write(into: &state)
            return RenderRequest(editState: state, allFaces: [], quality: .preview)
        }

        func drag(withHistogram: Bool) throws -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for frame in 0..<dragFrames {
                try renderer.render(request(Double(10 + frame % 40)))
                guard withHistogram, let output = renderer.outputTexture else { continue }
                // Exactly what the canvas does: issue and move on. `.busy` is a
                // legitimate answer and the caller simply skips that frame.
                do {
                    try sampler.sample(texture: output) { _ in }
                } catch HistogramSampler.Failure.busy {
                } catch {
                    throw error
                }
            }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(dragFrames)
        }

        // One warm-up drag: the first render allocates the output texture and
        // the node's scratch, which is a per-shot cost.
        _ = try drag(withHistogram: false)
        let without = try drag(withHistogram: false)
        let with = try drag(withHistogram: true)
        return [
            "frames": dragFrames,
            "without_histogram_ms_per_frame": without,
            "with_histogram_ms_per_frame": with,
            "marginal_ms_per_frame": with - without,
            "with_histogram_fps": 1000 / max(with, 0.0001),
            "control": "the same renderer, same fixture, same run, no histogram sample issued",
            "node": "ColorRenderNode (exposure + contrast), the group that needs no face",
        ]
    }

    // MARK: - 3. What the main thread actually pays

    /// `HistogramSampler.sample` against `LivePreviewRenderer.readOutputPixels()`
    /// — the CPU readback whose own doc comment says "test / bench only, it
    /// stalls the GPU". Measuring both on the same texture in the same run is
    /// what turns "we avoided the stalling path" from a claim into a ratio.
    static func stallNumbers(context: MetalContext) throws -> [String: Any] {
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let renderer = try LivePreviewRenderer(context: context)
        try renderer.prewarm()
        try renderer.setSource(
            LivePreviewFixture.sRGBImage(width: width, height: height, seed: 78))
        var state = EditState()
        ColorSliders(exposure: 30).write(into: &state)
        try renderer.render(RenderRequest(editState: state, allFaces: [], quality: .preview))
        let output = try #require(renderer.outputTexture)
        let sampler = try HistogramSampler(context: context)

        var encodeSamples: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try sampler.sample(texture: output) { _ in }
            } catch HistogramSampler.Failure.busy {}
            encodeSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        encodeSamples.sort()

        var readbackSamples: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try renderer.readOutputPixels()
            readbackSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        readbackSamples.sort()

        let encode = encodeSamples[encodeSamples.count / 2]
        let readback = readbackSamples[readbackSamples.count / 2]
        return [
            "encode_and_commit_median_ms": encode,
            "stalling_readback_median_ms": readback,
            "speedup_vs_readback": readback / max(encode, 0.0001),
            "readback_bytes": width * height * 8,
            "histogram_bytes": ImageHistogram.binCount * ImageHistogram.channelCount * 4,
            "control": "LivePreviewRenderer.readOutputPixels(), the documented stalling path",
        ]
    }
}
