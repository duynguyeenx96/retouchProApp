import CoreGraphics
import Foundation
import Metal
import RPCore

/// The whole-frame masks the canvas renders with, carried into an export.
///
/// ## Why this exists
///
/// Until 2026-09-23 ``ExportJob`` carried faces and nothing else, so everything
/// the canvas narrows or widens with a **whole-frame** mask rendered on screen
/// and not in the file. `LivePreviewController.renderRequest` assembles exactly
/// three of them, and this type carries exactly those three:
///
/// | canvas field                | request slot                | read by                    |
/// |-----------------------------|-----------------------------|----------------------------|
/// | `manualMask` (brush)        | `gateMasks` (appended last) | every gated node           |
///
/// ## The brush travels as strokes, not pixels (2026-09-23)
///
/// ``brushStrokes`` is the shot's stroke list as the project stores it
/// (`RPCore.ManualMaskStroke`, normalised to the frame), and the renderer
/// **rasterises it at the render's own resolution** — the same splat kernel the
/// canvas paints with, at 6000×4000 instead of 2048×1365. An earlier version of
/// this type carried the preview-sized coverage and let the export upsample it,
/// which softened every brush edge by the preview-to-export ratio (~3× at
/// 24 MP). The subject and body masks below are still preview-sized rasters,
/// because they *are* derived rasters (Vision / a classifier) with no finer
/// form to redraw from.
/// | `subjectMask` → gate        | `gateMasks` ("Khoá nền")    | every gated node           |
/// | `bodySkinMask`              | `bodySkinMask`              | ``SkinRenderNode``         |
///
/// ## Coordinates — the same discipline as `faces` + `faceReferenceSize`
///
/// Every *raster* mask here (subject, body) is a ``RenderMask`` whose `maskToImage` maps into an image
/// of ``referenceSize`` pixels — normally the 2048 px preview the canvas
/// decoded, because that is where all three were built. The renderer maps them
/// onto whatever it actually renders at with ``scaled(to:)``; the caller never
/// has to know that size, and nothing guesses it. A mask without a reference
/// size is refused (``ExportMaskError/missingReferenceSize``) rather than being
/// assumed to be at render resolution: a brush mask painted on a 2048 px preview
/// and read as if it were 6000 px wide lands in the top-left third of the frame,
/// silently.
///
/// Unlike faces the scale is **per axis**. These masks cover the *whole frame*
/// by construction, and the preview is the full frame resampled to rounded
/// dimensions (6000×4000 → 2048×1365, so x is ×2.9297 and y ×2.9304); mapping
/// each axis by its own ratio puts the mask's bottom row on the image's bottom
/// row rather than a third of a preview pixel off. A reference whose aspect
/// ratio does not match the render (more than one preview pixel of drift) is a
/// different picture — a rotated decode, the wrong file — and is refused
/// (``ExportMaskError/aspectMismatch``) rather than stretched.
///
/// ## Feature flags and the document's switches are still read at render time
///
/// Carrying a mask is not the same as applying it. ``ExportRenderer`` passes
/// the brush through only while `RPEngineFeatureFlags.manualMask` is on, the
/// subject gate only through ``BackgroundLock/gateMasks(for:subjectGate:)`` and
/// the body mask only through ``BodySkinSync/mask(for:bodySkinMask:)`` — the
/// exact calls the canvas makes — so the file and the canvas agree on *whether*
/// a mask applies as well as on its pixels.
public struct ExportMasks: Sendable, Equatable {
    /// Pixel size of the image the raster masks' `maskToImage` maps into.
    /// Irrelevant to ``brushStrokes``, which are normalised to the frame.
    public var referenceSize: CGSize
    /// The shot's hand-painted strokes (docs/ADR-0019), oldest first, or empty
    /// when nothing is painted. **Empty means no gate, never an all-zero
    /// gate**: an empty gate would switch every mask-driven slider off
    /// (ADR-0019 §5). A non-empty list that erased everything is still a gate —
    /// the canvas treats it the same way (`ManualMaskSession.isEmpty` is about
    /// strokes, not pixels).
    public var brushStrokes: [ManualMaskStroke]
    /// The person-segmentation mask (docs/ADR-0018), or `nil` when no person was
    /// found or nothing asked for one.
    public var subjectMask: RenderMask?
    /// Whole-frame skin coverage (docs/ADR-0021), or `nil`.
    public var bodySkinMask: RenderMask?

    public init(
        referenceSize: CGSize,
        brushStrokes: [ManualMaskStroke] = [],
        subjectMask: RenderMask? = nil,
        bodySkinMask: RenderMask? = nil
    ) {
        self.referenceSize = referenceSize
        self.brushStrokes = brushStrokes
        self.subjectMask = subjectMask
        self.bodySkinMask = bodySkinMask
    }

    /// No masks at all — the pre-2026-09-23 export.
    public static let none = ExportMasks(referenceSize: .zero)

    public var isEmpty: Bool { brushStrokes.isEmpty && !hasRasterMasks }

    /// `true` when a mask needs ``referenceSize`` to be placed.
    public var hasRasterMasks: Bool { subjectMask != nil || bodySkinMask != nil }

    /// Tolerance of the aspect check, in **reference** pixels: rounding a
    /// 6000×4000 frame to a 2048 px preview moves an edge by at most half a
    /// pixel, so one full pixel is generous for a genuine match and still far
    /// below any real mismatch (a 90° rotation is thousands).
    public static let aspectTolerancePixels: CGFloat = 1

    /// The same masks against an image of `renderSize` pixels.
    ///
    /// Only the transforms move — the coverage bytes are not resampled, for the
    /// reason ``RenderMask/scaled(by:)`` gives: the sampling happens once, on
    /// the GPU, with the bilinear filter every mask consumer already uses.
    ///
    /// ``brushStrokes`` pass through untouched — they are normalised, so they
    /// need no transform and no reference size.
    public func scaled(to renderSize: CGSize) throws -> ExportMasks {
        guard hasRasterMasks else { return self }
        guard referenceSize.width > 0, referenceSize.height > 0 else {
            throw ExportMaskError.missingReferenceSize
        }
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw ExportMaskError.missingReferenceSize
        }
        let sx = renderSize.width / referenceSize.width
        let sy = renderSize.height / referenceSize.height
        // Where the reference's height would land if the aspect ratios agreed,
        // compared in reference pixels.
        let expectedHeight = renderSize.height / sx
        guard abs(expectedHeight - referenceSize.height) <= Self.aspectTolerancePixels else {
            throw ExportMaskError.aspectMismatch(reference: referenceSize, render: renderSize)
        }
        let transform = CGAffineTransform(scaleX: sx, y: sy)
        func map(_ mask: RenderMask?) -> RenderMask? {
            mask.map {
                RenderMask(
                    width: $0.width, height: $0.height, values: $0.values,
                    maskToImage: $0.maskToImage.concatenating(transform))
            }
        }
        return ExportMasks(
            referenceSize: renderSize,
            brushStrokes: brushStrokes,
            subjectMask: map(subjectMask),
            bodySkinMask: map(bodySkinMask))
    }
}

public enum ExportMaskError: Error, CustomStringConvertible, Equatable {
    case missingReferenceSize
    case aspectMismatch(reference: CGSize, render: CGSize)

    public var description: String {
        switch self {
        case .missingReferenceSize:
            "The export carries masks but no size they were built at; refusing to guess a scale."
        case .aspectMismatch(let reference, let render):
            "The masks were built on a \(Int(reference.width))×\(Int(reference.height)) image "
                + "but the export renders \(Int(render.width))×\(Int(render.height)) — not the same "
                + "picture shape, so they would land in the wrong place."
        }
    }
}

/// Turns ``ExportMasks`` (already at render size) into what `RenderRequest`
/// takes, applying the same flag and document gates the canvas applies.
///
/// A class because it keeps the "Khoá nền" rasteriser between exports the way
/// `LivePreviewController` keeps its `BackgroundLockMaskSource` between shots.
final class ExportMaskResolver: @unchecked Sendable {
    private let context: MetalContext
    private let lock = NSLock()
    private var subjectSource: BackgroundLockMaskSource?

    init(context: MetalContext) {
        self.context = context
    }

    struct Resolved {
        var gateMasks: [any RenderGateMask] = []
        var bodySkinMask: RenderMask?
        /// Which masks actually reached the request, for the export's notes.
        var applied: [String] = []
        /// Wall-clock ms of rasterising the brush strokes at render size.
        var brushRasterMilliseconds: Double?
    }

    /// - Parameter masks: already mapped onto the render size (``ExportMasks/scaled(to:)``).
    func resolve(
        _ masks: ExportMasks, editState: EditState, width: Int, height: Int
    ) throws -> Resolved {
        var resolved = Resolved()

        // Body skin: the exact call `LivePreviewController.renderRequest` makes.
        resolved.bodySkinMask = BodySkinSync.mask(for: editState, bodySkinMask: masks.bodySkinMask)
        if resolved.bodySkinMask != nil { resolved.applied.append("bodySkin") }

        // "Khoá nền": rasterise only when `BackgroundLock.gateMasks` would pass
        // a subject through (flag on, document switch on) — the full-size
        // rasterisation is 24 MB at 24 MP and pointless otherwise. The gate
        // itself still goes through that same call below.
        if let subject = masks.subjectMask, RPEngineFeatureFlags.backgroundLock,
            BackgroundLock(editState).isOn
        {
            let source = try subjectSourceLocked()
            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                throw MetalContext.Failure.noCommandQueue
            }
            let texture = try source.encode(
                into: commandBuffer, mask: subject, width: width, height: height)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let texture {
                resolved.gateMasks += BackgroundLock.gateMasks(
                    for: editState, subjectGate: TextureGateMask(texture: texture))
                resolved.applied.append("backgroundLock")
            }
        }

        // Brush last, after the subject gate — the canvas's order. The gates
        // multiply, so the order does not change a pixel, but the same order
        // keeps a side-by-side diff of the two request builders trivial.
        //
        // Rasterised here, at the render's own size, from the strokes — not
        // upsampled from the preview (see the type's note). The coverage is
        // identity-mapped because it *is* at render size.
        if RPEngineFeatureFlags.manualMask, !masks.brushStrokes.isEmpty {
            let started = DispatchTime.now().uptimeNanoseconds
            let coverage = try ManualMaskSession.rasterize(
                masks.brushStrokes, width: width, height: height, context: context)
            resolved.brushRasterMilliseconds =
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            resolved.gateMasks.append(coverage)
            resolved.applied.append("manualMask")
        }
        return resolved
    }

    /// Drops the full-size subject texture after a render (24 MB at 24 MP).
    func releaseIntermediates() {
        lock.lock()
        let source = subjectSource
        lock.unlock()
        source?.releaseIntermediates()
    }

    private func subjectSourceLocked() throws -> BackgroundLockMaskSource {
        lock.lock()
        defer { lock.unlock() }
        if let subjectSource { return subjectSource }
        let created = try BackgroundLockMaskSource(context: context)
        subjectSource = created
        return created
    }
}
