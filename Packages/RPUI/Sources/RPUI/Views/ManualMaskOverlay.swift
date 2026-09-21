import CoreGraphics
import RPEngine
import SwiftUI

/// Where the brush has been, drawn over the picture (docs/PLAN.md §6.1,
/// docs/ADR-0019).
///
/// ## It draws the strokes, not the coverage texture
///
/// The mask itself lives on the GPU as an `r8Unorm` texture that only the render
/// graph reads (ADR-0019 §4 — a CPU value type would mean a 2.8 MB read-back and
/// re-upload per frame of a drag). Showing *those pixels* on screen would mean
/// exactly that read-back, per frame, to draw something the user is already
/// watching being painted. So this view re-draws the same geometry the session
/// was given — `BrushStroke.points`, in mask pixels, scaled back into view
/// points — which costs a `Path` per stroke and no GPU stall.
///
/// It is therefore an **indication of where the stroke went, not a rendering of
/// the mask**: the falloff is drawn as one flat translucent band instead of the
/// splat kernel's smoothstep, and overlapping strokes do not darken. The truth
/// of what is selected is the gated node's own output — turn a Da slider up and
/// the effect appears exactly inside the painted region, which is the check that
/// actually matters and the one the device run makes.
///
/// ## Erase strokes cut, they do not paint
///
/// A `.subtract` stroke is drawn with `.destinationOut` inside one layer, in
/// stroke order, so rubbing out and painting back over produce what the kernel
/// produces (`max` then `min(existing, 1 - coverage)` — ADR-0019 §2). Drawing
/// erases as a second colour would show the user a region that is *not* selected
/// as if it were.
struct ManualMaskOverlay: View {
    /// Finished strokes, oldest first (`LivePreviewController.manualMaskStrokes`).
    let strokes: [BrushStroke]
    /// The stroke the finger is drawing right now, if any. It is not in
    /// ``strokes`` until it ends, and only the view capturing the drag has it.
    let liveStroke: BrushStroke?
    /// Pixel size of the picture the mask was painted on.
    let imageSize: CGSize
    /// Where that picture is drawn, in the edited pane's coordinates.
    let frame: CGRect
    /// x of the edited pane inside the canvas — non-zero only in the Mac's
    /// Trước | Sau comparison, where the mask belongs over the right-hand pane.
    var paneOriginX: CGFloat = 0

    /// Mint at a third: visible over skin, hair and a white background alike,
    /// and light enough to retouch through.
    private static let tint = 0.34

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            context.drawLayer { layer in
                for stroke in strokes { draw(stroke, in: layer) }
                if let liveStroke { draw(liveStroke, in: layer) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ stroke: BrushStroke, in context: GraphicsContext) {
        guard !stroke.points.isEmpty else { return }
        var layer = context
        layer.blendMode = stroke.mode == .add ? .normal : .destinationOut

        let width = ManualMaskBrushGeometry.viewLength(
            maskLength: stroke.radius * 2, imageSize: imageSize, frame: frame)
        guard width > 0 else { return }

        var path = Path()
        let points = stroke.points.map {
            let view = ManualMaskBrushGeometry.viewPoint(
                maskPoint: $0.location, imageSize: imageSize, frame: frame)
            return CGPoint(x: view.x + paneOriginX, y: view.y)
        }
        if points.count == 1 {
            // A tap leaves a dot, exactly as `beginStroke` does on the GPU.
            let radius = width / 2
            path.addEllipse(
                in: CGRect(
                    x: points[0].x - radius, y: points[0].y - radius,
                    width: width, height: width))
            layer.fill(path, with: .color(RPTheme.accent.opacity(Self.tint)))
            return
        }
        path.addLines(points)
        layer.stroke(
            path, with: .color(RPTheme.accent.opacity(Self.tint)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
