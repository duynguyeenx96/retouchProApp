import CoreGraphics
import Foundation

/// How hard the provider should work on the subject mask.
///
/// Mirrors `VNGeneratePersonSegmentationRequest.QualityLevel` (and RPVision's
/// `PersonSegmentationQuality`) by name, so the adapter is a `switch` with no
/// arithmetic in it — the same trick `RenderMaskKind` plays for
/// `FaceParsingGroup`. RPEngine does not import Vision for the same reason it
/// does not import RPVision (docs/ADR-0009): the seam is a plain value type and
/// the framework stays on the other side of it.
///
/// **No default is declared here.**
/// `Research/bench/p6-background-lock-macos.json` holds the macOS ms/request for
/// all three (the Simulator cannot run the request at all, and files that fact
/// instead); which one the UI picks is docs/PLAN.md §6.1's follow-up decision,
/// once there is an iPhone number.
public enum SubjectMaskQuality: String, Sendable, Codable, CaseIterable {
    case fast, balanced, accurate
}

/// How the render side gets a whole-frame subject (foreground) mask without
/// RPEngine learning about Vision.
///
/// The shape is deliberately the same as ``FaceInputProviding``: the app target
/// is the one place that links both packages, so it implements this on top of
/// RPVision's `PersonSegmenter` and everything above only ever sees a
/// ``RenderMask``.
///
/// ### What it is for
/// "Khoá nền" (docs/PLAN.md §6.1): keep an effect from leaking onto the
/// background. A consumer multiplies its per-pixel amount by this coverage, so
/// 1 = subject (effect applies) and 0 = background (locked).
///
/// ### The performance contract is part of the protocol
/// Same rule as ``FaceInputProviding``, and for a larger number: person
/// segmentation costs tens of milliseconds per frame (see the bench file), and a
/// slider drag issues 30–60 redraws a second. A conformance must key on the
/// shot's content hash **and** the pixel size **and** the quality level, and
/// return a cached mask. Nothing above this protocol re-asks per frame.
///
/// ### Why `RenderMask` and not a new type
/// A person mask is bytes + size + a mask→image affine, which is exactly
/// ``RenderMask``, and reusing it means the existing `MaskRasteriser` upload path
/// works unchanged. What it is *not* is a ``RenderMaskKind``: this mask belongs
/// to the frame, not to a face, so it is not carried in `FaceRenderInput.masks`
/// and there is no new case in that enum (which mirrors the parsing classes and
/// would then promise a class BiSeNet cannot produce).
public protocol SubjectMaskProviding: Sendable {
    /// The subject mask for an already-decoded preview image, **in that image's
    /// pixel coordinates**, or `nil` when the frame has no subject.
    ///
    /// - Parameters:
    ///   - image: the decoded preview the canvas is showing, for the same reason
    ///     ``FaceInputProviding`` takes one — the mask then lives in the grid the
    ///     graph renders in, and there is no second decode of a 24 MP file.
    ///   - contentHash: `Shot.contentHash`, the cache key's first component.
    ///   - quality: which quality level to ask for; part of the cache key too,
    ///     because the same file at two quality levels is two different answers.
    /// - Returns: `nil` means "no subject found", which is a legitimate answer
    ///   for a landscape or a product shot, not a failure. A caller must treat it
    ///   as "there is nothing to lock the background against" and leave the
    ///   effect ungated rather than gating everything to zero.
    func subjectMask(
        for image: PreviewImage, contentHash: String, quality: SubjectMaskQuality
    ) async throws -> RenderMask?
}

/// The default: no subject mask, ever.
///
/// Not a failure mode — it is the honest answer while
/// `RPEngineFeatureFlags.backgroundLock` is off (the shipping default) and while
/// no UI asks for one. With no mask, every node behaves exactly as it does today
/// and the picture is unchanged, which is what "the rail control stays locked"
/// has to mean in the engine as well as in the UI.
public struct NoSubjectMaskProvider: SubjectMaskProviding {
    public init() {}

    public func subjectMask(
        for image: PreviewImage, contentHash: String, quality: SubjectMaskQuality
    ) async throws -> RenderMask? {
        nil
    }
}
