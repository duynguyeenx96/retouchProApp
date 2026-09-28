import CoreGraphics
import Foundation
import RPCore

/// The "Trang điểm" (makeup) slider group — docs/PLAN.md Phase 5
/// *"Makeup sliders"*, docs/ADR-0027.
///
/// Four sliders, all 0–100, default 0, 0 = untouched — the ``HairSliders``
/// contract. v1 covers the three items of the planned six that have a mask
/// source today:
///
/// | slider | mask | why it is in v1 |
/// |---|---|---|
/// | Son môi (+ Tông son) | BiSeNet `lips` (`u_lip + l_lip`) | the class exists and is feathered |
/// | Má hồng | two soft ellipses anchored on the 478-point mesh, × BiSeNet `skin` | no "cheek" class; the ``ContourMask`` lobe machinery already does exactly this for "Tạo khối" |
/// | Lông mày | BiSeNet `brows` | the class exists |
///
/// "Nền" (foundation) is the Da group's "Đều màu da" under another name, and
/// "Phấn mắt" / "Kẻ mắt" need a lid / lash-line region no current mask gives —
/// the eye class is the opening, not the lid. They stay planned, not faked.
///
/// ``lipTone`` is a modifier, like `HairSliders.dyeTone`: a hue has no neutral
/// value, so the amount is ``lipstick`` and the tone alone changes nothing.
public struct MakeupSliders: Sendable, Equatable {
    /// **Son môi** — how far the lips move to the ``lipTone`` colour.
    public var lipstick: Double = 0
    /// **Tông son** — position on ``lipPalette``. Modifier only.
    public var lipTone: Double = 0
    /// **Má hồng** — rose tint on the apples of the cheeks, skin only.
    public var blush: Double = 0
    /// **Lông mày** — darkens the brows, on luma.
    public var brows: Double = 0

    public init(lipstick: Double = 0, lipTone: Double = 0, blush: Double = 0, brows: Double = 0) {
        self.lipstick = Slider.clamp(lipstick)
        self.lipTone = Slider.clamp(lipTone)
        self.blush = Slider.clamp(blush)
        self.brows = Slider.clamp(brows)
    }

    /// Parameter names inside `EditState.SectionKey.makeup`.
    public enum Key {
        public static let lipstick = "lipstick"
        public static let lipTone = "lipTone"
        public static let blush = "blush"
        public static let brows = "brows"

        public static let all = [lipstick, lipTone, blush, brows]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.makeup]
        self.init(
            lipstick: section.slider(Key.lipstick),
            lipTone: section.slider(Key.lipTone),
            blush: section.slider(Key.blush),
            brows: section.slider(Key.brows))
    }

    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.makeup
        state.setSlider(Key.lipstick, in: section, to: lipstick)
        state.setSlider(Key.lipTone, in: section, to: lipTone)
        state.setSlider(Key.blush, in: section, to: blush)
        state.setSlider(Key.brows, in: section, to: brows)
    }

    /// `true` when nothing can change. ``lipTone`` is a modifier and not part of it.
    public var isIdentity: Bool { lipstick == 0 && blush == 0 && brows == 0 }

    // MARK: - Colours

    /// Rec.709, the same weights as `kRPLuma`.
    static let lumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// "Tông son", in slider order: nude → coral → red → berry → plum,
    /// gamma-encoded sRGB. Unlike the hair dye, the palette's own **luma** is
    /// used too (``lipLumaPull``): lipstick is opaque enough to change how light
    /// the lips are, and a red at the lips' own luma reads as pink.
    public static let lipPalette: [SIMD3<Double>] = [
        SIMD3(0.72, 0.47, 0.42),
        SIMD3(0.86, 0.40, 0.34),
        SIMD3(0.72, 0.10, 0.14),
        SIMD3(0.58, 0.12, 0.30),
        SIMD3(0.40, 0.12, 0.24),
    ]

    /// The blush colour, gamma-encoded sRGB — a muted rose. Only its chroma is
    /// used (the tint keeps the skin's luma), so it cannot darken a cheek.
    public static let blushColour = SIMD3<Double>(0.88, 0.48, 0.52)

    /// How far the lips' luma moves toward the lipstick's own luma at full
    /// strength. Not 1: the lips' own highlights and creases are what make
    /// lipstick look applied rather than painted flat, so 60 % of the texture
    /// is kept.
    public static let lipLumaPull = 0.4

    /// Luma exponent at "Lông mày" = 100. 1.6 takes a mid-brown brow at 0.35 to
    /// 0.19 — one "shade" of brow pencil — and leaves near-black brows almost
    /// where they were.
    public static let browsExponent = 1.6

    /// The lipstick colour for a tone: (rgb normalised to luma 1, the colour's
    /// own luma). Computed on the CPU and handed to the shader so the palette has
    /// one definition.
    static func lipTint(tone: Double) -> (normalised: SIMD3<Double>, luma: Double) {
        let palette = lipPalette
        let position = Slider.clamp(tone) / 100 * Double(palette.count - 1)
        let lower = min(palette.count - 2, Int(position.rounded(.down)))
        let f = position - Double(lower)
        let c = palette[lower] * (1 - f) + palette[lower + 1] * f
        let y = (c * lumaWeights).sum()
        return (c / max(y, 1e-6), y)
    }

    /// ``blushColour`` normalised to luma 1.
    static var blushTint: SIMD3<Double> {
        blushColour / (blushColour * lumaWeights).sum()
    }

    /// `pow(browsExponent, brows / 100)`: exactly 1 at 0.
    var browsLumaExponent: Double { pow(Self.browsExponent, brows / 100) }
}

/// Where "Má hồng" goes: one soft ellipse per cheek, as ``ContourLobe``s, so the
/// shader evaluates them with the very `rp_contour_mask` "Tạo khối" uses and the
/// CPU reference is `ContourMask.value(at:lobes:)`.
///
/// Every length is a fraction of face width or of the mesh's own vertical
/// frame (``FaceMeshFrame``), which is what lets a preset carry it between a
/// close-up and a full-length frame.
enum BlushMask {
    static let lobesPerFace = 2
    /// Same budget as the contour lobes' buffer.
    static let maxLobes = 64

    /// Height of the apple of the cheek, as a fraction of the way from the eye
    /// line to the mouth line — just under the cheekbone highlight "Tạo khối"
    /// puts at 0.62 of eye → cheek line.
    static let appleT = 0.45
    /// Lateral position, as a fraction of that side's own cheek-extreme distance
    /// from the midline (per side, so a three-quarter view puts the far cheek's
    /// blush on the far cheek).
    static let appleU = 0.55
    static let halfAlong = 0.17
    static let halfAcross = 0.11
    /// Degrees; the long axis runs up toward the temple, the way blush is swept.
    static let tilt = 20.0

    static func lobes(faces: [FaceRenderInput]) -> [ContourLobe] {
        var out: [ContourLobe] = []
        for face in faces {
            guard out.count + lobesPerFace <= maxLobes,
                let frame = FaceMeshFrame(landmarks: face.landmarks, faceWidth: face.faceWidth)
            else { continue }
            out.append(contentsOf: lobes(frame: frame, landmarks: face.landmarks))
        }
        return out
    }

    static func lobes(frame: FaceMeshFrame, landmarks: [CGPoint]) -> [ContourLobe] {
        let w = frame.width
        let t = frame.tEyeLine + CGFloat(appleT) * (frame.tMouthLine - frame.tEyeLine)
        var out: [ContourLobe] = []
        for side in [CGFloat(1), CGFloat(-1)] {
            let extreme =
                side > 0 ? landmarks[FaceMesh.cheekLeft] : landmarks[FaceMesh.cheekRight]
            let span = max(abs(frame.u(extreme)), 0.15 * w)
            let u = side * CGFloat(appleU) * span
            let centre = CGPoint(
                x: frame.origin.x + frame.down.dx * (t * frame.length) + frame.lateral.dx * u,
                y: frame.origin.y + frame.down.dy * (t * frame.length) + frame.lateral.dy * u)
            let c = CGFloat(cos(tilt * .pi / 180))
            let s = CGFloat(sin(tilt * .pi / 180))
            let axis = CGVector(
                dx: side * frame.lateral.dx * c - frame.down.dx * s,
                dy: side * frame.lateral.dy * c - frame.down.dy * s)
            out.append(
                ContourLobe(
                    centre: SIMD2<Float>(Float(centre.x), Float(centre.y)),
                    axisU: SIMD2<Float>(Float(axis.dx), Float(axis.dy)),
                    halfExtent: SIMD2<Float>(Float(CGFloat(halfAlong) * w), Float(CGFloat(halfAcross) * w)),
                    strength: 1))
        }
        return out
    }
}
