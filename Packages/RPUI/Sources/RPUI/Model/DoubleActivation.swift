import CoreGraphics
import Foundation

/// "Was that the second click/tap in the same spot?" — the double-click that
/// snaps a slider track back to its neutral 0 (2026-09-21, user request).
///
/// ## Why this is hand-rolled instead of `.onTapGesture(count: 2)`
///
/// `RPSliderTrack`'s gesture set is the most load-bearing arbitration in the app
/// (see that type's note): a `DragGesture` whose `minimumDistance` differs per
/// platform so the phone's `ScrollView` can still win a flick, plus a separate
/// `SpatialTapGesture` on touch because a tap never travels 12 pt. Adding a
/// third recogniser into that mix costs both of the things the existing two were
/// tuned for:
///
/// * **A double-tap recogniser delays every single tap.** UIKit (and SwiftUI on
///   top of it) cannot know a tap is single until the double-tap window has
///   expired, so tap-to-set — which is how you set a value on the phone at all —
///   would gain ~0.3 s of lag on every use.
/// * **A `TapGesture(count: 2)` next to a `DragGesture(minimumDistance: 0)` on
///   macOS has to be arbitrated**, and whichever one loses is a regression in a
///   control every panel in the app uses.
///
/// Registering the click/tap *ends the existing gestures already deliver* costs
/// nothing and changes no arbitration at all: the second click is recognised
/// after the fact, from its own `onEnded`. The visible price is that the second
/// click of a double first sets the value where it landed and then resets — one
/// frame of movement on macOS, where the drag's `onChanged` fires on mouse-down.
/// That is the trade docs/ADR-0019's brush made too: no new recogniser near the
/// scroll view.
struct DoubleActivation: Equatable, Sendable {
    /// How long the second click/tap may arrive after the first. macOS's own
    /// default double-click interval is 0.5 s and iOS's is ~0.3 s; 0.35 s is
    /// short enough that two deliberate single taps on the same slider are not
    /// read as a reset.
    static let interval: TimeInterval = 0.35

    /// How far apart the two may land and still be "the same spot", in points.
    /// A fat finger moves a few points between taps; 16 pt is about a fingertip
    /// and well under the width of any slider row.
    static let slop: CGFloat = 16

    private var lastTime: TimeInterval?
    private var lastX: CGFloat?

    init() {}

    /// Records one finished click/tap and answers whether it completed a double.
    ///
    /// `isStationary` is false when the gesture that ended was a real drag: a
    /// drag is never half of a double-click, and it also clears any pending
    /// first click, so "click, drag, click" cannot reset the slider.
    ///
    /// A completed double clears the state, so a *triple* click is one double
    /// followed by a fresh first click rather than two resets.
    mutating func register(x: CGFloat, at time: TimeInterval, isStationary: Bool = true) -> Bool {
        guard isStationary else {
            lastTime = nil
            lastX = nil
            return false
        }
        if let lastTime, let lastX,
            (0...Self.interval).contains(time - lastTime),
            abs(x - lastX) <= Self.slop
        {
            self.lastTime = nil
            self.lastX = nil
            return true
        }
        lastTime = time
        lastX = x
        return false
    }
}
