import CoreGraphics
import Foundation

/// Zoom / pan state for the canvas, with no SwiftUI in it so the arithmetic can
/// be tested directly.
///
/// Coordinate model — deliberately simple, and the reason the zoom readout can
/// be truthful:
///
/// - `zoom` is the **display scale relative to the image's own pixels**:
///   `1.0` is 100 %, one image pixel per point. It is not relative to a
///   fit-to-window baseline, so `zoom == 1` means the same thing in every
///   window size.
/// - `offset` moves the image's centre away from the view's centre, in points.
/// - The image therefore occupies
///   `CGRect(center: viewCentre + offset, size: imagePixelSize * zoom)`.
public struct CanvasViewport: Hashable, Sendable {
    /// 5 % — enough to see a 24 MP frame whole in a small window.
    public static let minZoom: CGFloat = 0.05
    /// 1600 % — pixel peeping for skin retouch.
    public static let maxZoom: CGFloat = 16

    public private(set) var zoom: CGFloat
    public private(set) var offset: CGSize
    /// `true` while the viewport is following the window size instead of a zoom
    /// the user chose. Any explicit zoom or pan clears it; `fit` sets it.
    public private(set) var isFittingToWindow: Bool

    public init(zoom: CGFloat = 1, offset: CGSize = .zero, isFittingToWindow: Bool = true) {
        self.zoom = Self.clampZoom(zoom)
        self.offset = offset
        self.isFittingToWindow = isFittingToWindow
    }

    public static func clampZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(maxZoom, max(minZoom, value))
    }

    // MARK: - Fitting

    /// The zoom at which `imageSize` exactly fits inside `viewSize`.
    /// Never magnifies past 100 %: a 200 px thumbnail in a 4K window should be
    /// shown at 100 %, not blown up to a blurry wall.
    public static func fitZoom(imageSize: CGSize, in viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
            viewSize.width > 0, viewSize.height > 0
        else { return 1 }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return clampZoom(min(scale, 1))
    }

    public mutating func fit(imageSize: CGSize, in viewSize: CGSize) {
        zoom = Self.fitZoom(imageSize: imageSize, in: viewSize)
        offset = .zero
        isFittingToWindow = true
    }

    /// Re-fits only while the user has not taken control of the zoom. Called on
    /// every window resize.
    public mutating func refitIfFollowingWindow(imageSize: CGSize, in viewSize: CGSize) {
        guard isFittingToWindow else { return }
        fit(imageSize: imageSize, in: viewSize)
    }

    /// 100 %, centred.
    public mutating func actualSize() {
        zoom = Self.clampZoom(1)
        offset = .zero
        isFittingToWindow = false
    }

    // MARK: - Zoom

    /// Sets an absolute zoom while keeping the image point currently under
    /// `anchor` under `anchor`. `anchor` is in view coordinates, origin
    /// top-left.
    public mutating func setZoom(
        _ newZoom: CGFloat,
        anchor: CGPoint,
        viewSize: CGSize
    ) {
        let clamped = Self.clampZoom(newZoom)
        guard clamped != zoom else { return }

        let centre = CGPoint(
            x: viewSize.width / 2 + offset.width,
            y: viewSize.height / 2 + offset.height
        )
        // The image-space point under the anchor, in image pixels from centre.
        let imagePoint = CGPoint(
            x: (anchor.x - centre.x) / zoom,
            y: (anchor.y - centre.y) / zoom
        )
        let newCentre = CGPoint(
            x: anchor.x - imagePoint.x * clamped,
            y: anchor.y - imagePoint.y * clamped
        )
        zoom = clamped
        offset = CGSize(
            width: newCentre.x - viewSize.width / 2,
            height: newCentre.y - viewSize.height / 2
        )
        isFittingToWindow = false
    }

    public mutating func zoom(by factor: CGFloat, anchor: CGPoint, viewSize: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        setZoom(zoom * factor, anchor: anchor, viewSize: viewSize)
    }

    /// Keyboard / menu zoom: a fixed step anchored at the centre of the view.
    ///
    /// No `viewSize` needed, and that is not a shortcut: substituting
    /// `anchor = viewSize/2` into ``setZoom(_:anchor:viewSize:)`` gives
    /// `offset' = offset · (zoom' / zoom)` with the view size cancelling out.
    /// `CanvasViewportTests.centreAnchoredStepMatchesExplicitAnchor` pins that.
    public mutating func zoomStep(_ direction: ZoomDirection) {
        let factor: CGFloat = direction == .in ? 1.25 : 1 / 1.25
        let clamped = Self.clampZoom(zoom * factor)
        guard clamped != zoom, zoom > 0 else { return }
        let ratio = clamped / zoom
        offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
        zoom = clamped
        isFittingToWindow = false
    }

    public enum ZoomDirection: Sendable { case `in`, out }

    // MARK: - Pan

    public mutating func pan(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        isFittingToWindow = false
    }

    /// Stops the image being dragged off screen.
    ///
    /// On an axis where the image is smaller than the view it is pinned centred
    /// (offset 0); where it is larger, the offset is limited so an edge of the
    /// image can never come inside the corresponding edge of the view.
    public mutating func clampOffset(imageSize: CGSize, viewSize: CGSize) {
        offset = Self.clampedOffset(offset, imageSize: imageSize, viewSize: viewSize, zoom: zoom)
    }

    public static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        viewSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        func axis(_ value: CGFloat, image: CGFloat, view: CGFloat) -> CGFloat {
            let displayed = image * zoom
            guard displayed > view else { return 0 }
            let limit = (displayed - view) / 2
            return min(limit, max(-limit, value))
        }
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGSize(
            width: axis(offset.width, image: imageSize.width, view: viewSize.width),
            height: axis(offset.height, image: imageSize.height, view: viewSize.height)
        )
    }

    // MARK: - Derived

    /// Where the image should be drawn, in view coordinates.
    public func imageFrame(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        let displayed = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        return CGRect(
            x: (viewSize.width - displayed.width) / 2 + offset.width,
            y: (viewSize.height - displayed.height) / 2 + offset.height,
            width: displayed.width,
            height: displayed.height
        )
    }

    /// "38 %" / "100 %" for the canvas status line.
    public var zoomPercentText: String {
        "\(Int((zoom * 100).rounded()))%"
    }
}
