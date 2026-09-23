import Foundation

/// One hand-painted brush stroke as the **document** stores it: resolution-free
/// metadata, never pixels (docs/ADR-0019 addendum 2026-09-23 "strokes, not a
/// PNG", docs/ADR-0025).
///
/// RPEngine's `BrushStroke` is the same stroke in *mask pixels* of whatever
/// texture it is being painted into; this type is that stroke normalised so it
/// can be replayed onto any resolution — the 2048 px preview when a shot is
/// reopened, the full-size frame when it is exported.
///
/// ## Coordinates
///
/// * **Points**: `x` is a fraction of the image **width**, `y` a fraction of the
///   image **height**, origin top-left, y down — the same whole-frame, per-axis
///   mapping `ExportMasks` uses for every other whole-frame mask, so a point
///   lands on the same image feature on a 2048×1365 preview and a 6000×4000
///   export even though the two aspect ratios differ by a rounding.
/// * **Radius**: a fraction of the image's **long edge**. One scalar has to
///   stay a circle, so it cannot be per-axis; the long edge is the dimension
///   `RenderQuality` sizes previews by, so "radius 0.03" means the same
///   on-screen brush on every picture the preview pipeline produces.
///
/// `hardness` and `flow` are 0…1 and resolution-free already.
public struct ManualMaskStroke: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, Codable {
        case add
        case subtract
    }

    public struct Point: Sendable, Hashable {
        /// Fraction of the image width, 0…1 (a point just outside the frame
        /// is kept: a stamp centred off-frame still covers the edge).
        public var x: Double
        /// Fraction of the image height, 0…1.
        public var y: Double
        /// 0…1.
        public var pressure: Double

        public init(x: Double, y: Double, pressure: Double = 1) {
            self.x = x
            self.y = y
            self.pressure = pressure
        }
    }

    /// Fraction of the image's long edge, at full pressure.
    public var radius: Double
    public var hardness: Double
    public var flow: Double
    public var mode: Mode
    public var points: [Point]

    public init(radius: Double, hardness: Double, flow: Double, mode: Mode, points: [Point]) {
        self.radius = radius
        self.hardness = hardness
        self.flow = flow
        self.mode = mode
        self.points = points
    }
}

extension ManualMaskStroke: Codable {
    private enum CodingKeys: String, CodingKey {
        case radius, hardness, flow, mode, points
    }

    /// Points are one flat `[x, y, pressure, x, y, pressure, …]` array rather
    /// than an array of objects: a stroke is hundreds of points and the keys
    /// would triple the file for no information.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decode(Double.self, forKey: .radius)
        hardness = try container.decodeIfPresent(Double.self, forKey: .hardness) ?? 0.5
        flow = try container.decodeIfPresent(Double.self, forKey: .flow) ?? 1
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .add
        let flat = try container.decodeIfPresent([Double].self, forKey: .points) ?? []
        guard flat.count % 3 == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .points, in: container,
                debugDescription: "points must be [x, y, pressure] triples; found \(flat.count) numbers")
        }
        guard radius.isFinite, radius > 0, flat.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(
                forKey: .radius, in: container, debugDescription: "non-finite or non-positive stroke value")
        }
        var points: [Point] = []
        points.reserveCapacity(flat.count / 3)
        var index = 0
        while index < flat.count {
            points.append(Point(x: flat[index], y: flat[index + 1], pressure: flat[index + 2]))
            index += 3
        }
        self.points = points
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(radius, forKey: .radius)
        try container.encode(hardness, forKey: .hardness)
        try container.encode(flow, forKey: .flow)
        try container.encode(mode, forKey: .mode)
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for point in points {
            flat.append(point.x)
            flat.append(point.y)
            flat.append(point.pressure)
        }
        try container.encode(flat, forKey: .points)
    }
}

/// `edits/<shot id>.strokes.json` — every brush stroke of one shot, oldest
/// first. The list **is** the brush mask; the coverage texture is derived from
/// it by replaying.
///
/// A sibling of `edits/<shot id>.json` rather than a field inside it, for the
/// two reasons ADR-0019 §8 gave for keeping pixels out of that file, which
/// still hold for a few hundred kilobytes of points: that file is rewritten on
/// every slider release, and `EditState` is hashed and compared on the
/// interaction path.
public struct ManualMaskStrokeDocument: Sendable, Hashable {
    /// Bump when the stroke encoding changes in a way this build cannot read.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var strokes: [ManualMaskStroke]

    public init(strokes: [ManualMaskStroke], formatVersion: Int = Self.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.strokes = strokes
    }
}

extension ManualMaskStrokeDocument: Codable {
    private enum CodingKeys: String, CodingKey { case formatVersion, strokes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion <= Self.currentFormatVersion else {
            throw ProjectStoreError.unsupportedFormatVersion(
                found: formatVersion, supported: Self.currentFormatVersion)
        }
        strokes = try container.decodeIfPresent([ManualMaskStroke].self, forKey: .strokes) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(strokes, forKey: .strokes)
    }
}
