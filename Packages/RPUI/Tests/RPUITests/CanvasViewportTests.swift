import CoreGraphics
import Testing

@testable import RPUI

@Suite("Canvas zoom / pan arithmetic")
struct CanvasViewportTests {
    static let view = CGSize(width: 800, height: 600)
    static let image = CGSize(width: 6000, height: 4000)

    @Test("Fit scales the long edge to the view and never magnifies past 100 %")
    func fitting() {
        #expect(
            CanvasViewport.fitZoom(imageSize: Self.image, in: Self.view)
                == min(800.0 / 6000, 600.0 / 4000))

        // A small image in a big window stays at 100 % rather than being blown up.
        let small = CGSize(width: 200, height: 100)
        #expect(CanvasViewport.fitZoom(imageSize: small, in: Self.view) == 1)

        // Degenerate inputs must not produce NaN.
        #expect(CanvasViewport.fitZoom(imageSize: .zero, in: Self.view) == 1)
        #expect(CanvasViewport.fitZoom(imageSize: Self.image, in: .zero) == 1)
    }

    @Test("Zooming keeps the image point under the anchor under the anchor")
    func zoomAnchorIsStable() {
        var viewport = CanvasViewport()
        viewport.fit(imageSize: Self.image, in: Self.view)

        let anchor = CGPoint(x: 620, y: 180)
        let before = imagePoint(under: anchor, viewport: viewport)
        viewport.setZoom(viewport.zoom * 3, anchor: anchor, viewSize: Self.view)
        let after = imagePoint(under: anchor, viewport: viewport)

        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - after.y) < 0.001)
    }

    /// The reason `zoomStep` can drop its `viewSize` parameter.
    @Test("Centre-anchored step matches an explicit centre anchor")
    func centreAnchoredStepMatchesExplicitAnchor() {
        var stepped = CanvasViewport(zoom: 0.4, offset: CGSize(width: 37, height: -12))
        var anchored = stepped

        stepped.zoomStep(.in)
        anchored.setZoom(
            0.4 * 1.25,
            anchor: CGPoint(x: Self.view.width / 2, y: Self.view.height / 2),
            viewSize: Self.view)

        #expect(abs(stepped.zoom - anchored.zoom) < 1e-9)
        #expect(abs(stepped.offset.width - anchored.offset.width) < 1e-9)
        #expect(abs(stepped.offset.height - anchored.offset.height) < 1e-9)
    }

    @Test("Zoom is clamped to the 5 %…1600 % range")
    func zoomIsClamped() {
        var viewport = CanvasViewport(zoom: 1)
        for _ in 0..<200 { viewport.zoomStep(.in) }
        #expect(viewport.zoom == CanvasViewport.maxZoom)
        for _ in 0..<400 { viewport.zoomStep(.out) }
        #expect(viewport.zoom == CanvasViewport.minZoom)

        // A non-finite zoom is a bug upstream, not a request for 1600 %: it
        // resets to 100 % rather than propagating.
        #expect(CanvasViewport(zoom: CGFloat.nan).zoom == 1)
        #expect(CanvasViewport(zoom: CGFloat.infinity).zoom == 1)
    }

    @Test("An image smaller than the view is pinned centred; a larger one cannot be dragged off")
    func clampingOffsets() {
        // Fitted: displayed size <= view on both axes, so any pan snaps back.
        var fitted = CanvasViewport()
        fitted.fit(imageSize: Self.image, in: Self.view)
        fitted.pan(by: CGSize(width: 500, height: 500))
        fitted.clampOffset(imageSize: Self.image, viewSize: Self.view)
        #expect(fitted.offset == .zero)

        // At 100 % the 6000 px image is much wider than the 800 pt view.
        var zoomed = CanvasViewport()
        zoomed.actualSize()
        zoomed.pan(by: CGSize(width: 100_000, height: 100_000))
        zoomed.clampOffset(imageSize: Self.image, viewSize: Self.view)
        #expect(zoomed.offset.width == CGFloat(6000 - 800) / 2)
        #expect(zoomed.offset.height == CGFloat(4000 - 600) / 2)

        let frame = zoomed.imageFrame(imageSize: Self.image, viewSize: Self.view)
        // The image's left/top edge has been dragged to the view's left/top edge
        // and no further: the view stays covered.
        #expect(abs(frame.minX) < 0.001)
        #expect(abs(frame.minY) < 0.001)
    }

    @Test("Fit follows the window until the user takes over")
    func fitFollowsWindowUntilUserActs() {
        var viewport = CanvasViewport()
        viewport.refitIfFollowingWindow(imageSize: Self.image, in: Self.view)
        #expect(viewport.isFittingToWindow)
        let fitted = viewport.zoom

        // A resize re-fits.
        viewport.refitIfFollowingWindow(
            imageSize: Self.image, in: CGSize(width: 1600, height: 1200))
        #expect(viewport.zoom > fitted)

        // An explicit zoom stops the following, and later resizes leave it alone.
        viewport.zoomStep(.in)
        #expect(!viewport.isFittingToWindow)
        let held = viewport.zoom
        viewport.refitIfFollowingWindow(imageSize: Self.image, in: Self.view)
        #expect(viewport.zoom == held)
    }

    @Test("The zoom readout is the true percentage of image pixels")
    func zoomReadout() {
        var viewport = CanvasViewport()
        viewport.actualSize()
        #expect(viewport.zoomPercentText == "100%")
        viewport.setZoom(0.375, anchor: .zero, viewSize: Self.view)
        #expect(viewport.zoomPercentText == "38%")
    }

    @Test("The image frame is centred plus the offset")
    func imageFrameGeometry() {
        var viewport = CanvasViewport(zoom: 0.1, offset: CGSize(width: 20, height: -10))
        let frame = viewport.imageFrame(imageSize: Self.image, viewSize: Self.view)
        #expect(frame.size == CGSize(width: 600, height: 400))
        #expect(frame.midX == CGFloat(800) / 2 + 20)
        #expect(frame.midY == CGFloat(600) / 2 - 10)

        viewport.pan(by: CGSize(width: CGFloat.nan, height: 5))
        #expect(viewport.offset == CGSize(width: 20, height: -10))
    }

    /// Image-space coordinates of the point currently drawn at `anchor`.
    private func imagePoint(under anchor: CGPoint, viewport: CanvasViewport) -> CGPoint {
        let centre = CGPoint(
            x: Self.view.width / 2 + viewport.offset.width,
            y: Self.view.height / 2 + viewport.offset.height
        )
        return CGPoint(
            x: (anchor.x - centre.x) / viewport.zoom,
            y: (anchor.y - centre.y) / viewport.zoom
        )
    }
}

@Suite("Editor layout rule")
struct EditorLayoutTests {
    @Test("Three panes only when the canvas would still be usable")
    func layoutThreshold() {
        #expect(EditorLayout.forWidth(1440) == .threePane)
        #expect(EditorLayout.forWidth(EditorLayout.threePaneMinimumWidth) == .threePane)
        #expect(EditorLayout.forWidth(EditorLayout.threePaneMinimumWidth - 1) == .compact)
        #expect(EditorLayout.forWidth(390) == .compact)
    }

    @Test("The threshold leaves the canvas wider than the two side panels")
    func thresholdIsConsistentWithMetrics() {
        let sides = EditorMetrics.sidePanelsWidth
        #expect(EditorLayout.threePaneMinimumWidth - sides >= 320)
    }
}
