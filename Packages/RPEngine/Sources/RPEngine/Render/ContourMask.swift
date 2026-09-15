import CoreGraphics
import Foundation
import RPCore

/// "Tạo khối" (Contour) — docs/PLAN.md §6.2.
///
/// Three amounts, 0…100, default 0, living in `EditState.SectionKey.face`
/// alongside the reshape sliders: contour is a *per-face* effect whose every
/// length is a fraction of `faceWidth`, which is exactly the property that makes
/// the "Mặt" section transferable through a preset (docs/PLAN.md §2). They are
/// **not** in the `color` section even though the kernel that applies them is the
/// colour composite — the `color` section is bidirectional (docs/ADR-0016) and
/// none of these three has a meaningful negative half (see ``isIdentity``'s
/// neighbours below).
///
/// No new key had to be added to `RPCore.Slider`: `Slider.range(for:in:)` gives
/// any parameter of a non-bidirectional section `0...100`, which is what these
/// want, so this group introduces **no RPCore change at all**.
public struct ContourSliders: Sendable, Equatable {
    /// **Gò má** — a highlight on the cheekbone under the eye and a shadow in the
    /// hollow below it, one pair per side of the face.
    public var cheek: Double = 0
    /// **Sống mũi** — a narrow highlight along the nose bridge, from the nasion
    /// to the nose tip.
    public var nose: Double = 0
    /// **Hàm** — a shadow band just inside the jaw line of the face oval.
    public var jaw: Double = 0

    public init(cheek: Double = 0, nose: Double = 0, jaw: Double = 0) {
        self.cheek = Self.clamp(cheek, Key.cheek)
        self.nose = Self.clamp(nose, Key.nose)
        self.jaw = Self.clamp(jaw, Key.jaw)
    }

    static func clamp(_ value: Double, _ key: String) -> Double {
        Slider.clamp(value, for: key, in: EditState.SectionKey.face)
    }

    /// Parameter names inside `EditState.SectionKey.face`. Prefixed `contour…` so
    /// they cannot collide with ``FaceSliders/Key`` (`cheekbone`, `jaw`, `chin`,
    /// …), which is the reshape group and means something else entirely.
    public enum Key {
        public static let cheek = "contourCheek"
        public static let nose = "contourNose"
        public static let jaw = "contourJaw"
        public static let all: [String] = [cheek, nose, jaw]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.face]
        self.init(
            cheek: section.slider(Key.cheek), nose: section.slider(Key.nose),
            jaw: section.slider(Key.jaw))
    }

    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.face
        state.setSlider(Key.cheek, in: section, to: cheek)
        state.setSlider(Key.nose, in: section, to: nose)
        state.setSlider(Key.jaw, in: section, to: jaw)
    }

    /// `true` when this group cannot change a single pixel.
    public var isIdentity: Bool { cheek == 0 && nose == 0 && jaw == 0 }
}

/// One soft ellipse of the contour mask, in **image pixels**.
///
/// Field order and padding must match `ContourLobe` in `ColorShaders.metal`
/// exactly (`ContourRenderTests.lobeStructMatchesShaderLayout` pins the stride).
///
/// The mask value at a point `p` is
///
/// ```
/// a  = dot(p − centre,  axisU) / halfExtent.x
/// b  = dot(p − centre,  axisV) / halfExtent.y      // axisV = perp(axisU)
/// r² = a² + b²
/// w  = r² < 1 ? 1 − smoothstep(0, 1, √r²) : 0      // 1 at the centre, 0 at the rim
/// m += strength · w
/// ```
///
/// summed over every lobe **in array order** and then clamped to −1…1. The
/// falloff is `1 − (3r² − 2r³)`, which is C¹ at both ends, so two lobes that
/// overlap blend instead of meeting at a crease and a lobe's rim cannot show as
/// an edge.
struct ContourLobe: Sendable, Equatable {
    /// Ellipse centre, image pixels.
    var centre: SIMD2<Float>
    /// Unit vector along the ellipse's long axis. The short axis is its
    /// perpendicular `(−y, x)`, so only one vector is uploaded.
    var axisU: SIMD2<Float>
    /// Half-lengths along `axisU` and along its perpendicular, in pixels. Both
    /// are computed as fractions of `faceWidth`, never as pixel constants.
    var halfExtent: SIMD2<Float>
    /// Signed peak amplitude. **Positive dodges** (highlight: the cheekbone, the
    /// nose bridge), **negative burns** (shadow: the cheek hollow, the jaw), and
    /// the magnitude is the mask value at the lobe's centre.
    var strength: Float
    /// Padding to the 8-byte alignment `SIMD2<Float>` imposes. Explicit so the
    /// Swift and Metal layouts are written the same way rather than both relying
    /// on a compiler's tail padding.
    var pad: Float = 0
}

/// Builds the contour mask's lobes from landmarks the project **already**
/// computes, and evaluates that mask on the CPU.
///
/// ## What this is, and what it deliberately is not
/// docs/PLAN.md §6.2 fixes the shape of this work: *"vài mask ellipse/radial mềm
/// neo tại index landmark 478 điểm sẵn có … rồi nhân mask đó vào đúng công thức
/// dodge/burn LUT đã có. Không landmark mới, không model mới, không kernel Metal
/// họ mới."* So:
///
/// * **No new landmarks.** Every anchor is a `FaceMeshFrame` level
///   (`tEyeLine`, `tCheekLine`, `tMouthLine`, `tNasion`, `tNoseTip`) or a point of
///   ``FaceMesh/faceOval`` — all of which `FaceReshape` already computes for the
///   "Mặt" group.
/// * **No new Core ML model**, and no new mask *source*: nothing here reads
///   `FaceRenderInput.masks`, so the group works on a face whose parsing mask is
///   missing.
/// * **No new kernel family.** The lobes are evaluated inside the existing
///   `rp_color_composite`, and what they gate is the existing dodge/burn LUT
///   step — the same `kRPDodgeGamma` / `kRPBurnGamma` mix "Auto D&B" uses. A
///   contour render is that step with the mask supplying the weight and the
///   direction, where Auto D&B has the frame's own local luminance error supply
///   both. That is the "mask multiply" of ADR-0009's `MaskRasteriser` pattern,
///   applied to a Color-stage effect; it is analytic rather than rasterised
///   because the mask is an ellipse, and uploading 24 MB of `r8Unorm` to store
///   eleven ellipses would be the expensive way to say the same thing.
///
/// ## Every constant here is untuned
/// The positions, the half-extents, the tilts and the four peak strengths are
/// argued from where the anatomy is (a cheekbone highlight sits under the eye and
/// outboard of the nose; a jaw shadow sits just inside the oval) and are **not
/// tuned against a retoucher's eye** — the same disclosure the "Mặt"
/// (docs/ADR-0010), "Mắt / Răng" (docs/ADR-0011) and "Color" (docs/ADR-0012)
/// groups make. What is measured is that the GPU computes the documented mask,
/// that the mask covers the region its slider is named after, and that it changes
/// an unrelated region by **exactly** zero.
enum ContourMask {
    // MARK: - Budget

    /// Lobes per face: 2 cheek highlights + 2 cheek shadows + 1 nose bridge +
    /// 6 jaw segments.
    static let lobesPerFace = 11
    /// Hard cap on the uploaded buffer. The kernel loops over every lobe for
    /// every pixel, so this is a cost ceiling and not just an allocation one:
    /// 128 lobes is ~11 faces, and a frame with twelve faces in it is not a
    /// portrait retouch.
    static let maxLobes = 128

    // MARK: - Geometry constants (fractions of faceWidth, or of a `t` span)

    /// Cheekbone highlight, as a fraction of the eye-line → cheek-line span.
    static let cheekHighlightT = 0.62
    /// …and how far out toward that side's cheek extreme it sits.
    static let cheekHighlightU = 0.58
    /// Cheek hollow shadow, as a fraction of the cheek-line → mouth-line span.
    static let cheekShadowT = 0.34
    static let cheekShadowU = 0.76
    /// Half-extents, × faceWidth: (along the lobe's own axis, across it).
    static let cheekHighlightHalf = (along: 0.26, across: 0.11)
    static let cheekShadowHalf = (along: 0.24, across: 0.085)
    /// Tilt of the cheek lobes away from the face's lateral axis, degrees —
    /// outboard **and up**, which is the direction a cheekbone runs.
    static let cheekHighlightTilt = 18.0
    static let cheekShadowTilt = 26.0
    /// Nose bridge highlight: half its length is this fraction of the
    /// nasion → nose-tip span, and its half-width is this fraction of faceWidth.
    /// 0.055 is inside the 0.068 × faceWidth that `FaceMesh.noseBridge`'s own
    /// doc comment reports as the measured spread of the bridge points about the
    /// midline, so the highlight cannot spill onto an eye.
    static let noseHalfLength = 0.62
    static let noseHalfWidth = 0.055
    /// Jaw: each side's nine oval points are taken in three groups of three; a
    /// segment's half-length is half its group's span plus this overlap, so the
    /// three lobes form a continuous band rather than three beads.
    static let jawOverlap = 0.05
    static let jawHalfWidth = 0.055
    /// How far inside the oval the jaw shadow sits, × faceWidth. A contour on the
    /// oval line itself would darken the background half of its own falloff.
    static let jawInset = 0.03

    /// Peak mask amplitude at slider 100, per region. Below 1 on purpose: 1 is
    /// the full `pow(c, 0.8091)` / `pow(c, 1.2199)` LUT step, which on mid-grey
    /// is +0.07 / −0.06 — plenty for a whole cheek.
    static let cheekHighlightStrength = 0.55
    static let cheekShadowStrength = 0.65
    static let noseStrength = 0.50
    static let jawStrength = 0.60

    // MARK: - Index lists (from FaceMesh.faceOval, cheek → chin on both sides)

    /// The subject's left jaw: the run of ``FaceMesh/faceOval`` between the cheek
    /// extreme (454) and the chin (152), exclusive of both.
    static let jawLeft: [Int] = [323, 361, 288, 397, 365, 379, 378, 400, 377]
    /// The subject's right jaw, **reversed** out of the ring's order so it also
    /// runs cheek → chin and the two sides group identically.
    static let jawRight: [Int] = [93, 132, 58, 172, 136, 150, 149, 176, 148]

    // MARK: - Building

    /// Every lobe for every face, in face order then region order.
    ///
    /// Returns an empty array when the group is at its default, when no face has
    /// a usable mesh (`FaceMeshFrame` returns `nil` for a short or degenerate
    /// one), or when the caller passed no faces — in which case the node skips
    /// the whole contour branch and the render is bit-exact what it was before
    /// this group existed.
    static func lobes(faces: [FaceRenderInput], sliders: ContourSliders) -> [ContourLobe] {
        guard !sliders.isIdentity else { return [] }
        var out: [ContourLobe] = []
        out.reserveCapacity(min(maxLobes, faces.count * lobesPerFace))
        for face in faces {
            guard out.count + lobesPerFace <= maxLobes else { break }
            guard let frame = FaceMeshFrame(landmarks: face.landmarks, faceWidth: face.faceWidth)
            else { continue }
            out.append(contentsOf: lobes(frame: frame, landmarks: face.landmarks, sliders: sliders))
        }
        return out
    }

    /// One face's lobes. Split out so a test can build them from a frame without
    /// going through `FaceRenderInput`.
    static func lobes(frame: FaceMeshFrame, landmarks: [CGPoint], sliders: ContourSliders)
        -> [ContourLobe]
    {
        var out: [ContourLobe] = []
        let w = frame.width

        /// A point at `t` down the face axis and `u` pixels off the midline.
        func point(t: CGFloat, u: CGFloat) -> CGPoint {
            CGPoint(
                x: frame.origin.x + frame.down.dx * (t * frame.length) + frame.lateral.dx * u,
                y: frame.origin.y + frame.down.dy * (t * frame.length) + frame.lateral.dy * u)
        }
        /// A unit vector `tilt` degrees up from the lateral axis, on `side`
        /// (+1 = the subject's left). `down` and `lateral` are orthonormal, so
        /// this is already unit length.
        func axis(tilt: Double, side: CGFloat) -> CGVector {
            let c = CGFloat(cos(tilt * .pi / 180))
            let s = CGFloat(sin(tilt * .pi / 180))
            return CGVector(
                dx: side * frame.lateral.dx * c - frame.down.dx * s,
                dy: side * frame.lateral.dy * c - frame.down.dy * s)
        }
        func lobe(
            centre: CGPoint, axis: CGVector, halfAlong: CGFloat, halfAcross: CGFloat,
            strength: Double
        ) -> ContourLobe {
            ContourLobe(
                centre: SIMD2<Float>(Float(centre.x), Float(centre.y)),
                axisU: SIMD2<Float>(Float(axis.dx), Float(axis.dy)),
                halfExtent: SIMD2<Float>(Float(halfAlong), Float(halfAcross)),
                strength: Float(strength))
        }

        // --- Cheeks: a highlight on the bone, a shadow in the hollow below it.
        if sliders.cheek > 0 {
            let amount = sliders.cheek / 100
            for side in [CGFloat(1), CGFloat(-1)] {
                let extreme =
                    side > 0
                    ? landmarks[FaceMesh.cheekLeft] : landmarks[FaceMesh.cheekRight]
                // That side's own distance from the midline, so a three-quarter
                // view puts the near and far cheek in different places — the
                // same reason FaceMeshFrame measures `u` per point (ADR-0010).
                // Floored so a near-profile face cannot collapse both lobes onto
                // the midline.
                let span = max(abs(frame.u(extreme)), 0.15 * w)

                let tHighlight =
                    frame.tEyeLine
                    + CGFloat(cheekHighlightT) * (frame.tCheekLine - frame.tEyeLine)
                out.append(
                    lobe(
                        centre: point(t: tHighlight, u: side * CGFloat(cheekHighlightU) * span),
                        axis: axis(tilt: cheekHighlightTilt, side: side),
                        halfAlong: CGFloat(cheekHighlightHalf.along) * w,
                        halfAcross: CGFloat(cheekHighlightHalf.across) * w,
                        strength: amount * cheekHighlightStrength))

                let tShadow =
                    frame.tCheekLine
                    + CGFloat(cheekShadowT) * (frame.tMouthLine - frame.tCheekLine)
                out.append(
                    lobe(
                        centre: point(t: tShadow, u: side * CGFloat(cheekShadowU) * span),
                        axis: axis(tilt: cheekShadowTilt, side: side),
                        halfAlong: CGFloat(cheekShadowHalf.along) * w,
                        halfAcross: CGFloat(cheekShadowHalf.across) * w,
                        strength: -amount * cheekShadowStrength))
            }
        }

        // --- Nose bridge: one narrow highlight on the midline, between the two
        //     levels FaceReshape already computes. Skipped when the projected
        //     bridge has no length (a head tipped back far enough that the
        //     nasion and the tip land on the same point).
        if sliders.nose > 0 {
            let span = (frame.tNoseTip - frame.tNasion) * frame.length
            if span > 0 {
                out.append(
                    lobe(
                        centre: point(t: (frame.tNasion + frame.tNoseTip) / 2, u: 0),
                        axis: frame.down,
                        halfAlong: CGFloat(noseHalfLength) * span,
                        halfAcross: CGFloat(noseHalfWidth) * w,
                        strength: (sliders.nose / 100) * noseStrength))
            }
        }

        // --- Jaw: three segments per side along the face oval, pushed slightly
        //     inside it.
        if sliders.jaw > 0 {
            let amount = sliders.jaw / 100
            let inward = point(t: 0.45, u: 0)
            for indices in [jawRight, jawLeft] {
                for group in stride(from: 0, to: indices.count - 2, by: 3) {
                    let a = landmarks[indices[group]]
                    let b = landmarks[indices[group + 1]]
                    let c = landmarks[indices[group + 2]]
                    let spanX = c.x - a.x
                    let spanY = c.y - a.y
                    let length = hypot(spanX, spanY)
                    guard length > 0.02 * w else { continue }
                    var centre = CGPoint(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3)
                    let toInside = CGVector(dx: inward.x - centre.x, dy: inward.y - centre.y)
                    let inwardLength = hypot(toInside.dx, toInside.dy)
                    if inwardLength > 0 {
                        centre.x += toInside.dx / inwardLength * CGFloat(jawInset) * w
                        centre.y += toInside.dy / inwardLength * CGFloat(jawInset) * w
                    }
                    out.append(
                        lobe(
                            centre: centre,
                            axis: CGVector(dx: spanX / length, dy: spanY / length),
                            halfAlong: length / 2 + CGFloat(jawOverlap) * w,
                            halfAcross: CGFloat(jawHalfWidth) * w,
                            strength: -amount * jawStrength))
                }
            }
        }

        return out
    }

    // MARK: - Evaluation

    /// The mask at one point, in `Double`.
    ///
    /// This is the CPU twin of `rp_contour_mask` in `ColorShaders.metal`: same
    /// summation order, same falloff, same final clamp. It reads the `Float`
    /// fields the GPU was handed — not the `CGFloat` geometry they came from — so
    /// a golden comparison measures the kernel and not the float conversion, the
    /// same arrangement `ColorRenderNode.curveTable` uses for the curve LUT.
    ///
    /// `point` is a **pixel centre**: the kernel evaluates at `float2(gid) + 0.5`.
    static func value(at point: CGPoint, lobes: [ContourLobe]) -> Double {
        var m = 0.0
        for lobe in lobes {
            let dx = Double(point.x) - Double(lobe.centre.x)
            let dy = Double(point.y) - Double(lobe.centre.y)
            let ux = Double(lobe.axisU.x)
            let uy = Double(lobe.axisU.y)
            let a = (dx * ux + dy * uy) / Double(lobe.halfExtent.x)
            let b = (dx * -uy + dy * ux) / Double(lobe.halfExtent.y)
            let r2 = a * a + b * b
            guard r2 < 1 else { continue }
            let r = r2.squareRoot()
            m += Double(lobe.strength) * (1 - r * r * (3 - 2 * r))
        }
        return min(max(m, -1), 1)
    }
}
