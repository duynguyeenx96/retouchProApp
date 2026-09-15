import CoreGraphics
import Foundation

/// The outer boundary of the hair mask, as an ordered ring of points in **image**
/// pixels — the extra control points the "Đầu" (head reshape) group needs and
/// that the 478-point mesh cannot supply.
///
/// docs/PLAN.md §6.2 "Đầu": *"Vision không có API viền đầu/tóc riêng, nhưng
/// RPVision **đã có** — `FaceParsingClass.hair` … Dò biên ngoài của mask tóc
/// (`VNContoursRequest` hoặc trace CPU/Metal) làm control point MLS thêm."*
/// This is the CPU trace side of that sentence.
///
/// ## Why not `VNContoursRequest`
/// Three reasons, in order of weight:
///
/// 1. **Wrong input shape.** The thing to trace is a ``RenderMask`` — a
///    `[UInt8]` coverage buffer that RPVision already handed to the graph, with
///    an affine back to the photo. `VNContoursRequest` wants an image
///    (`CGImage`/`CVPixelBuffer`), so every frame would have to wrap the buffer
///    in a pixel buffer, hand it to Vision, and map normalised, bottom-left
///    `VNContour` points back through that affine. More conversion than trace.
/// 2. **It is an edge detector, not a region tracer.** Its documented controls
///    (`contrastAdjustment`, `detectsDarkOnLight`, `contrastPivot`) describe
///    binarising an *image*; the output is a contour hierarchy with its own
///    polygon approximation. On a mask that is already binary that is a second,
///    undocumented thresholding step between the parsing model and the warp,
///    and the exact vertex positions are not specified — for a warp, where a
///    control point's position *is* the answer, that is the wrong dependency.
/// 3. **RPEngine does not import Vision** (and the layering audit in RPTestKit
///    is what keeps this package testable without a model or a device). A
///    ~2400-pixel Moore trace on a 512² mask is a pure function, runs anywhere,
///    and is measured in `Research/bench/p6-head-reshape-*.json`
///    (`speed.trace_ms`).
///
/// The cost of choosing this is stated rather than hidden: the trace is
/// **ours**, so it has to be verified against something independent. It is —
/// `Research/bench/p6-head-hairline-reference.json`, produced by
/// `Research/bench/hair-boundary-reference.py` (NumPy, a completely different
/// algorithm: per-row/column extremes of the largest 4-connected component),
/// and compared frame by frame in `HeadReshapeGeometryTests`.
public enum HairBoundary {

    /// Coverage at or above this counts as hair.
    ///
    /// The production mask is `ParsedFace.feathered(.hair)` — soft edges, 0…255 —
    /// so a threshold is unavoidable; 128 is the half-coverage isoline, i.e. the
    /// same place `MaskRasteriser` puts the visual edge of the mask.
    public static let coverageThreshold: UInt8 = 128

    /// How many boundary points become MLS handles. The raw trace is ~2400
    /// points on a 512² parsing mask (**measured**: median 2362, max 2476 over
    /// the 11 a6300 frames); the whole "Mặt" group uses 150 handles, so taking
    /// every traced pixel would be 16× the solve for one slider. 96 is ~2.7× the
    /// 36-point face oval, for an outline that is ~1.7× longer.
    ///
    /// Not tuned for looks — measured for cost and for round-trip error in
    /// `Research/bench/p6-head-reshape-*.json`. In practice a real frame keeps
    /// fewer: a median of 22 % of the 96 are clipped by the parsing crop and
    /// dropped, plus those that crowd a mesh handle, leaving a median of 65.
    public static let sampleCount = 96

    /// One traced boundary pixel.
    public struct Point: Sendable, Equatable {
        /// Position in **image** pixels (the mask's `maskToImage` already applied).
        public var location: CGPoint
        /// The pixel sat on the mask rectangle's own edge, so this is where the
        /// *crop* ended and not where the hair ended.
        ///
        /// Measured, not hypothetical (`Research/bench/p6-head-hairline-reference.json`,
        /// produced by the NumPy reference): on the 11 a6300 frames the parsing
        /// crop (`CropRegion`, k = 1.87 around the face) cuts the hair on
        /// **10 of 11** — every one of those ten at the *bottom*, where the hair
        /// runs off the shoulders, and **3 of them** (DSC05123, DSC05146,
        /// DSC05164) at the *top*, i.e. across the crown. A clipped point carries
        /// no information about the silhouette, so ``HeadReshape`` drops it: it
        /// neither moves nor pins.
        public var isClipped: Bool

        public init(location: CGPoint, isClipped: Bool) {
            self.location = location
            self.isClipped = isClipped
        }
    }

    /// The traced ring plus the numbers a bench wants without re-deriving them.
    public struct Outline: Sendable {
        /// Every traced boundary pixel of the largest component, in ring order,
        /// in image pixels. Not closed by repetition: the last point joins the
        /// first.
        public var contour: [Point]
        /// Pixels in the component that was traced.
        public var componentPixelCount: Int
        /// Pixels in *all* hair components at or above the threshold. The ratio
        /// says whether dropping the smaller components mattered: measured
        /// **≥ 0.9997** on all 11 a6300 frames (9 of them have exactly one
        /// component; the worst, DSC05403, has two and loses 0.03 % of the mask).
        public var maskPixelCount: Int
        /// Size of the mask the trace ran on, in mask pixels.
        public var maskSize: CGSize

        public var clippedCount: Int { contour.count { $0.isClipped } }

        /// `contour` resampled to `count` points at uniform arc length, starting
        /// at `contour[0]`.
        ///
        /// A sample is marked clipped when **either** endpoint of the segment it
        /// landed on is clipped — deliberately pessimistic, because a sample that
        /// straddles the crop edge is as uninformative as one on it.
        public func resampled(count: Int = HairBoundary.sampleCount) -> [Point] {
            guard count > 0, contour.count > 1 else { return contour }
            guard contour.count > count else { return contour }

            var cumulative: [CGFloat] = [0]
            cumulative.reserveCapacity(contour.count + 1)
            var total: CGFloat = 0
            for i in 0..<contour.count {
                let a = contour[i].location
                let b = contour[(i + 1) % contour.count].location
                total += hypot(b.x - a.x, b.y - a.y)
                cumulative.append(total)
            }
            guard total > 0 else { return contour }

            var out: [Point] = []
            out.reserveCapacity(count)
            var segment = 0
            for k in 0..<count {
                let target = total * CGFloat(k) / CGFloat(count)
                while segment < contour.count - 1, cumulative[segment + 1] < target {
                    segment += 1
                }
                let a = contour[segment]
                let b = contour[(segment + 1) % contour.count]
                let span = cumulative[segment + 1] - cumulative[segment]
                let f = span > 0 ? (target - cumulative[segment]) / span : 0
                out.append(
                    Point(
                        location: CGPoint(
                            x: a.location.x + (b.location.x - a.location.x) * f,
                            y: a.location.y + (b.location.y - a.location.y) * f),
                        isClipped: a.isClipped || b.isClipped))
            }
            return out
        }
    }

    /// Traces the outer boundary of the largest connected hair region.
    ///
    /// `nil` when the mask has no pixel at or above ``coverageThreshold`` — a
    /// bald subject, a hat, or a parsing failure. ``HeadReshape`` turns that into
    /// "the head sliders do nothing", which is the honest answer: with no
    /// silhouette there is nothing to reshape.
    ///
    /// Three steps, all `O(mask)`:
    ///
    /// 1. threshold;
    /// 2. largest **4-connected** component (breadth-first, one visited bitmap) —
    ///    a stray blob of mis-parsed hair somewhere else in the crop must not
    ///    become a control point;
    /// 3. Moore-neighbour trace with Jacob's stopping criterion, from the
    ///    component's topmost-then-leftmost pixel, walking the 8-neighbourhood
    ///    clockwise.
    ///
    /// Step 3 returns the **outer** ring only: a hole inside the hair (a gap the
    /// parser left) is a separate contour and is not traced. That is deliberate —
    /// a hole is not part of the head's silhouette — and it is why the reference
    /// comparison uses row/column extremes rather than boundary-pixel set
    /// equality (a hole's boundary is in the set and not in the ring).
    public static func trace(_ mask: RenderMask) -> Outline? {
        let width = mask.width
        let height = mask.height
        guard width > 1, height > 1, mask.values.count == width * height else { return nil }

        var inside = [Bool](repeating: false, count: width * height)
        var maskPixels = 0
        for i in 0..<inside.count where mask.values[i] >= coverageThreshold {
            inside[i] = true
            maskPixels += 1
        }
        guard maskPixels > 0 else { return nil }

        guard let component = largestComponent(inside, width: width, height: height)
        else { return nil }

        let ring = mooreTrace(
            component.member, width: width, height: height, start: component.start)
        guard !ring.isEmpty else { return nil }

        let transform = mask.maskToImage
        let contour = ring.map { pixel -> Point in
            // Pixel centres, so a 1×1 mask pixel maps to the middle of its image
            // footprint rather than to its corner.
            let centre = CGPoint(x: CGFloat(pixel.x) + 0.5, y: CGFloat(pixel.y) + 0.5)
            let clipped =
                pixel.x == 0 || pixel.y == 0 || pixel.x == width - 1 || pixel.y == height - 1
            return Point(location: centre.applying(transform), isClipped: clipped)
        }
        return Outline(
            contour: contour, componentPixelCount: component.count,
            maskPixelCount: maskPixels,
            maskSize: CGSize(width: width, height: height))
    }

    // MARK: - Steps

    struct Pixel: Equatable {
        var x: Int
        var y: Int
    }

    /// The largest 4-connected component, as a membership bitmap plus the pixel a
    /// trace must start from (topmost row, then leftmost column — so the pixel to
    /// its left is guaranteed to be outside).
    static func largestComponent(_ inside: [Bool], width: Int, height: Int)
        -> (member: [Bool], count: Int, start: Pixel)?
    {
        var visited = [Bool](repeating: false, count: width * height)
        var best: [Int] = []
        var queue: [Int] = []
        for seed in 0..<inside.count where inside[seed] && !visited[seed] {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            visited[seed] = true
            var component: [Int] = []
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                component.append(index)
                let x = index % width
                let y = index / width
                if x > 0, inside[index - 1], !visited[index - 1] {
                    visited[index - 1] = true
                    queue.append(index - 1)
                }
                if x < width - 1, inside[index + 1], !visited[index + 1] {
                    visited[index + 1] = true
                    queue.append(index + 1)
                }
                if y > 0, inside[index - width], !visited[index - width] {
                    visited[index - width] = true
                    queue.append(index - width)
                }
                if y < height - 1, inside[index + width], !visited[index + width] {
                    visited[index + width] = true
                    queue.append(index + width)
                }
            }
            if component.count > best.count { best = component }
        }
        guard let first = best.min() else { return nil }
        var member = [Bool](repeating: false, count: width * height)
        for index in best { member[index] = true }
        // `best.min()` is the smallest row-major index, i.e. the topmost row and
        // then the leftmost column of that row.
        return (member, best.count, Pixel(x: first % width, y: first / width))
    }

    /// Clockwise 8-neighbourhood, starting west and turning through north.
    private static let neighbourOffsets: [(dx: Int, dy: Int)] = [
        (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1),
    ]

    /// Moore-neighbour tracing with Jacob's stopping criterion.
    ///
    /// Returns the boundary pixels of the component containing `start`, in ring
    /// order, without repeating the start pixel at the end. A one-pixel component
    /// returns just that pixel.
    static func mooreTrace(_ member: [Bool], width: Int, height: Int, start: Pixel) -> [Pixel] {
        func isMember(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return member[y * width + x]
        }
        guard isMember(start.x, start.y) else { return [] }

        // The start pixel is the topmost-leftmost of the component, so its west
        // neighbour is outside — which is the backtrack the algorithm needs.
        var contour: [Pixel] = [start]
        var current = start
        var backtrackDirection = 0  // index into neighbourOffsets: west
        let firstBacktrack = backtrackDirection
        // A Moore ring can revisit pixels, so the bound is generous but finite;
        // it exists so a malformed membership map cannot hang a render.
        let limit = 4 * member.count { $0 } + 8

        while contour.count < limit {
            var found = false
            for step in 1...8 {
                let direction = (backtrackDirection + step) % 8
                let offset = neighbourOffsets[direction]
                let nx = current.x + offset.dx
                let ny = current.y + offset.dy
                if isMember(nx, ny) {
                    // The backtrack for the next step is the neighbour we came
                    // from, i.e. the direction opposite to the one we moved in.
                    backtrackDirection = (direction + 4) % 8
                    current = Pixel(x: nx, y: ny)
                    found = true
                    break
                }
            }
            if !found { break }  // isolated pixel
            // Jacob's criterion: stop when the start pixel is re-entered from the
            // same direction it was first left in. Comparing positions alone ends
            // a figure-of-eight outline early.
            if current == start, backtrackDirection == firstBacktrack { break }
            if current == start, contour.count > 1, contour[1] == nextPixel(
                from: current, backtrack: backtrackDirection, member: member,
                width: width, height: height)
            {
                break
            }
            contour.append(current)
        }
        return contour
    }

    /// The pixel a trace at `current` with this backtrack would visit next —
    /// used only by the stopping criterion above.
    private static func nextPixel(
        from current: Pixel, backtrack: Int, member: [Bool], width: Int, height: Int
    ) -> Pixel? {
        for step in 1...8 {
            let offset = neighbourOffsets[(backtrack + step) % 8]
            let nx = current.x + offset.dx
            let ny = current.y + offset.dy
            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
            if member[ny * width + nx] { return Pixel(x: nx, y: ny) }
        }
        return nil
    }
}
