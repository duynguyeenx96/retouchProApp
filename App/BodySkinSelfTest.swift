import Foundation
import RPCore
import RPEngine
import RPUI

/// A launch-time whole-body skin-mask run against a real photo, written to
/// `session.log` — the "Sửa da" half of what ``FaceSelfTest`` does for faces
/// (docs/ADR-0021 §v2).
///
/// ## Why this exists
/// The same reason as `FaceSelfTest`, and it applies here more sharply: this
/// path runs a `VNGeneratePersonSegmentationRequest`, and that request **cannot
/// be performed on the iOS Simulator at all**
/// (`Research/bench/p6-background-lock-ios-simulator.json`). So a Simulator run
/// can only ever show the failure branch, and the only place the intersection
/// actually happens on iOS is a real device — which the package test bundles
/// cannot reach (`xcodebuild` refuses tool-hosted testing on a device
/// destination).
///
/// It drives the **product objects**: `LivePreviewController.open`, i.e. exactly
/// what opening a shot on the canvas does, and then reports what the controller
/// ended up holding. Nothing is duplicated here — if the wiring is wrong, this
/// reports the wrong thing too, which is the point.
///
/// ```
/// xcrun devicectl device process launch --console --device <udid> \
///   --environment-variables '{"RP_ENABLE_EXPERIMENTS":"bodySkinSync","RP_BODYSKIN_SELFTEST":"DSC05259.jpg"}' \
///   com.duynguyen.RetouchPro
/// ```
///
/// Off unless the variable is set, and it only reads.
enum BodySkinSelfTest {
    static let environmentKey = "RP_BODYSKIN_SELFTEST"

    /// Same grammar as `RP_FACE_SELFTEST`: `first-shot`, a bare file name, or an
    /// absolute path. Deliberately the same type, so the two self-tests cannot
    /// drift into two different ways of naming a photo.
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
            AppLog.write("body-skin selftest: cannot run — \(reason)")
            return
        }
        guard let live else {
            AppLog.write("body-skin selftest: no live preview on this machine (no Metal device)")
            return
        }
        // Said out loud rather than inferred from a missing line: with the flag
        // off the controller does nothing at all, by design, and that must not
        // read as a broken build.
        guard RPEngineFeatureFlags.bodySkinSync else {
            AppLog.write(
                "body-skin selftest: RPEngineFeatureFlags.bodySkinSync is OFF (the shipping "
                    + "default) — nothing is computed. Launch with RP_ENABLE_EXPERIMENTS=bodySkinSync.")
            return
        }

        do {
            let image = try await renderer.renderPreview(
                PreviewRequest(
                    originalURL: url, maxPixelSize: renderer.preferredPreviewPixelSize))
            let started = ContinuousClock.now
            await live.open(
                image, contentHash: "bodyskin-selftest-\(url.lastPathComponent)",
                editState: EditState())
            // Whole seconds included — see
            // `PersonSegmenterSubjectMaskProvider.milliseconds(since:)` for why
            // that has to be said.
            let ms = PersonSegmenterSubjectMaskProvider.milliseconds(since: started)
            if let mask = live.bodySkinMask {
                // The v1 control, on the same photo: coverage with no subject
                // mask at all. Without it a low coverage figure is unreadable —
                // "the subject mask trimmed the background" and "the subject
                // mask is misaligned and ate the skin" produce the same single
                // number, and that is precisely the failure this path can have
                // (docs/ADR-0021 §v2, the resampling).
                let control = try? BodySkinMask.make(image: image.cgImage)
                // The alignment check, and the reason it is worth a line in the
                // log: a subject mask that is flipped, transposed or scaled
                // wrong produces a *lower* coverage figure, exactly like a
                // subject mask that is doing its job. These two numbers tell
                // them apart — the face is unambiguously skin and unambiguously
                // inside the subject, so if the v2 coverage collapses inside the
                // detected face box while the control's does not, the mask is
                // in the wrong place. Mirrors what
                // `PersonSegmentationMask.meanCoverage(inImageRect:)` does in
                // RPVision's own tests.
                var alignment = ""
                if let box = live.faceBox(0) {
                    let after = meanCoverage(of: mask, inImageRect: box)
                    let before = control.map { meanCoverage(of: $0.mask, inImageRect: box) } ?? 0
                    alignment = String(
                        format: ", in the face box: %.3f (no subject mask: %.3f)", after, before)
                }
                AppLog.write(
                    "body-skin selftest: \(url.lastPathComponent) "
                        + "\(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) — mask "
                        + "\(mask.width)x\(mask.height), coverage "
                        + String(format: "%.3f", live.bodySkinCoverageFraction ?? 0)
                        + " (no subject mask: "
                        + String(format: "%.3f", control?.coverageFraction ?? 0) + ")"
                        + ", subject mask \(live.bodySkinUsedSubjectMask ? "APPLIED" : "absent")"
                        + alignment
                        + ", open took " + String(format: "%.1f ms", ms))
            } else {
                AppLog.write(
                    "body-skin selftest: \(url.lastPathComponent) — NO MASK produced "
                        + "(open took " + String(format: "%.1f ms", ms)
                        + "); see the person-segmentation line above for why")
            }
        } catch {
            AppLog.write("body-skin selftest: FAILED on \(url.lastPathComponent): \(error)")
        }
    }

    /// Mean coverage (0…1) of a ``RenderMask`` over a rectangle **in image
    /// pixels**, nearest-neighbour at the mask's own resolution. Diagnostic
    /// only — rendering goes through the GPU rasteriser.
    private static func meanCoverage(of mask: RenderMask, inImageRect rect: CGRect) -> Double {
        let toMask = mask.imageToMask
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { $0.applying(toMask) }
        let minX = max(0, Int((corners.map(\.x).min() ?? 0).rounded(.down)))
        let maxX = min(mask.width - 1, Int((corners.map(\.x).max() ?? 0).rounded(.up)))
        let minY = max(0, Int((corners.map(\.y).min() ?? 0).rounded(.down)))
        let maxY = min(mask.height - 1, Int((corners.map(\.y).max() ?? 0).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return 0 }
        var total = 0.0
        var count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                total += Double(mask.values[y * mask.width + x])
                count += 1
            }
        }
        return count == 0 ? 0 : total / (255 * Double(count))
    }
}
