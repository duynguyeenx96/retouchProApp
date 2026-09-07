import CoreGraphics
import Foundation
import RPEngine
import RPVision

/// Turns RPVision's `FaceAnalysis` into RPEngine's `FaceRenderInput`.
///
/// ## Why this lives in the app target and not in a package
///
/// `RPEngine` does not import `RPVision`. `docs/ADR-0007` fixed that seam when
/// spike S3 landed — "Phase 2's `RenderGraph` will need … a plain value type
/// between `FaceAnalysis` and the warp" — and the reason is not the layering
/// audit (which does not actually forbid the edge; see the note below) but Core
/// ML: `FaceAnalysis` is reachable only through types that pull in the parsing
/// and landmark model wrappers, and a render graph that links Core ML cannot be
/// unit-tested on a machine with no models, which is exactly how
/// `RPEngineTests` runs today.
///
/// The app target already links both packages (`AppContainer`), so the
/// conversion belongs here. It is a pure function over value types with no state
/// and no GPU work.
///
/// **Note on ADR-0007.** That ADR states "`RPTestKitTests/LayeringAuditTests`
/// forbids `RPEngine` from importing `RPVision`". As written, the audit's rule
/// table only forbids `RPEngine` → `RPUI` / `RPImport`
/// (`Packages/RPTestKit/Tests/RPTestKitTests/LayeringAuditTests.swift:61-71`),
/// so the edge is permitted by the test and refused by choice. The choice is
/// still the right one for the reason above; the ADR's justification is not.
enum FaceAnalysisRenderBridge {

    /// The mask groups the Phase 2 render nodes can use.
    ///
    /// `teeth` is absent because CelebAMask-HQ has no teeth class — the whiten
    /// teeth slider derives it from luminance inside `mouth`
    /// (`ParsedFace`'s doc comment, spike S2 §3c). `RenderMaskKind` has no
    /// `teeth` case either, so this cannot be forgotten.
    ///
    /// A caller feeding a particular node should pass that node's own list
    /// rather than a hand-written one — `EyesTeethRenderNode.maskKinds` is
    /// `[.eyes, .mouth]`, and `FaceAnalysisRenderBridgeTests` checks the bridge
    /// can feather exactly those.
    static let groups: [(FaceParsingGroup, RenderMaskKind)] = [
        (.skin, .skin), (.hair, .hair), (.eyes, .eyes), (.brows, .brows),
        (.lips, .lips), (.mouth, .mouth), (.neck, .neck), (.nose, .nose),
        (.eyeglasses, .eyeglasses), (.ears, .ears),
    ]

    /// Converts every analysed face, optionally scaling into the coordinates of a
    /// render that is smaller than the analysed image.
    ///
    /// - Parameter renderScale: `renderedLongEdge / analysedLongEdge`. A preview
    ///   renders at 2048 px while `FaceAnalyzer` ran on the full frame, so this
    ///   is not usually 1. `RenderRequest.faces` is documented as already scaled
    ///   for exactly this reason.
    static func renderInputs(
        from analysis: FaceAnalysis,
        renderScale: CGFloat = 1,
        kinds: Set<RenderMaskKind> = [.skin]
    ) -> [FaceRenderInput] {
        analysis.faces.map { face in
            var masks: [RenderMaskKind: RenderMask] = [:]
            if let parsing = face.parsing {
                for (group, kind) in groups where kinds.contains(kind) {
                    masks[kind] = RenderMask(
                        width: parsing.mask.width,
                        height: parsing.mask.height,
                        // Always feathered, never `hardMask`. Spike S2 §4 measured
                        // eye IoU at 0.84 and proved it is the checkpoint's ceiling
                        // (a ~1 px boundary error on a ~15 px object); the same
                        // ±1 px edge is why even the skin mask gets a ramp rather
                        // than a staircase from the 512 → full-res upsample.
                        values: parsing.feathered(group),
                        maskToImage: parsing.region.outputToImage)
                }
            }
            return FaceRenderInput(
                landmarks: face.imagePoints, faceWidth: face.faceWidth, masks: masks)
        }
        .map { renderScale == 1 ? $0 : $0.scaled(by: renderScale) }
    }

    /// `renderScale` for a render whose long edge is `renderedLongEdge`, given the
    /// image `analysis` was computed on.
    static func renderScale(for analysis: FaceAnalysis, renderedLongEdge: Int) -> CGFloat {
        let analysed = max(analysis.imageSize.width, analysis.imageSize.height)
        guard analysed > 0 else { return 1 }
        return CGFloat(renderedLongEdge) / analysed
    }
}
