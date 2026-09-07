import CoreGraphics
import Foundation

/// How the canvas gets faces without RPEngine or RPUI learning about Core ML.
///
/// RPEngine does not import RPVision (docs/ADR-0007, and the long note in
/// `App/FaceAnalysisRenderBridge.swift`): `FaceAnalysis` is only reachable
/// through types that pull in the landmark and parsing model wrappers, and a
/// render graph that links Core ML cannot be unit-tested on a machine with no
/// models. RPUI must not import it either, for the same reason plus the layering
/// rule (RPUI → RPEngine → RPCore, never sideways).
///
/// So the app target — the one place that links both packages — implements this
/// protocol on top of `FaceAnalyzer` + `FaceAnalysisRenderBridge`, and RPUI only
/// ever sees `[FaceRenderInput]`, which is a plain value type.
///
/// ### The performance contract is part of the protocol
/// A conformance **must not** run detection on the interaction path. Face
/// analysis costs ~36 ms per image on an M-series Mac (docs/PLAN.md Phase 2,
/// `Research/bench/p2-face-analyzer-macos.json`) and a slider drag issues 30–60
/// redraws a second. `FaceAnalyzer` already caches by content hash — cold
/// 46.7 ms, warm 0.052 ms, and concurrent callers with the same key share one
/// run — so a conformance is expected to key on the shot's content hash and
/// return the cached answer. Nothing above this protocol re-asks per frame
/// either: `LivePreviewController` asks once per shot and keeps the array.
public protocol FaceInputProviding: Sendable {
    /// Faces for an already-decoded preview image, **in that image's pixel
    /// coordinates**, ready to put straight into `RenderRequest.faces`.
    ///
    /// - Parameters:
    ///   - image: the decoded preview the canvas is showing. Passing the decoded
    ///     image rather than a URL is deliberate: the analysis then runs in the
    ///     same pixel grid the graph renders in, so `renderScale` is 1 and there
    ///     is no second decode of a 24 MP file.
    ///   - contentHash: `Shot.contentHash` (RPImport computes it at import).
    ///     The conformance is expected to fold the image's pixel size into its
    ///     own cache key, because the same file analysed at two sizes is two
    ///     different answers.
    ///   - kinds: which masks the enabled slider groups actually need. Feathering
    ///     a mask the render will not read costs 4.1 ms of CPU per group per face
    ///     (docs/PLAN.md Phase 2, `ParsedFace.feathered`).
    func faceInputs(
        for image: PreviewImage, contentHash: String, kinds: Set<RenderMaskKind>
    ) async throws -> [FaceRenderInput]
}

/// The default: no faces, ever.
///
/// Not a failure mode — it is the honest answer when the Core ML models are not
/// present (they are 25 MB and are still not bundled; docs/ADR-0008 and the
/// spikes deliberately left the bundling question open) or when
/// `RPVisionFeatureFlags.faceAnalyzer` is off. With no faces the face-dependent
/// groups (Da / Mặt / Mắt-Răng) have nothing to act on and skip themselves, and
/// the Color group — which never reads a face — still works. That is also
/// exactly the right behaviour for a landscape or product shot.
public struct NoFaceInputProvider: FaceInputProviding {
    public init() {}

    public func faceInputs(
        for image: PreviewImage, contentHash: String, kinds: Set<RenderMaskKind>
    ) async throws -> [FaceRenderInput] {
        []
    }
}

/// Which masks the currently-enabled nodes need, so a provider does not feather
/// masks nothing will read.
///
/// Derived from the nodes themselves rather than hard-coded: `SkinRenderNode`
/// needs `.skin`, `EyesTeethRenderNode` needs `.eyes` and `.mouth`,
/// `WarpRenderNode` needs none (it is landmarks only), and `ColorRenderNode`
/// does not see faces at all.
public enum RenderMaskRequirements {
    /// The union of the mask kinds the enabled slider groups read.
    public static func forEnabledGroups() -> Set<RenderMaskKind> {
        var kinds: Set<RenderMaskKind> = []
        if RPEngineFeatureFlags.skinSliders { kinds.formUnion(SkinRenderNode.maskKinds) }
        if RPEngineFeatureFlags.eyesTeethSliders {
            kinds.formUnion(EyesTeethRenderNode.maskKinds)
        }
        return kinds
    }
}
