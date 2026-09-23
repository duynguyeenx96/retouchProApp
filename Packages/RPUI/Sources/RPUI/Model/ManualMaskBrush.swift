import CoreGraphics
import Foundation
import RPEngine

/// What the brush is set to right now: size, hardness, flow and add/erase
/// (docs/PLAN.md §6.1 "Cọ mask thủ công", docs/ADR-0019).
///
/// ## Why this is chrome and not `EditState`
///
/// A brush setting is *where the user's hand is*, not part of the document: the
/// document's half of the feature is the strokes themselves, stored normalised
/// in `edits/<shot id>.strokes.json` (`RPCore.ManualMaskStroke`, ADR-0019's
/// 2026-09-23 addendum) — each stroke carries its own radius as a fraction of
/// the image, so the *setting* is not needed to replay it. Putting a radius
/// into `EditState` would put it into every `Preset` too, and a preset carrying
/// "64 px brush" is meaningless on another image. So it lives in
/// ``EditorChrome`` beside `macTool`, which is never written to disk
/// (docs/design/SPEC.md cross-cutting rule 1: *"do not invent new EditState
/// fields"*).
///
/// ## The three numbers are 0–100, the engine's are not
///
/// Every slider in this app is 0–100 (docs/PLAN.md §0), so these are too and the
/// brush bar can reuse `RPSliderRow` unchanged. The engine speaks a different
/// language — a radius in **mask pixels** and 0…1 for hardness and flow
/// (`BrushStroke`) — and the conversion happens here, in one place, so no view
/// has to know it.
public struct ManualMaskBrushSettings: Hashable, Sendable {
    /// Smallest radius the size slider can reach, in mask pixels. A 4 px radius
    /// is still two pixels of falloff on each side, i.e. the smallest brush that
    /// can draw a soft edge at all.
    public static let minimumRadius: Double = 4
    /// Largest radius, in mask pixels: an eighth of a 2048 px preview's long
    /// edge. Bigger than that and a single stamp covers the face — which is what
    /// the *absence* of a mask already means.
    public static let maximumRadius: Double = 256

    /// 0–100. Maps linearly onto ``minimumRadius``…``maximumRadius``.
    public var size: Double
    /// 0–100 → `BrushStroke.hardness` 0…1. 100 is a hard-edged disc.
    public var hardness: Double
    /// 0–100 → `BrushStroke.flow` 0…1, the peak coverage one stroke deposits.
    public var flow: Double
    /// Paint the mask in, or rub it out (`BrushMode`).
    public var mode: BrushMode

    /// Defaults: a 64 px brush, half-soft, full flow, adding. Full flow because
    /// a mask is a selection — "select this region" is the common case and a
    /// half-covered selection is the surprising one.
    public init(size: Double = 24, hardness: Double = 50, flow: Double = 100, mode: BrushMode = .add)
    {
        self.size = Self.clamped(size)
        self.hardness = Self.clamped(hardness)
        self.flow = Self.clamped(flow)
        self.mode = mode
    }

    private static func clamped(_ value: Double) -> Double { min(100, max(0, value)) }

    /// Radius in **mask pixels** — the space `BrushPoint.location` is in, and
    /// therefore the space the radius has to be in too.
    ///
    /// Deliberately *not* a radius in view points: a brush measured on screen
    /// would paint a different amount of the picture at every zoom level, so a
    /// mask painted zoomed in would not match the same gesture zoomed out. Every
    /// raster editor sizes its brush in image pixels for this reason; the canvas
    /// scales it back into view points for the cursor and the overlay
    /// (``ManualMaskBrushGeometry/viewLength(maskLength:imageSize:frame:)``).
    public var radiusInMaskPixels: Double {
        Self.minimumRadius + (size / 100) * (Self.maximumRadius - Self.minimumRadius)
    }

    public var hardnessFraction: Double { hardness / 100 }
    public var flowFraction: Double { flow / 100 }

    /// "64 px" — what the size row shows instead of a bare 0–100 number, because
    /// the pixel figure is the one that predicts what the stroke will cover.
    public var radiusText: String { "\(Int(radiusInMaskPixels.rounded())) px" }

    public var isErasing: Bool { mode == .subtract }
}

/// View points ⇄ mask pixels for the brush, kept out of the views so the
/// arithmetic is testable without a window or a GPU.
///
/// The mask is painted at the size of the **decoded preview**, which is exactly
/// the texture the canvas renders (`LivePreviewController.sourceSize`), so
/// "mask pixels" and "image pixels" are the same grid here and
/// `ManualMaskCoverage.maskToImage` stays the identity (ADR-0019 §4). That is
/// why this type converts to *image* pixels and stops: a second scale factor
/// would be a second chance to be half a frame out.
public enum ManualMaskBrushGeometry {

    /// A point on screen → the mask pixel under it, or `nil` when the point is
    /// not on the edited picture at all.
    ///
    /// - Parameters:
    ///   - viewPoint: in the canvas's own coordinates, origin top-left.
    ///   - paneOriginX: x of the *edited* pane inside the canvas. 0 in the
    ///     single-pane layout; half a canvas plus the gap in the Mac's
    ///     Trước | Sau comparison, where the picture the brush paints on is the
    ///     right-hand one. Getting this wrong is how a stroke lands mirrored on
    ///     the other side of the canvas, so it is a parameter rather than an
    ///     assumption.
    ///   - frame: where the picture is drawn inside that pane
    ///     (`CanvasViewport.imageFrame`).
    ///
    /// The result is **not clamped to the picture**: a stroke that runs off the
    /// edge and comes back is one continuous stroke, and the rasteriser only
    /// writes the pixels that exist. What *is* rejected is a point in the
    /// untouched "Trước" pane, which is not a place a mask can be painted.
    public static func maskPoint(
        viewPoint: CGPoint, paneOriginX: CGFloat = 0, imageSize: CGSize, frame: CGRect
    ) -> CGPoint? {
        guard frame.width > 0, frame.height > 0,
            imageSize.width > 0, imageSize.height > 0,
            viewPoint.x.isFinite, viewPoint.y.isFinite
        else { return nil }
        let local = CGPoint(x: viewPoint.x - paneOriginX, y: viewPoint.y)
        guard local.x >= 0 else { return nil }
        return FaceOverlayGeometry.imagePoint(
            viewPoint: local, imageSize: imageSize, frame: frame)
    }

    /// The inverse, for drawing: a mask pixel → where it sits on screen.
    public static func viewPoint(
        maskPoint: CGPoint, imageSize: CGSize, frame: CGRect
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGPoint(
            x: frame.minX + maskPoint.x * frame.width / imageSize.width,
            y: frame.minY + maskPoint.y * frame.height / imageSize.height)
    }

    /// A length in mask pixels → the same length on screen, so the overlay's
    /// stroke width is the brush's actual footprint at the current zoom.
    public static func viewLength(
        maskLength: Double, imageSize: CGSize, frame: CGRect
    ) -> CGFloat {
        guard imageSize.width > 0, frame.width > 0 else { return 0 }
        return CGFloat(maskLength) * frame.width / imageSize.width
    }
}
