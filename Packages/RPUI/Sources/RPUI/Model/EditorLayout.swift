import CoreGraphics
import Foundation

/// Which arrangement the editor uses at a given window width.
///
/// Driven by the **measured width**, not by `horizontalSizeClass`: the size
/// class does not exist on macOS, and a narrow Mac window has the same problem
/// an iPhone does. One rule, one code path, testable without a view.
public enum EditorLayout: String, Hashable, Sendable {
    /// Screens 1b / 2c — canvas centre, 326 pt slider panel, 56 pt group rail.
    case threePane
    /// Screens 1a / 2a — full-bleed canvas over an attached tool sheet.
    case compact

    /// Below this the canvas would be narrower than the two side panels put
    /// together (`macPanelWidth + macRailWidth + 320`), which is unusable.
    public static let threePaneMinimumWidth: CGFloat = 900

    public static func forWidth(_ width: CGFloat) -> EditorLayout {
        width >= threePaneMinimumWidth ? .threePane : .compact
    }

    public var showsSidePanels: Bool { self == .threePane }
}

/// Panel sizes the layout rule above is checked against.
///
/// The design's own numbers live in ``RPTheme/Metrics``; these forward to them
/// so the threshold and the views cannot drift apart.
public enum EditorMetrics {
    /// The two fixed columns to the right of the canvas in screen 1b.
    public static var sidePanelsWidth: CGFloat {
        RPTheme.Metrics.macPanelWidth + RPTheme.Metrics.macRailWidth
    }
    public static var sliderPanelWidth: CGFloat { RPTheme.Metrics.macPanelWidth }
    public static var groupRailWidth: CGFloat { RPTheme.Metrics.macRailWidth }
    public static var filmstripHeight: CGFloat { RPTheme.Metrics.macFilmstripHeight }
    public static var thumbnailPixelSize: Int { RPTheme.Metrics.thumbnailPixelSize }
}
