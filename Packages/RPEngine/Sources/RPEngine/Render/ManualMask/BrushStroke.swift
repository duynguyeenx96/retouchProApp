import CoreGraphics
import Foundation
import RPCore

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
/// **Since 2026-09-23 the strokes are the document** (docs/ADR-0019 addendum,
/// docs/ADR-0025): the project stores every stroke as an `RPCore.ManualMaskStroke`
/// — this value normalised to the image (``normalized(imageSize:)``) — and the
/// coverage is re-rasterised from them at whatever size is needed
/// (``init(_:imageSize:)``). No PNG is written.
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

// MARK: - The stored form (RPCore.ManualMaskStroke)

extension BrushMode {
    init(_ mode: ManualMaskStroke.Mode) {
        switch mode {
        case .add: self = .add
        case .subtract: self = .subtract
        }
    }

    var stored: ManualMaskStroke.Mode {
        switch self {
        case .add: .add
        case .subtract: .subtract
        }
    }
}

extension BrushStroke {
    /// This stroke — in mask pixels of an image of `imageSize` pixels — as the
    /// resolution-free form the project stores: points as fractions of the width
    /// and height, the radius as a fraction of the long edge (see
    /// `RPCore.ManualMaskStroke` for why each).
    public func normalized(imageSize: CGSize) -> ManualMaskStroke {
        let width = max(Double(imageSize.width), 1)
        let height = max(Double(imageSize.height), 1)
        let longEdge = max(width, height)
        return ManualMaskStroke(
            radius: radius / longEdge, hardness: hardness, flow: flow, mode: mode.stored,
            points: points.map {
                ManualMaskStroke.Point(
                    x: Double($0.location.x) / width, y: Double($0.location.y) / height,
                    pressure: $0.pressure)
            })
    }

    /// A stored stroke replayed onto an image of `imageSize` pixels.
    ///
    /// The inverse of ``normalized(imageSize:)``. Round-tripping at the same
    /// size gives back the same pixels (`x / w * w` is exact to well below the
    /// `Float` the splat kernel reads — asserted by
    /// `ManualMaskStrokeStorageTests`), and at another size the stroke scales
    /// with the picture: every point per axis, the radius with the long edge —
    /// so the stamp *count* is the same at 2048 px and at 6000 px (spacing is a
    /// fraction of the radius) and the export is the canvas's mask drawn
    /// sharper, not a different mask.
    public init(_ stored: ManualMaskStroke, imageSize: CGSize) {
        let width = Double(imageSize.width)
        let height = Double(imageSize.height)
        let longEdge = max(width, height)
        self.init(
            radius: stored.radius * longEdge, hardness: stored.hardness, flow: stored.flow,
            mode: BrushMode(stored.mode),
            points: stored.points.map {
                BrushPoint(
                    location: CGPoint(x: $0.x * width, y: $0.y * height), pressure: $0.pressure)
            })
    }
}
