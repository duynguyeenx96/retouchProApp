import CoreGraphics
import Foundation
import RPCore

/// "Đầu" (head reshape) — docs/PLAN.md §6.2.
///
/// Three amounts, 0…100, default 0, living in `EditState.SectionKey.face`
/// beside the reshape ("Mặt") and contour ("Tạo khối") sliders, for the same
/// reason ``ContourSliders`` gives: this is a per-face effect whose every length
/// is a fraction of `faceWidth`, which is what makes the `face` section
/// transferable through a preset (docs/PLAN.md §2).
///
/// ## Why these three and not a copy of "Mặt"
/// §6.2 asks for one thing — *"warp cả khung đầu/viền tóc, không chỉ landmark
/// mặt"* — and the only new information this group has that "Mặt" does not is
/// the **hair silhouette**. So each slider here is something that cannot be
/// expressed by moving the 478-point mesh alone:
///
/// * ``size`` moves the whole head, hair included, which a mesh-only slider
///   cannot do without the hair sliding off the skull;
/// * ``width`` narrows the *skull* above the eye line, where the mesh has only
///   the thin arc of the face oval and no hair at all — "Bóp mặt" is the jaw and
///   below, "Thái dương" pushes the temples out;
/// * ``volume`` moves **only** the silhouette and pins the face, which is a
///   statement about two different regions and needs both to be handles.
///
/// Nothing here duplicates a "Mặt" slider, and the two groups compose rather
/// than fight: see ``HeadReshape/handles(landmarks:faceWidth:hair:face:head:)``.
///
/// No new `RPCore.Slider` key: `Slider.range(for:in:)` gives any parameter of a
/// non-bidirectional section `0...100`, which is what these want.
public struct HeadSliders: Sendable, Equatable {

    /// **Thu nhỏ đầu** — scales the whole head (face mesh, the expanded ring and
    /// the hair silhouette together) about a pivot below the chin, so the head
    /// gets smaller relative to the body and stays attached to the neck.
    ///
    /// One direction, like every other slider in the project: a *smaller* head
    /// is the retouch people ask for.
    public var size: Double = 0

    /// **Hẹp đầu** — narrows the skull laterally, at full weight above the eye
    /// line and fading to nothing at the cheek line, so the face itself is left
    /// to "Bóp mặt" / "Gò má" and this slider takes the cranium and the hair
    /// around it.
    public var width: Double = 0

    /// **Phồng tóc** — pushes the hair silhouette outward from the head's centre
    /// above the eye line. The face mesh is a **pure identity handle** for this
    /// slider, so the hair gains volume and the face does not grow — the same
    /// construction "Môi đầy" uses to thicken a lip without opening the mouth.
    public var volume: Double = 0

    public init(size: Double = 0, width: Double = 0, volume: Double = 0) {
        self.size = Self.clamp(size, Key.size)
        self.width = Self.clamp(width, Key.width)
        self.volume = Self.clamp(volume, Key.volume)
    }

    static func clamp(_ value: Double, _ key: String) -> Double {
        Slider.clamp(value, for: key, in: EditState.SectionKey.face)
    }

    /// Parameter names inside `EditState.SectionKey.face`. Prefixed `head…` so
    /// they cannot collide with ``FaceSliders/Key`` or ``ContourSliders/Key``,
    /// which share the section and mean something else.
    public enum Key {
        public static let size = "headSize"
        public static let width = "headWidth"
        public static let volume = "headVolume"
        public static let all: [String] = [size, width, volume]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.face]
        self.init(
            size: section.slider(Key.size), width: section.slider(Key.width),
            volume: section.slider(Key.volume))
    }

    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.face
        state.setSlider(Key.size, in: section, to: size)
        state.setSlider(Key.width, in: section, to: width)
        state.setSlider(Key.volume, in: section, to: volume)
    }

    /// Every value in declaration order — which is the order
    /// ``HeadReshape/Field`` accumulates displacements in, and therefore part of
    /// the contract (a sum of floats is not associative).
    public var values: [Double] { [size, width, volume] }

    /// `true` when this group cannot move a single point.
    public var isIdentity: Bool { values.allSatisfy { $0 == 0 } }

    /// Does any slider need the hair silhouette? All three do — see
    /// ``HeadReshape/silhouette(landmarks:faceWidth:hair:)`` for why "no hair, no
    /// head reshape" is the honest answer rather than a fallback.
    var needsSilhouette: Bool { !isIdentity }
}

/// Turns ``HeadSliders`` plus the 478-point mesh **plus the traced hair
/// boundary** into MLS handles, and composes them with the "Mặt" group's.
///
/// This is the same family as ``FaceReshape`` — identity handles plus a weighted
/// region, no new warp maths, no new model — and it is pure in exactly the same
/// way: value types in, value types out, no Metal, no state, testable without a
/// GPU. What is new is where the handles come from:
///
/// | source | count | role |
/// |---|---|---|
/// | the 478-point mesh (``FaceMesh/allHandleIndices``) | ~150 | the head's interior; identity handles for ``HeadSliders/volume`` |
/// | the expanded oval ring (``Silhouette/ring``) | ≤ 36 | the gap between the face oval and the hairline |
/// | the traced hair boundary (``HairBoundary``) | ≤ 96 | the silhouette itself |
///
/// docs/PLAN.md §6.2 prescribes exactly that combination: *"Dò biên ngoài của
/// mask tóc … làm control point MLS thêm, kết hợp mở rộng vòng oval mặt (478
/// điểm) ra ngoài theo tỉ lệ neo vào biên tóc đó."* The ring is the "expanded
/// oval anchored to the hair boundary": each usable oval landmark is pushed a
/// fixed **fraction of the way to the hairline along its own ray**, so it is
/// anchored to the measured silhouette rather than to a pixel constant, and it
/// carries an intermediate silhouette weight. Without it, ``HeadSliders/volume``
/// would step from 0 at the oval to 1 at the hairline across whatever gap the
/// hairstyle happens to leave, and MLS would shear that gap.
///
/// ## How this composes with "Mặt"
/// The two groups are solved as **one** handle set, because two warp passes mean
/// two full-frame resamples (``WarpRenderNode``'s own note). They cannot
/// contradict each other, because for a landmark both groups touch, the head
/// field is applied *on top of* the reshaped destination:
///
/// ```
/// destination(i) = FaceReshape.destination(i) + Field.displacement(at: landmarks[i])
/// ```
///
/// The head displacement is evaluated at the **undeformed** landmark, so the two
/// contributions stay independent and linear and the composition order does not
/// change the answer — the same reason ``FaceReshape`` accumulates its own
/// sliders rather than applying them in sequence.
///
/// ## Every magnitude is relative to the face
/// ``sizeGain`` and ``widthGain`` are dimensionless gains on landmark-derived
/// distances; ``volumeFraction`` is a fraction of `faceWidth`; the pivot, the
/// crown centre and the ring are all built from the mesh and the traced boundary.
/// So `f(k · geometry) == k · f(geometry)` exactly, which is what lets a preset
/// move between images and between a 2048 px preview and a 24 MP export
/// (`HeadReshapeTests.headDisplacementsScaleWithTheFace`).
///
/// ## The magnitudes are not tuned
/// Like ``FaceReshape``'s, the constants below are plausible retouch amounts and
/// **nothing has measured what looks right** — that needs a human comparing
/// renders. What is measured is that they behave: the geometry, the round-trip
/// error of the solved lattice and the cost are in
/// `Research/bench/p6-head-reshape-*.json`, and the trace those numbers rest on
/// is checked against an independent NumPy implementation
/// (`Research/bench/hair-boundary-reference.py`).
public enum HeadReshape {

    // MARK: - Magnitudes at slider = 100

    /// Thu nhỏ đầu: the head scales by `1 − sizeGain` about ``pivotT``.
    ///
    /// 8 % is a large edit for a head — it moves the crown of a 200 px-wide face
    /// by ~20 px — and is deliberately at the top of the plausible range so the
    /// bench's worst case is a worst case.
    public static let sizeGain: CGFloat = 0.08
    /// Hẹp đầu: the skull's lateral offset shrinks by this fraction.
    public static let widthGain: CGFloat = 0.08
    /// Phồng tóc: the silhouette moves out by this fraction of face width.
    public static let volumeFraction: CGFloat = 0.06

    // MARK: - Where the head's own frame sits
    //
    // Both anchors are landmark-derived levels on the face axis, never pixel
    // constants and never derived from the hair mask — a mask that is cut by the
    // parsing crop (measured: 10 of the 11 a6300 frames) would otherwise move
    // the pivot, and a slider whose pivot depends on how much hair the crop
    // caught is not a slider.

    /// The scale pivot, in units of `t` (0 at the forehead centre, 1 at the
    /// chin). 1.25 is a quarter of a face length below the chin — roughly the
    /// base of the neck, so shrinking the head does not detach it from the body
    /// and the displacement falls to 0 there instead of at the jaw.
    public static let pivotT: CGFloat = 1.25
    /// The centre ``HeadSliders/volume`` expands away from, in units of `t`. The
    /// eye line: the hair is above and around it, so the push lifts the crown and
    /// widens the sides rather than dragging the silhouette down the face.
    public static let crownCentreT: CGFloat = 0.30

    /// ``HeadSliders/width`` is at full weight at or above the eye line and 0 at
    /// or below the cheek line — where "Gò má" and "Bóp mặt" take over. The two
    /// bands do not overlap, so "Đầu" cannot quietly re-slim a face.
    static func widthWeight(t: CGFloat, frame: FaceMeshFrame) -> CGFloat {
        1 - FaceMeshFrame.ramp(t, from: frame.tEyeLine, to: frame.tCheekLine)
    }

    /// ``HeadSliders/volume`` is at full weight at or above the forehead centre
    /// (`t = 0`, where the crown is) and 0 at the eye line, so hair on the
    /// shoulders is not inflated with the top of the head.
    static func volumeWeight(t: CGFloat, frame: FaceMeshFrame) -> CGFloat {
        1 - FaceMeshFrame.ramp(t, from: 0, to: frame.tEyeLine)
    }

    // MARK: - The expanded ring

    /// How far along the ray from the crown centre to the hairline the expanded
    /// ring sits: half way. Its silhouette weight is the same number, so
    /// ``HeadSliders/volume`` ramps 0 → ½ → 1 from the face to the hairline
    /// instead of stepping.
    public static let ringFraction: CGFloat = 0.5
    /// A ray whose hairline hit is further than this many face widths from the
    /// oval landmark is discarded: on a long hairstyle a ray cast past the jaw
    /// leaves the head entirely and lands on hair hanging over a shoulder, which
    /// is not the local hairline and must not become a ring point.
    public static let maxRingSpanFraction: CGFloat = 0.9

    /// Head-added handles (ring and hair) closer than this many face widths to a
    /// face-mesh handle are dropped.
    ///
    /// Two handles a couple of pixels apart with different destinations is an
    /// ill-conditioned MLS solve *and* a visible shear, and at the hairline that
    /// is exactly the configuration ``HeadSliders/volume`` creates: the mesh
    /// point does not move and the silhouette point moves by the full amount. So
    /// the silhouette gives way at the hairline, which is also the right picture
    /// — hair volume grows at the crown, not out of the forehead. A taste
    /// parameter, stated rather than hidden (ADR-0007 flags `alpha` the same way).
    public static let minSeparationFraction: CGFloat = 0.05

    /// Identity handles per image edge — the same mandatory border pinning
    /// ``FaceReshape/borderAnchorsPerEdge`` documents (ADR-0007).
    public static let borderAnchorsPerEdge = FaceReshape.borderAnchorsPerEdge

    // MARK: - Output

    /// Where a handle came from, which is what decides how much of
    /// ``HeadSliders/volume`` it takes.
    public enum Role: Sendable, Equatable {
        /// A point of the 478-point mesh. Silhouette weight 0.
        case faceMesh
        /// A point of the expanded oval ring. Silhouette weight ``ringFraction``.
        case expandedRing
        /// A traced, unclipped hair-boundary point. Silhouette weight 1.
        case hairBoundary

        public var silhouetteWeight: CGFloat {
            switch self {
            case .faceMesh: 0
            case .expandedRing: ringFraction
            case .hairBoundary: 1
            }
        }
    }

    /// One handle of the combined (face + head) solve.
    public struct Handle: Sendable, Equatable {
        /// Index into the 478-point mesh, or `nil` for a ring / hair point.
        public var index: Int?
        public var source: CGPoint
        public var destination: CGPoint
        public var role: Role

        public var displacement: CGFloat {
            hypot(destination.x - source.x, destination.y - source.y)
        }
    }

    /// The hair silhouette as this group uses it.
    public struct Silhouette: Sendable {
        /// The raw trace, for a bench that wants the counts.
        public var outline: HairBoundary.Outline
        /// Resampled boundary points that are **not** clipped by the parsing
        /// crop. Clipped points carry no silhouette information, so they neither
        /// move nor pin (``HairBoundary/Point/isClipped``).
        public var hair: [CGPoint]
        /// The full resampled ring, clipped points included, as a closed polygon
        /// — needed to cast the ring's rays even where the outline is cut.
        public var polygon: [HairBoundary.Point]
        /// The expanded oval ring, in ``FaceMesh/faceOval`` order.
        public var ring: [CGPoint]
        /// How many resampled points sat on the crop edge.
        public var clippedCount: Int
    }

    /// The handles for a whole render, plus the numbers a bench or a diagnostic
    /// wants without recomputing them.
    public struct Built: Sendable {
        /// Face + head handles **and** the border anchors, ready for `MLSMeshWarp`.
        public var control: MLSDeformation.ControlPoints
        /// Everything except the border anchors, in emission order.
        public var handles: [Handle]
        /// Largest displacement over all handles, in pixels.
        public var maxDisplacement: CGFloat
        /// How many handles actually moved.
        public var movedHandleCount: Int
        public var borderAnchorCount: Int
        /// Handles by role, for the bench.
        public var faceMeshHandleCount: Int
        public var ringHandleCount: Int
        public var hairHandleCount: Int
        /// Resampled hair points dropped because the parsing crop cut them.
        public var clippedPointCount: Int
        /// Ring and hair points dropped for sitting on top of a mesh handle
        /// (``minSeparationFraction``).
        public var crowdedPointCount: Int
    }

    // MARK: - The displacement field

    /// The head transform as a pure function of position and role.
    ///
    /// Everything the three sliders do is in ``displacement(at:silhouetteWeight:)``,
    /// so the same field is applied to a mesh landmark, a ring point and a hair
    /// point — the only difference between them is the silhouette weight. That is
    /// what makes "the face is an identity handle for volume" a property of the
    /// data rather than of a special case in the code.
    public struct Field: Sendable {
        public var frame: FaceMeshFrame
        /// `s − 1` for the size scale: 0 when the slider is 0, negative when it
        /// shrinks the head.
        public var sizeDelta: CGFloat
        public var widthAmount: CGFloat
        /// Pixels of outward push at full weight.
        public var volumeAmount: CGFloat
        public var pivot: CGPoint
        public var crownCentre: CGPoint

        public var isIdentity: Bool {
            sizeDelta == 0 && widthAmount == 0 && volumeAmount == 0
        }

        /// Accumulated in ``HeadSliders/values``' declaration order: size, then
        /// width, then volume.
        public func displacement(at point: CGPoint, silhouetteWeight: CGFloat) -> CGVector {
            var dx: CGFloat = 0
            var dy: CGFloat = 0

            if sizeDelta != 0 {
                dx += sizeDelta * (point.x - pivot.x)
                dy += sizeDelta * (point.y - pivot.y)
            }

            if widthAmount > 0 {
                let weight = widthWeight(t: frame.t(point), frame: frame)
                if weight > 0 {
                    let u = frame.u(point)
                    // `distance` is proportional to |u|, so a point on the
                    // midline does not move and no `lateralWeight` guard is
                    // needed (unlike "Bóp mặt", whose amount is constant across
                    // the face).
                    let vector = frame.towardMidline(
                        u: u, distance: abs(u) * widthAmount * weight)
                    dx += vector.dx
                    dy += vector.dy
                }
            }

            if volumeAmount > 0, silhouetteWeight > 0 {
                let weight = volumeWeight(t: frame.t(point), frame: frame)
                if weight > 0 {
                    let rx = point.x - crownCentre.x
                    let ry = point.y - crownCentre.y
                    let radius = hypot(rx, ry)
                    if radius > 0 {
                        let amount = volumeAmount * weight * silhouetteWeight
                        dx += rx / radius * amount
                        dy += ry / radius * amount
                    }
                }
            }

            return CGVector(dx: dx, dy: dy)
        }
    }

    /// The field for one face, or `nil` when the sliders are all 0 or the mesh is
    /// unusable.
    public static func field(landmarks: [CGPoint], faceWidth: CGFloat, sliders: HeadSliders)
        -> Field?
    {
        guard !sliders.isIdentity,
            let frame = FaceMeshFrame(landmarks: landmarks, faceWidth: faceWidth)
        else { return nil }
        return Field(
            frame: frame,
            sizeDelta: -CGFloat(sliders.size / 100) * sizeGain,
            widthAmount: CGFloat(sliders.width / 100) * widthGain,
            volumeAmount: CGFloat(sliders.volume / 100) * volumeFraction * frame.width,
            pivot: axisPoint(frame, t: pivotT),
            crownCentre: axisPoint(frame, t: crownCentreT))
    }

    /// A point `t` of the way down the face axis, on the midline.
    static func axisPoint(_ frame: FaceMeshFrame, t: CGFloat) -> CGPoint {
        CGPoint(
            x: frame.origin.x + frame.down.dx * t * frame.length,
            y: frame.origin.y + frame.down.dy * t * frame.length)
    }

    // MARK: - The silhouette

    /// Memoises the traced silhouette, because the trace is by far the most
    /// expensive thing this group does and a slider drag repeats it for nothing.
    ///
    /// Measured on an M1 Pro, Release, one 512² hair mask
    /// (`Research/bench/p6-head-reshape-macos.json`): the trace is **1.37 ms**
    /// and the whole handle build **1.46 ms**, against a 2048 px preview render
    /// of **0.83 ms**. Dragging a head slider changes the sliders and nothing
    /// else — the mask and the mesh are fixed for the shot — so without this the
    /// group would spend nearly twice the render, every frame, recomputing an
    /// identical answer. With it: **0.036 ms**.
    ///
    /// ## Why the key is the mask **by value**
    /// A cache that serves a stale silhouette is worse than no cache: it would
    /// warp the current photo with the previous photo's hairline. So the key is
    /// full value equality of the inputs — `RenderMask` is `Equatable` and its
    /// `values` comparison is a `memcmp` of 262 kB, ~20 µs, three orders of
    /// magnitude below the trace it replaces. No hash, no identity token, no
    /// buffer address: nothing that can collide.
    ///
    /// **Not internally synchronised.** The owner (``WarpRenderNode``) holds its
    /// own lock across the call; the class is `@unchecked Sendable` on that
    /// basis, the same contract `MLSMeshWarp`'s resources have.
    public final class SilhouetteCache: @unchecked Sendable {
        private struct Entry {
            var landmarks: [CGPoint]
            var faceWidth: CGFloat
            var hair: RenderMask?
            /// `nil` is cached too: "this mask has no usable silhouette" is an
            /// expensive answer to recompute as well.
            var silhouette: Silhouette?
        }

        /// Two faces is the common crowd for a portrait; four is a cheap ceiling
        /// (each entry holds one 512² mask by reference-counted buffer, not a
        /// copy, so the cost is the `Silhouette`'s few hundred points).
        public static let capacity = 4

        private var entries: [Entry] = []
        /// How many traces this cache has actually performed. Read by
        /// `HeadReshapeRenderTests.theSilhouetteIsTracedOncePerMask`.
        public private(set) var traceCount = 0

        public init() {}

        public func clear() {
            entries.removeAll()
        }

        func silhouette(landmarks: [CGPoint], faceWidth: CGFloat, hair: RenderMask?)
            -> Silhouette?
        {
            for entry in entries
            where entry.faceWidth == faceWidth && entry.hair == hair
                && entry.landmarks == landmarks
            {
                return entry.silhouette
            }
            traceCount += 1
            let made = HeadReshape.silhouette(
                landmarks: landmarks, faceWidth: faceWidth, hair: hair)
            entries.append(
                Entry(
                    landmarks: landmarks, faceWidth: faceWidth, hair: hair, silhouette: made))
            if entries.count > Self.capacity { entries.removeFirst() }
            return made
        }
    }

    /// Traces the hair mask and builds the expanded oval ring from it.
    ///
    /// `nil` when there is no hair mask, when nothing in it reaches
    /// ``HairBoundary/coverageThreshold`` (a bald subject, a hat — the BiSeNet
    /// `hat` class is *not* folded into `hair`, spike S2 — or a parsing failure),
    /// or when the mesh is unusable.
    ///
    /// The caller turns `nil` into "the head sliders do nothing", which is the
    /// honest answer and not a fallback: with no silhouette the only thing left
    /// to warp is the face, and warping the face inside hair that stays put is
    /// visibly worse than doing nothing. It is also a **measured** case rather
    /// than a hypothetical one — see docs/ADR-0022 for how often it fires.
    public static func silhouette(landmarks: [CGPoint], faceWidth: CGFloat, hair: RenderMask?)
        -> Silhouette?
    {
        guard let hair, let frame = FaceMeshFrame(landmarks: landmarks, faceWidth: faceWidth),
            let outline = HairBoundary.trace(hair)
        else { return nil }

        let polygon = outline.resampled()
        guard polygon.count > 2 else { return nil }
        let usable = polygon.filter { !$0.isClipped }.map(\.location)
        let clipped = polygon.count - usable.count

        let centre = axisPoint(frame, t: crownCentreT)
        var ring: [CGPoint] = []
        ring.reserveCapacity(FaceMesh.faceOval.count)
        let maxSpan = maxRingSpanFraction * frame.width
        for index in FaceMesh.faceOval {
            let point = landmarks[index]
            // Only the part of the oval hair can surround: the forehead, the
            // temples and the upper cheeks. Below the cheek line a ray from the
            // crown centre leaves the head.
            guard frame.t(point) <= frame.tCheekLine else { continue }
            guard let hit = hairlineHit(from: centre, through: point, polygon: polygon)
            else { continue }
            let span = hypot(hit.x - point.x, hit.y - point.y)
            guard span > 0, span <= maxSpan else { continue }
            ring.append(
                CGPoint(
                    x: point.x + (hit.x - point.x) * ringFraction,
                    y: point.y + (hit.y - point.y) * ringFraction))
        }

        return Silhouette(
            outline: outline, hair: usable, polygon: polygon, ring: ring,
            clippedCount: clipped)
    }

    /// Where the ray from `centre` through `point` first crosses the hair
    /// polygon **beyond** `point`, or `nil`.
    ///
    /// A segment with a clipped endpoint is skipped: the polygon there is the
    /// edge of the parsing crop, not a hairline, and anchoring a ring point to it
    /// would anchor it to the crop.
    static func hairlineHit(from centre: CGPoint, through point: CGPoint,
        polygon: [HairBoundary.Point]) -> CGPoint?
    {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        guard dx != 0 || dy != 0 else { return nil }

        var best: CGFloat = .greatestFiniteMagnitude
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if a.isClipped || b.isClipped { continue }
            let ex = b.location.x - a.location.x
            let ey = b.location.y - a.location.y
            let denominator = dx * ey - dy * ex
            guard abs(denominator) > 1e-12 else { continue }
            let ax = a.location.x - centre.x
            let ay = a.location.y - centre.y
            // centre + s·d == a + r·e
            let s = (ax * ey - ay * ex) / denominator
            let r = (ax * dy - ay * dx) / denominator
            guard r >= 0, r <= 1, s > 1 else { continue }
            best = min(best, s)
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        return CGPoint(x: centre.x + dx * best, y: centre.y + dy * best)
    }

    // MARK: - Handles

    /// The combined handle list for one face: the "Mặt" group's landmarks with
    /// the head field applied on top, plus the ring and the silhouette.
    ///
    /// Emission order is fixed — mesh handles by ascending index, then ring
    /// points in ``FaceMesh/faceOval`` order, then hair points in ring order — so
    /// one `EditState` gives one mesh, exactly as ``FaceReshape`` guarantees for
    /// its own group.
    ///
    /// Falls back to ``FaceReshape/handles(landmarks:faceWidth:sliders:)`` (as
    /// `.faceMesh` handles) when the head sliders are at 0 or there is no
    /// silhouette, so this function is a strict superset of the "Mặt" group and
    /// the Phase 2 numbers are reproduced exactly, not approximately.
    public static func handles(
        landmarks: [CGPoint], faceWidth: CGFloat, hair: RenderMask?,
        face: FaceSliders, head: HeadSliders, cache: SilhouetteCache? = nil
    ) -> [Handle] {
        build(
            landmarks: landmarks, faceWidth: faceWidth, hair: hair, face: face, head: head,
            cache: cache
        ).handles
    }

    /// Every index the head field touches, deduplicated and sorted once.
    static let headHandleIndices: [Int] = Set(FaceMesh.allHandleIndices).sorted()

    /// ``handles(landmarks:faceWidth:hair:face:head:)`` plus the silhouette it
    /// used, so a caller that wants both does not trace the mask twice.
    static func build(
        landmarks: [CGPoint], faceWidth: CGFloat, hair: RenderMask?,
        face: FaceSliders, head: HeadSliders, cache: SilhouetteCache? = nil
    ) -> (handles: [Handle], silhouette: Silhouette?) {
        let faceHandles = FaceReshape.handles(
            landmarks: landmarks, faceWidth: faceWidth, sliders: face)

        guard let field = field(landmarks: landmarks, faceWidth: faceWidth, sliders: head),
            let silhouette = cache.map({
                $0.silhouette(landmarks: landmarks, faceWidth: faceWidth, hair: hair)
            }) ?? silhouette(landmarks: landmarks, faceWidth: faceWidth, hair: hair)
        else {
            return (
                faceHandles.map {
                    Handle(
                        index: $0.index, source: $0.source, destination: $0.destination,
                        role: .faceMesh)
                }, nil
            )
        }

        var reshaped: [Int: CGPoint] = [:]
        reshaped.reserveCapacity(faceHandles.count)
        for handle in faceHandles { reshaped[handle.index] = handle.destination }

        var out: [Handle] = []
        out.reserveCapacity(FaceMesh.allHandleIndices.count + silhouette.ring.count + 96)

        // 1. Every point of the mesh any slider can touch. Those the head field
        //    leaves alone become identity handles, which is what pins the face
        //    while the silhouette moves.
        for index in headHandleIndices {
            let source = landmarks[index]
            let base = reshaped[index] ?? source
            let delta = field.displacement(at: source, silhouetteWeight: 0)
            out.append(
                Handle(
                    index: index, source: source,
                    destination: CGPoint(x: base.x + delta.dx, y: base.y + delta.dy),
                    role: .faceMesh))
        }

        // 2. The ring, then the silhouette — dropped where they crowd a mesh
        //    handle (``minSeparationFraction``).
        let meshPoints = out.map(\.source)
        let minimum = minSeparationFraction * faceWidth
        func add(_ point: CGPoint, _ role: Role) {
            for other in meshPoints
            where hypot(point.x - other.x, point.y - other.y) < minimum { return }
            let delta = field.displacement(at: point, silhouetteWeight: role.silhouetteWeight)
            out.append(
                Handle(
                    index: nil, source: point,
                    destination: CGPoint(x: point.x + delta.dx, y: point.y + delta.dy),
                    role: role))
        }
        for point in silhouette.ring { add(point, .expandedRing) }
        for point in silhouette.hair { add(point, .hairBoundary) }

        return (out, silhouette)
    }

    /// Handles for every face in a request, plus the mandatory border anchors.
    ///
    /// `nil` when nothing would move — which the node turns into an exact copy,
    /// so "slider at 0", "no hair mask" and "a face the mesh could not describe"
    /// all leave the picture bit-exact rather than resampling it.
    public static func controlPoints(
        faces: [FaceRenderInput], face: FaceSliders, head: HeadSliders, imageSize: CGSize,
        cache: SilhouetteCache? = nil
    ) -> Built? {
        guard !(face.isIdentity && head.isIdentity), imageSize.width > 0, imageSize.height > 0
        else { return nil }

        var handles: [Handle] = []
        var clipped = 0
        var crowded = 0
        for input in faces {
            let built = build(
                landmarks: input.landmarks, faceWidth: input.faceWidth,
                hair: input.masks[.hair], face: face, head: head, cache: cache)
            if let silhouette = built.silhouette {
                clipped += silhouette.clippedCount
                let added = built.handles.count { $0.role != .faceMesh }
                crowded += silhouette.ring.count + silhouette.hair.count - added
            }
            handles += built.handles
        }
        guard !handles.isEmpty else { return nil }

        var maxDisplacement: CGFloat = 0
        var moved = 0
        for handle in handles {
            let d = handle.displacement
            if d > 0 { moved += 1 }
            maxDisplacement = max(maxDisplacement, d)
        }
        guard maxDisplacement > 0 else { return nil }

        let control = MLSDeformation.ControlPoints(
            source: handles.map(\.source), destination: handles.map(\.destination)
        ).pinningBorder(
            width: Double(imageSize.width), height: Double(imageSize.height),
            perEdge: borderAnchorsPerEdge)

        return Built(
            control: control, handles: handles, maxDisplacement: maxDisplacement,
            movedHandleCount: moved, borderAnchorCount: control.count - handles.count,
            faceMeshHandleCount: handles.count { $0.role == .faceMesh },
            ringHandleCount: handles.count { $0.role == .expandedRing },
            hairHandleCount: handles.count { $0.role == .hairBoundary },
            clippedPointCount: clipped, crowdedPointCount: crowded)
    }
}
