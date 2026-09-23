import CoreGraphics
import Foundation
import RPCore
import RPEngine
import RPUI

/// A launch-time brush run against a real photo, written to `session.log` — the
/// "Cọ mask thủ công" sibling of ``FaceSelfTest`` / ``BodySkinSelfTest``
/// (docs/PLAN.md §6.1, docs/ADR-0019).
///
/// ## Why this exists, and why it is not a test
///
/// ADR-0019 shipped the brush with its flag off for one stated reason: *"There
/// is no ms/frame for the brush on an iPhone … a ms/frame on an A-series part is
/// required before it is turned on, the same rule every other node followed."*
/// `ManualMaskBenchTests` answers that on macOS and in the Simulator, but both
/// of those run on the host Mac's GPU, and the package test bundles **cannot**
/// run on a phone — `xcodebuild` refuses tool-hosted testing on a device
/// destination, the same wall `BodySkinSelfTest` documents. So the A-series
/// number has to come from inside the app, which is what this is.
///
/// It drives the **product objects** — `LivePreviewController.open`, then
/// `beginManualMaskStroke` / `extendManualMaskStroke` / `endManualMaskStroke`,
/// i.e. exactly the calls `CanvasView`'s drag handler makes, then
/// `LivePreviewRenderer.render(_:)`, the call the canvas's `MTKView` makes per
/// frame. Nothing is re-implemented here; if the wiring is wrong this reports
/// the wrong number too, which is the point.
///
/// Three numbers, and the third is the one the ADR asked for:
///
/// * `paint_ms_per_point` — main thread per touch event. The brush is attached
///   to the finger or it is not.
/// * `render_ungated_ms` / `render_gated_ms` — the same graph, the same photo,
///   the same run, without and with the painted gate. The first is the control;
///   the difference is the entire cost of gating.
/// * `undo_ms` — one undo at the end of the strokes painted here, because undo
///   is a replay rather than a snapshot (ADR-0019 §3).
///
/// ```
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_BRUSH_SELFTEST":"first-shot"}' \
///   com.duynguyen.RetouchPro
/// ```
///
/// Off unless the variable is set. It paints into a session that is thrown away
/// when the canvas opens its own shot, and it writes no file.
enum ManualMaskSelfTest {
    static let environmentKey = "RP_BRUSH_SELFTEST"

    /// Touch events in the simulated drag — about a second of a finger moving at
    /// 120 Hz.
    static let dragPoints = 120
    /// Frames timed on each side of the comparison.
    static let renderIterations = 15

    /// Same grammar as `RP_FACE_SELFTEST`: `first-shot`, a bare file name, or an
    /// absolute path — the same type, so the self-tests cannot drift into
    /// different ways of naming a photo.
    static func target(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FaceSelfTest.Target? {
        environment[environmentKey].flatMap(FaceSelfTest.Target.init)
    }

    @MainActor
    static func run(
        target: FaceSelfTest.Target,
        renderer: any PreviewRendering,
        live: LivePreviewController?
    ) async {
        let libraryRoot = try? ProjectLibrary.defaultRoot()
        let url: URL
        switch FaceSelfTest.resolve(target, libraryRoot: libraryRoot) {
        case .file(let resolved): url = resolved
        case .failure(let reason):
            AppLog.write("brush selftest: cannot run — \(reason)")
            return
        }
        guard let live else {
            AppLog.write("brush selftest: no live preview on this machine (no Metal device)")
            return
        }
        // Said out loud rather than inferred from a missing line, the same way
        // `BodySkinSelfTest` does: with the flag off there is no session by
        // design, and that must not read as a broken build.
        guard RPEngineFeatureFlags.manualMask else {
            AppLog.write(
                "brush selftest: RPEngineFeatureFlags.manualMask is OFF — no session is built. "
                    + "Launch without RPDisableGroups=manualMask.")
            return
        }

        do {
            let image = try await renderer.renderPreview(
                PreviewRequest(
                    originalURL: url, maxPixelSize: renderer.preferredPreviewPixelSize))
            // Every slider of the one gated group turned up, so the node the
            // gate narrows is actually running. With all sliders at 0 the node
            // is inactive and both sides of the comparison would measure a copy.
            var editState = EditState()
            SkinSliders(
                smooth: 70, keepTexture: 30, evenTone: 45, redness: 55, shine: 60,
                brighten: 35, darkCircle: 50, wrinkle: 40
            ).write(into: &editState)
            await live.open(
                image, contentHash: "brush-selftest-\(url.lastPathComponent)",
                editState: editState)

            guard live.canPaintManualMask else {
                AppLog.write(
                    "brush selftest: \(url.lastPathComponent) — no session was built "
                        + "(preview \(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)))")
                return
            }

            // 1. The control: the graph with no gate, on this photo.
            let ungated = median(iterations: renderIterations) {
                _ = try? live.renderer.render(live.renderRequest)
            }
            let nodes = live.renderer.report.nodes.joined(separator: "→")

            // 2. The drag, through the same calls the canvas's gesture handler
            //    makes, with the same settings the brush bar ships with.
            let settings = ManualMaskBrushSettings()
            let points = dragPath(in: image.pixelSize)
            let paintStart = CFAbsoluteTimeGetCurrent()
            live.beginManualMaskStroke(at: points[0], settings: settings)
            for point in points.dropFirst() { live.extendManualMaskStroke(to: point) }
            live.endManualMaskStroke()
            let paintMilliseconds = (CFAbsoluteTimeGetCurrent() - paintStart) * 1000

            // 3. The same graph again, now with the painted gate in the request.
            let gateCount = live.renderRequest.gateMasks.count
            let gated = median(iterations: renderIterations) {
                _ = try? live.renderer.render(live.renderRequest)
            }

            // 4. One more stroke, then an undo — the replay, at the history
            //    depth a self-test can honestly produce.
            live.beginManualMaskStroke(at: points[0], settings: settings)
            for point in points.dropFirst(60) { live.extendManualMaskStroke(to: point) }
            live.endManualMaskStroke()
            // Undo is the document handing the canvas the list minus its last
            // stroke (docs/ADR-0025) — the same replay `EditorModel.undo` drives.
            let undoStart = CFAbsoluteTimeGetCurrent()
            live.setManualMaskStrokes(Array(live.manualMaskDocument.dropLast()))
            let undoMilliseconds = (CFAbsoluteTimeGetCurrent() - undoStart) * 1000

            AppLog.write(
                "brush selftest: \(url.lastPathComponent) "
                    + "\(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) — "
                    + "paint " + String(format: "%.2f", paintMilliseconds) + " ms for "
                    + "\(points.count) points ("
                    + String(format: "%.3f", paintMilliseconds / Double(points.count))
                    + " ms/point), render ungated "
                    + String(format: "%.2f", ungated) + " ms, gated "
                    + String(format: "%.2f", gated) + " ms (marginal "
                    + String(format: "%.2f", gated - ungated) + " ms, "
                    + String(format: "%.0f", 1000 / max(gated, 0.001)) + " fps), undo "
                    + String(format: "%.1f", undoMilliseconds) + " ms, gates \(gateCount), "
                    + "strokes \(live.manualMaskStrokeCount), nodes \(nodes.isEmpty ? "none" : nodes)")

            // The mask this self-test painted must not be what the user sees
            // when the canvas opens their first shot.
            live.setManualMaskStrokes([])
        } catch {
            AppLog.write("brush selftest: FAILED on \(url.lastPathComponent): \(error)")
        }
    }

    /// Median wall-clock milliseconds of `body`, with one warm-up run that is
    /// thrown away (the first render allocates the node's scratch textures and
    /// the gate's, which is a per-shot cost, not a per-frame one).
    private static func median(iterations: Int, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        return samples.isEmpty ? 0 : samples[samples.count / 2]
    }

    /// A drag across the picture, in **mask pixels** — the space the paint API
    /// takes, and the space `CanvasView` converts a touch into.
    static func dragPath(in size: CGSize) -> [CGPoint] {
        let width = Double(size.width)
        let height = Double(size.height)
        return (0..<dragPoints).map { step in
            let t = Double(step) / Double(dragPoints - 1)
            return CGPoint(
                x: width * 0.12 + t * width * 0.76,
                y: height * 0.2 + sin(t * .pi) * height * 0.6)
        }
    }
}
