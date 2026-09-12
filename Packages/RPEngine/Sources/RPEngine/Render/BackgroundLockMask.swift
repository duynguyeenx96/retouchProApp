import CoreGraphics
import Foundation
import Metal

/// Turns a whole-frame subject mask (``SubjectMaskProviding``) into the
/// full-resolution `r8Unorm` coverage texture a node multiplies its amount by —
/// docs/PLAN.md §6.1, "Khoá nền" (background lock).
///
/// ## What this is, and what it is not
/// It is **one mask source**, not a render stage. There is no new kernel here and
/// no entry in `RenderGraph`: the rasterisation is the same `rp_skin_mask`
/// dispatch that has rasterised the face parsing masks since docs/ADR-0009, and
/// the only new thing is where the mask comes from — a whole-frame
/// `VNGeneratePersonSegmentationRequest` instead of a per-face BiSeNet crop. That
/// is deliberate: it proves the "a mask that belongs to no face can gate a node"
/// path with the existing, measured machinery, which is the path the manual mask
/// brush needs as well.
///
/// ## What is not wired yet
/// Nothing consumes the texture yet. There is no `EditState` field, no slider, no
/// `RenderRequest` member and no UI toggle — the rail's "Khoá nền" control stays
/// locked. Wiring the texture into a node's dispatch is a follow-up, and it has
/// to be coordinated with the manual mask brush, because both want the *same*
/// whole-frame mask slot on `RenderRequest` rather than one each.
///
/// ## Cost
/// One `r8Unorm` full-resolution texture (24 MB at 24 MP) plus the uploaded
/// source mask (Vision returns a few hundred kilobytes at most), and one dispatch
/// per encode. The upload only happens when the mask itself changes, so a slider
/// drag re-dispatches but does not re-upload.
///
/// There is deliberately **no separate bench file for this half**: the dispatch is
/// the `rp_skin_mask` pass already inside every `SkinRenderNode` frame, so its
/// cost is inside the skin node's measured ms/frame
/// (`Research/bench/p2-skin-*.json`) and measuring it again in isolation would
/// file a second number for the same work. The expensive half is the Vision
/// request that produces the mask, and that one *is* measured on its own:
/// `Research/bench/p6-background-lock-macos.json` and
/// `…-ios-simulator.json` — tens of milliseconds per request, which is why it is
/// a once-per-shot cost and not a per-frame one.
public final class BackgroundLockMaskSource: @unchecked Sendable {
    private let rasteriser: MaskRasteriser

    /// - Throws: ``RPEngineFeatureDisabled`` when
    ///   `RPEngineFeatureFlags.backgroundLock` is off, which is the shipping
    ///   default. Refusing at construction rather than at encode time matches
    ///   every other flagged path in this package (`GuidedFilter`, `MLSMeshWarp`,
    ///   the four slider nodes).
    public init(context: MetalContext) throws {
        guard RPEngineFeatureFlags.backgroundLock else {
            throw RPEngineFeatureDisabled(feature: "backgroundLock")
        }
        self.rasteriser = try MaskRasteriser(wholeFrame: context)
    }

    /// Bytes of GPU memory held for the current size.
    public var allocatedBytes: Int { rasteriser.allocatedBytes }

    /// The texture the most recent ``encode(into:mask:width:height:)`` wrote, or
    /// `nil` before the first one.
    public var coverage: (any MTLTexture)? { rasteriser.output }

    /// Drops the cached textures. Called when the document closes or the canvas
    /// size changes for good, not between frames.
    public func releaseIntermediates() { rasteriser.releaseIntermediates() }

    /// Encodes the rasterisation of `mask` into `commandBuffer`.
    ///
    /// - Parameter mask: the subject mask **already scaled** to the texture being
    ///   rendered — `RenderMask.scaled(by:)` does that, and a preview at 2048 px
    ///   is not the size the segmentation ran on. Same contract as
    ///   `RenderRequest.faces`, and for the same reason: inferring a scale from an
    ///   aspect ratio is how a mask ends up half a frame out of place.
    /// - Returns: a full-resolution coverage texture where 1 = subject and
    ///   0 = background, or `nil` when `mask` is `nil` — in which case nothing is
    ///   allocated and nothing is dispatched. A caller must read `nil` as "no
    ///   subject was found, so nothing is locked" and leave its effect ungated,
    ///   **not** as an all-zero mask: gating everything to zero would silently
    ///   turn off a slider the user had set.
    @discardableResult
    public func encode(
        into commandBuffer: any MTLCommandBuffer, mask: RenderMask?, width: Int, height: Int
    ) throws -> (any MTLTexture)? {
        guard let mask else { return nil }
        return try rasteriser.encode(
            into: commandBuffer, masks: [mask], width: width, height: height)
    }
}
