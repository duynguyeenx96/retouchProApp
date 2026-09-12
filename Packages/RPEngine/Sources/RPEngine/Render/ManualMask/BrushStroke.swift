import CoreGraphics
import Foundation

/// What a brush stroke does to the mask.
///
/// One enum, not two code paths: docs/PLAN.md §6.1 says *"add/subtract là cờ
/// blend-mode của kernel"*, and `rp_manual_mask_splat` takes it as a `uint`.
public enum BrushMode: String, Sendable, Codable, Hashable, CaseIterable {
    /// Paint coverage in — `max(existing, coverage)`.
    case add
    /// Rub coverage out — `min(existing, 1 - coverage)`.
    case subtract

    public var isSubtract: Bool { self == .subtract }
}

/// One sampled input event: where the finger / pointer was, and how hard.
///
/// **Not a `PKStrokePoint`.** docs/PLAN.md §6.1 rules PencilKit out for this job
/// (a `PKCanvasView` is a drawing surface, not a mask editor, and Apple's own
/// documentation says mutating a `PKStroke` breaks `UndoManager`), so the stroke
/// model is this plain value type and the input is raw `UITouch` / `NSEvent`
/// captured in RPUI.
///
/// `location` is in **mask pixels**, y down — the same space the coverage texture
/// is in. Converting from view points is the UI's job, because only the UI knows
/// the zoom and the pan.
public struct BrushPoint: Sendable, Equatable, Hashable, Codable {
    public var location: CGPoint
    /// 0…1. Devices with no force sensor report 1 (see
    /// `BrushInputView`): a brush that painted nothing on an iPhone 17 because
    /// `UITouch.force` is 0 there would be a bug, not a feature.
    public var pressure: Double

    public init(location: CGPoint, pressure: Double = 1) {
        self.location = location
        self.pressure = min(1, max(0, pressure))
    }
}

/// One continuous drag, from touch-down to touch-up.
///
/// The stroke keeps its **input points**, not the stamps they expand into: the
/// stamps are derived (``stamps``) and re-derived identically on every replay,
/// which is what makes undo "replay the list from the start" rather than "keep a
/// texture snapshot per stroke" (docs/PLAN.md §6.1).
///
/// `Codable` so a future version can persist the stroke list next to the PNG if
/// the need ever appears. Nothing writes it today, and the plan does not ask for
/// it: the PNG is the document, the strokes are this session's undo history —
/// the same trade every raster editor makes.
public struct BrushStroke: Sendable, Equatable, Hashable, Codable {
    /// Radius in **mask pixels** at full pressure.
    public var radius: Double
    /// 0…1 plateau fraction: 1 is a hard-edged disc, 0 is all falloff.
    public var hardness: Double
    /// 0…1 peak coverage the stroke deposits.
    public var flow: Double
    public var mode: BrushMode
    public var points: [BrushPoint]

    /// How much of the radius the lightest touch keeps.
    ///
    /// A stylus at 0 pressure must still paint *something* visible, otherwise the
    /// start and end of every stroke vanish; 0.35 is the usual floor.
    public static let minimumPressureScale: Double = 0.35

    /// Centre-to-centre spacing of the stamps, as a fraction of the radius.
    ///
    /// 0.15 keeps the union of consecutive discs smooth at the falloff scale
    /// without dispatching a stamp per pixel: a 60 px brush stamps every 9 px.
    public static let stampSpacingFraction: Double = 0.15

    public init(
        radius: Double, hardness: Double = 0.5, flow: Double = 1,
        mode: BrushMode = .add, points: [BrushPoint] = []
    ) {
        self.radius = max(0.5, radius)
        self.hardness = min(1, max(0, hardness))
        self.flow = min(1, max(0, flow))
        self.mode = mode
        self.points = points
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The discs this stroke rasterises into, in mask pixels.
    ///
    /// Equivalent to feeding every point to a ``Stamper`` in order — asserted by
    /// `ManualMaskStrokeTests.incrementalStampingMatchesAReplay`, which is the
    /// property the live-drag fast path depends on.
    public var stamps: [BrushStamp] {
        var stamper = Stamper(stroke: self)
        var all: [BrushStamp] = []
        for point in points { all += stamper.append(point) }
        return all
    }

    /// Radius of one stamp once pressure is applied.
    public func radius(atPressure pressure: Double) -> Double {
        let scale =
            Self.minimumPressureScale
            + (1 - Self.minimumPressureScale) * min(1, max(0, pressure))
        return radius * scale
    }

    /// Turns incoming points into evenly spaced stamps, **incrementally**.
    ///
    /// The state it carries (the previous point and the leftover distance since
    /// the last stamp) is the whole reason a live drag can rasterise only the
    /// stamps it just produced instead of re-rasterising the stroke: the sequence
    /// a `Stamper` emits for points 1…n then n+1…m is identical to the sequence
    /// it emits for 1…m.
    public struct Stamper: Sendable {
        private let radius: Double
        private var previous: BrushPoint?
        /// Distance already walked past the last emitted stamp.
        private var carry: Double = 0

        public init(stroke: BrushStroke) {
            self.radius = stroke.radius
            self.spacing = max(0.75, stroke.radius * BrushStroke.stampSpacingFraction)
            self.minimumScale = BrushStroke.minimumPressureScale
        }

        private let spacing: Double
        private let minimumScale: Double

        private func scaled(_ pressure: Double) -> Double {
            radius * (minimumScale + (1 - minimumScale) * min(1, max(0, pressure)))
        }

        /// The stamps this point adds. A touch-down (the first point) always
        /// produces one, so a tap paints a dot.
        public mutating func append(_ point: BrushPoint) -> [BrushStamp] {
            guard let last = previous else {
                previous = point
                carry = 0
                return [BrushStamp(center: point.location, radius: scaled(point.pressure))]
            }
            let dx = point.location.x - last.location.x
            let dy = point.location.y - last.location.y
            let segment = (dx * dx + dy * dy).squareRoot()
            guard segment.isFinite, segment > 0 else {
                previous = point
                return []
            }

            var produced: [BrushStamp] = []
            var travelled = spacing - carry
            while travelled <= segment {
                let t = travelled / segment
                let center = CGPoint(x: last.location.x + dx * t, y: last.location.y + dy * t)
                let pressure = last.pressure + (point.pressure - last.pressure) * t
                produced.append(BrushStamp(center: center, radius: scaled(pressure)))
                travelled += spacing
            }
            carry = segment - (travelled - spacing)
            previous = point
            return produced
        }
    }
}

/// One soft disc, ready for `rp_manual_mask_splat`. Mirrors `RPManualMaskStamp`
/// in ManualMaskShaders.metal; `ManualMaskTests` pins the stride.
public struct BrushStamp: Sendable, Equatable, Hashable {
    public var center: CGPoint
    /// Mask pixels, pressure already applied.
    public var radius: Double

    public init(center: CGPoint, radius: Double) {
        self.center = center
        self.radius = radius
    }
}
