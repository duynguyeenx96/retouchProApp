import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.1 — files the hand-painted mask's numbers ("Cọ mask thủ công",
/// docs/PLAN.md §6.1, docs/ADR-0019).
///
/// One `RPBENCH-P6BRUSH ` line of JSON, scraped by `Scripts/bench-manual-mask.sh`
/// into `Research/bench/p6-manual-mask-*.json`, the same arrangement every other
/// node's bench uses: the number filed under `Research/` is always a number a
/// test measured (docs/PLAN.md §5).
///
/// **This bench exists to close ADR-0019's own blocker.** That ADR shipped the
/// brush with `RPEngineFeatureFlags.manualMask` off and said why: *"There is no
/// ms/frame for the brush on an iPhone … a ms/frame on an A-series part is
/// required before it is turned on, the same rule every other node followed."*
/// The correctness numbers it does have (bit-exact splat, 0 unpainted pixels
/// changed) are `ManualMaskTests`; what was missing was speed, and speed is
/// three separate questions:
///
/// * `paint.*` — **main-thread** milliseconds per touch event. This is the one
///   that decides whether the brush feels attached to the finger: `beginStroke`
///   / `extendStroke` are called from the touch handler and encode a batch of
///   stamps, so if a point costs more than a frame the stroke lags no matter how
///   fast the GPU is.
/// * `render.*` — ms/frame of `SkinRenderNode` **with** the painted gate against
///   the same node **without** it, on the same fixture in the same run. The
///   second is the control: the gate's whole cost is one extra
///   `rp_manual_mask_modulate` dispatch over an r8 texture, and the marginal
///   figure is what says so.
/// * `undo.*` — a replay of a 20-stroke history, because undo is defined as a
///   replay rather than a snapshot (ADR-0019 §3) and that choice is only
///   defensible if a replay is cheap.
///
/// Everything is measured at a **2048 px preview**, which is the size the canvas
/// paints at (`LivePreviewController` builds the session at the decoded
/// preview's size) — not at 24 MP, which is export and is not what a finger is
/// dragging over.
@Suite("Phase 6.1 manual mask bench", .serialized)
struct ManualMaskBenchTests {
    /// The preview the canvas actually renders: `RenderQuality.preview`'s long
    /// edge, 3:2 like the a6300's frame.
    static let width = 2048
    static let height = 1365
    /// How many samples a real drag delivers. A finger crossing an iPhone screen
    /// at 120 Hz for a second produces ~120 touch-moved events; the stamper
    /// turns those into many more stamps.
    static let dragPoints = 120
    /// Median of this many runs, as the other node benches do.
    static let renderIterations = 15

    @Test("Files the brush's paint, render and undo milliseconds")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P6BRUSH-SKIP no Metal device")
            return
        }

        var report: [String: Any] = [
            "suite": "Phase 6.1 manual mask brush (Cọ mask thủ công)",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "feature_flag": "RPEngineFeatureFlags.manualMask",
            "preview_pixels": [Self.width, Self.height],
            "drag_points": Self.dragPoints,
            "brush_radius_mask_px": 64,
            "gated_node": "SkinRenderNode",
            "adr": "docs/ADR-0019-manual-mask-brush.md",
            "measures": [
                "paint": "main-thread ms per touch event (beginStroke / extendStroke)",
                "render": "SkinRenderNode ms/frame, with and without the painted gate",
                "undo": "ms to replay a 20-stroke history from the baseline",
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

        try ManualMaskTests.withManualMaskAndSkin {
            report["paint"] = try Self.paintNumbers(context: context)
            report["undo"] = try Self.undoNumbers(context: context)
            report["render"] = try Self.renderNumbers(context: context)
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6BRUSH \(String(decoding: data, as: UTF8.self))")

        // The two bars that decide whether the flag may go on, asserted rather
        // than merely filed. They are deliberately loose — this is a brush, not
        // a 60 Hz render loop, and the bar is "the finger is not waiting".
        let paint = try #require(report["paint"] as? [String: Any])
        let perPoint = try #require(paint["main_thread_ms_per_point"] as? Double)
        #expect(perPoint < 8, "\(perPoint) ms of main thread per touch event")
        let render = try #require(report["render"] as? [String: Any])
        let gated = try #require(render["gated_median_ms"] as? Double)
        #expect(gated < 33, "gated redraw \(gated) ms, i.e. under 30 fps")
    }

    // MARK: - Paint: the main thread, per touch event

    /// A drag across the frame, delivered the way the canvas delivers it: one
    /// `extendStroke` per touch-moved event, each encoding only the stamps that
    /// point added.
    ///
    /// The GPU flush is measured separately and *after* the drag, because
    /// `ManualMaskSession` deliberately does not wait on the command buffer —
    /// blocking the main thread on the GPU is exactly what would put the brush
    /// behind the finger.
    static func paintNumbers(context: MetalContext) throws -> [String: Any] {
        let session = try ManualMaskSession(context: context, width: width, height: height)
        let points = dragPath()

        let start = CFAbsoluteTimeGetCurrent()
        session.beginStroke(
            radius: 64, hardness: 0.5, flow: 1, mode: .add, at: points[0])
        for point in points.dropFirst() { session.extendStroke(to: point) }
        let stroke = session.endStroke()
        let paintMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // Everything the drag queued, drained: a read-back waits on the queue.
        let flushStart = CFAbsoluteTimeGetCurrent()
        _ = try session.readValues()
        let flushMilliseconds = (CFAbsoluteTimeGetCurrent() - flushStart) * 1000

        return [
            "main_thread_ms_total": paintMilliseconds,
            "main_thread_ms_per_point": paintMilliseconds / Double(points.count),
            "gpu_drain_plus_readback_ms": flushMilliseconds,
            "stamps": stroke?.stamps.count ?? 0,
            "mask_bytes": session.coverage.allocatedBytes,
        ]
    }

    // MARK: - Undo: a replay, not a snapshot

    static func undoNumbers(context: MetalContext) throws -> [String: Any] {
        let session = try ManualMaskSession(context: context, width: width, height: height)
        for index in 0..<20 {
            let offset = Double(index) * 12
            session.beginStroke(
                radius: 48, hardness: 0.5, flow: 1, mode: .add,
                at: BrushPoint(location: CGPoint(x: 200 + offset, y: 200 + offset)))
            session.extendStroke(
                to: BrushPoint(location: CGPoint(x: 1600 + offset, y: 1000 + offset)))
            session.endStroke()
        }
        // `undo()` replays every remaining stroke and waits for the GPU, so this
        // is the whole user-visible cost of one undo at the deepest history the
        // session is likely to hold.
        let start = CFAbsoluteTimeGetCurrent()
        _ = session.undo()
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return [
            "history_strokes": 20,
            "replay_ms": milliseconds,
            "strokes_replayed": session.strokeCount,
        ]
    }

    // MARK: - Render: the gate's marginal ms/frame

    /// `SkinRenderNode` at the preview size, with and without one painted gate,
    /// in the same run on the same fixture.
    static func renderNumbers(context: MetalContext) throws -> [String: Any] {
        let node = try SkinRenderNode(context: context)
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 909)
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])

        let face = SkinReference.face(
            imageWidth: width, imageHeight: height, faceWidth: CGFloat(width) * 0.28)
        var state = EditState()
        SkinRenderNodeTests.allSliders.write(into: &state)
        let ungatedRequest = RenderRequest(editState: state, faces: [face], quality: .preview)

        // A wide stroke across the face, so the gate is doing real work rather
        // than modulating a nearly empty texture.
        let session = try ManualMaskSession(context: context, width: width, height: height)
        let path = dragPath()
        session.beginStroke(radius: 120, hardness: 0.5, flow: 1, mode: .add, at: path[0])
        for point in path.dropFirst() { session.extendStroke(to: point) }
        session.endStroke()
        var gatedRequest = ungatedRequest
        gatedRequest.gateMasks = [session.coverage]

        func median(of request: RenderRequest) throws -> Double {
            var samples: [Double] = []
            // One warm-up: the first encode allocates the node's scratch
            // textures and the gate's, which is a per-shot cost, not a
            // per-frame one.
            for iteration in 0...renderIterations {
                guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                    throw MetalContext.Failure.noCommandQueue
                }
                let start = CFAbsoluteTimeGetCurrent()
                try node.encode(
                    into: commandBuffer, source: source, destination: destination,
                    request: request)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                if iteration > 0 { samples.append(elapsed) }
            }
            samples.sort()
            return samples[samples.count / 2]
        }

        let ungated = try median(of: ungatedRequest)
        let gated = try median(of: gatedRequest)
        return [
            "iterations": renderIterations,
            "ungated_median_ms": ungated,
            "gated_median_ms": gated,
            "gate_marginal_ms": gated - ungated,
            "gated_fps": 1000 / max(gated, 0.001),
            "control": "the same node, same fixture, same run, with gateMasks empty",
        ]
    }

    // MARK: - Fixture

    /// A drag that crosses the frame diagonally and curves back, so the stamper
    /// produces a realistic number of stamps rather than a straight line's
    /// minimum.
    static func dragPath() -> [BrushPoint] {
        (0..<dragPoints).map { step in
            let t = Double(step) / Double(dragPoints - 1)
            return BrushPoint(
                location: CGPoint(
                    x: 200 + t * Double(width - 400),
                    y: 250 + sin(t * .pi) * Double(height - 500)),
                pressure: 0.6 + 0.4 * t)
        }
    }
}
