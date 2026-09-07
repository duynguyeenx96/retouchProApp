import CoreGraphics
import Foundation

/// How the canvas compares the original with the current edit.
public enum BeforeAfterMode: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Only the edited image.
    case off
    /// One image, a draggable vertical divider: original left, edited right.
    case split
    /// Two panes next to each other.
    case sideBySide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Edited"
        case .split: "Split"
        case .sideBySide: "Side by side"
        }
    }

    public var systemImage: String {
        switch self {
        case .off: "photo"
        case .split: "rectangle.split.2x1"
        case .sideBySide: "rectangle.split.2x1.fill"
        }
    }
}

/// State of the before/after control.
///
/// **Where each side comes from, stated in the type because it is easy to
/// forget:** the "before" side is `RPEngine.PreviewRendering` decoding the file
/// under `originals/` (`PassthroughPreviewRenderer`, `appliesEditState ==
/// false`), and the "after" side is the live `MTKView` running the render graph
/// (`LivePreviewController`, docs/ADR-0013). Until Phase 2's live preview landed
/// both sides were the same pixels and this control was inert on purpose; it is
/// not any more.
///
/// With no Metal device the canvas shows the decoded original on both sides and
/// says so in its status bar — still not faking a difference.
public struct BeforeAfterState: Hashable, Sendable {
    /// The divider can never reach an edge; a 0 %-wide "before" pane would look
    /// like the control is broken.
    public static let splitRange: ClosedRange<CGFloat> = 0.02...0.98

    public var mode: BeforeAfterMode
    public private(set) var splitFraction: CGFloat
    /// Held-down "show me the original" (the `\` key / long press). Independent
    /// of `mode` so it works from any mode.
    public var isHoldingOriginal: Bool

    public init(
        mode: BeforeAfterMode = .off,
        splitFraction: CGFloat = 0.5,
        isHoldingOriginal: Bool = false
    ) {
        self.mode = mode
        self.splitFraction = Self.clampSplit(splitFraction)
        self.isHoldingOriginal = isHoldingOriginal
    }

    public static func clampSplit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(splitRange.upperBound, max(splitRange.lowerBound, value))
    }

    public mutating func setSplit(_ value: CGFloat) {
        splitFraction = Self.clampSplit(value)
    }

    /// Sets the divider from a drag in view coordinates.
    public mutating func setSplit(fromX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        setSplit(x / width)
    }

    /// `true` when the whole canvas should show the unedited image.
    public var showsOriginalFullFrame: Bool { isHoldingOriginal }

    /// `true` when the canvas has to render two images at once.
    public var needsBothImages: Bool {
        mode == .split || mode == .sideBySide
    }

    public mutating func cycleMode() {
        let all = BeforeAfterMode.allCases
        let index = all.firstIndex(of: mode) ?? 0
        mode = all[(index + 1) % all.count]
    }
}
