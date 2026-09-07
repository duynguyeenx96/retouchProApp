import CoreGraphics
import Foundation

/// The MediaPipe Face Mesh index lists and the face-local coordinate frame the
/// "Mặt" (reshape) sliders are expressed in.
///
/// `RPVision.FaceMeshIndex` deliberately carries only the three indices the
/// *analysis* contract needs (`cheekRight`, `cheekLeft`, `chin`, `foreheadTop`)
/// and says so: "the reshape sliders' full index lists belong to RPEngine". This
/// is that list. Nothing here imports RPVision; the landmarks arrive as
/// `FaceRenderInput.landmarks`, plain `[CGPoint]` in image pixels, y down.
///
/// ## Why the lists are checked and not trusted
/// A wrong index still produces a warp — just of the wrong part of the face, at
/// which point every downstream number (PSNR, ms/frame) is still green and the
/// picture is wrong. Spike S3's `FaceReshape.check` established the discipline;
/// `FaceMeshGeometryTests` runs the same class of geometric assertions over the
/// **11 real a6300 meshes** `FaceAnalyzer` produced
/// (`Research/phase2/face-analyzer/results/a6300/twostage.json`), and the
/// measured ranges are filed in `Research/bench/p2-warp-*.json`.
public enum FaceMesh {
    /// MediaPipe Face Landmarker with the iris refinement: 468 face + 10 iris.
    public static let pointCount = 478
    /// Face points only; 468…477 are the two iris rings.
    public static let faceOnlyPointCount = 468

    // MARK: - Single landmarks

    /// Subject's right cheek extreme. `faceWidth` is `|454 − 234|`, the same
    /// definition `RPVision.AnalyzedFace.faceWidth` uses, so the two agree.
    public static let cheekRight = 234
    /// Subject's left cheek extreme.
    public static let cheekLeft = 454
    /// Chin tip.
    public static let chin = 152
    /// Top of the forehead / hairline centre.
    public static let foreheadTop = 10
    /// Nasion — the bridge of the nose between the brows.
    public static let nasion = 168
    /// Nose tip.
    public static let noseTip = 1
    /// Base of the columella, under the nose.
    public static let noseBase = 2
    /// Eye corners, subject's right eye then left.
    public static let eyeOuterRight = 33
    public static let eyeInnerRight = 133
    public static let eyeInnerLeft = 362
    public static let eyeOuterLeft = 263
    /// Mouth corners.
    public static let mouthCornerRight = 61
    public static let mouthCornerLeft = 291

    // MARK: - Rings

    /// `FACEMESH_FACE_OVAL`, in ring order, starting at the forehead centre and
    /// running down the subject's left side to the chin and back up the right.
    /// Copied from spike S3's `FaceReshape.faceOval`, which verified it
    /// geometrically rather than trusting it.
    public static let faceOval: [Int] = [
        10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379,
        378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
        162, 21, 54, 103, 67, 109,
    ]

    /// `FACEMESH_LEFT_EYE` (the subject's left eye).
    public static let eyeRingLeft: [Int] = [
        362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398,
    ]
    /// `FACEMESH_RIGHT_EYE`.
    public static let eyeRingRight: [Int] = [
        33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246,
    ]
    /// The two iris rings the 478-point model adds. **Which ring belongs to which
    /// eye is not assumed** — `FaceReshape` assigns each iris point to the nearer
    /// eye centroid, so a naming convention (MediaPipe's "left" is the image's
    /// left, not the subject's) cannot put an iris on the wrong eye.
    public static let irisPoints: [Int] = Array(468..<478)

    /// `FACEMESH_LIPS` outer ring, starting at the subject's right corner.
    public static let lipsOuter: [Int] = [
        61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0,
        37, 39, 40, 185,
    ]
    /// `FACEMESH_LIPS` inner ring (the mouth opening).
    public static let lipsInner: [Int] = [
        78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13,
        82, 81, 80, 191,
    ]

    /// Nose midline from the nasion down to the top of the tip.
    ///
    /// Measured on the 11 a6300 meshes: `t` runs 0.271 → 0.477 down the face and
    /// every point stays within `0.068 × faceWidth` of the midline.
    public static let noseBridge: [Int] = [168, 6, 197, 195, 5]
    /// Tip, sub-tip and columella. Within `0.079 × faceWidth` of the midline.
    public static let noseCentre: [Int] = [4, 1, 19, 94, 2, 141, 370]
    /// The subject's right ala (nostril wing). Every one of these measured
    /// `u < 0` — i.e. strictly on the right of the face's own midline — on all
    /// 11 real meshes, which is what `FaceMeshGeometryTests` asserts.
    public static let noseAlaRight: [Int] = [115, 220, 131, 49, 209, 129, 48, 64, 98, 97]
    /// The subject's left ala. Mirror of ``noseAlaRight``; measured `u > 0`.
    public static let noseAlaLeft: [Int] = [344, 440, 360, 279, 429, 358, 278, 294, 327, 326]

    /// Every nose handle: bridge + centre + both alae. 32 points.
    public static let nose: [Int] = {
        var out: [Int] = noseBridge
        out.append(contentsOf: noseCentre)
        out.append(contentsOf: noseAlaRight)
        out.append(contentsOf: noseAlaLeft)
        return out
    }()

    /// Every index any slider can touch, in one array.
    ///
    /// Built with `append(contentsOf:)` rather than a chain of `+`: a seven-term
    /// `+` over untyped integer literals is one expression the Swift type checker
    /// has to solve as a whole, and SourceKit reported it as
    /// "unable to type-check in reasonable time". Every list above therefore also
    /// carries an explicit `[Int]`.
    public static let allHandleIndices: [Int] = {
        var out: [Int] = faceOval
        out.append(contentsOf: eyeRingLeft)
        out.append(contentsOf: eyeRingRight)
        out.append(contentsOf: irisPoints)
        out.append(contentsOf: lipsOuter)
        out.append(contentsOf: lipsInner)
        out.append(contentsOf: nose)
        return out
    }()

    /// Highest index any list above refers to. A `landmarks` array shorter than
    /// this cannot drive the reshape sliders.
    public static let highestIndex: Int = allHandleIndices.max() ?? 0
}

/// The face's own coordinate system: an origin at the forehead centre, a "down"
/// axis along the projected face midline and a "lateral" axis perpendicular to
/// it, plus the landmark-derived levels the slider bands are anchored to.
///
/// ## Why a face frame and not image x/y
///
/// 1. **Roll — verified.** A head tilted 15° in the frame must still slim along
///    *its* width, not along the image's x axis. The axis is `p[10] → p[152]`, so
///    the frame rotates with the head, and
///    `FaceReshapeTests.reshapeFollowsTheHeadRoll` asserts every displacement is
///    unchanged (to `1e-9 × faceWidth`) when the whole mesh is rotated 0.4 rad.
/// 2. **Yaw — observed, not validated.** On a three-quarter view the projected
///    midline is off-centre, and measuring `u` against `p[10] → p[152]` follows
///    it: the subject's left cheek takes 0.480…0.683 of the width over the 11
///    a6300 frames, against 0.5 for a frontal face. "Pull toward the midline"
///    therefore moves the far cheek further than the near one, which is what a
///    perspective projection asks for, while a frame built on the image's
///    vertical would move them equally. **That the amount is *correct* is not
///    measured** — it would need a ground-truth head pose this project does not
///    have. What is measured is that the frame responds to pose at all.
///    (`FaceMeshGeometryTests.cheekSplitIsAnAnatomyIdentity` records the split
///    and explains why "the two `u` values sum to 1" — which they do, on every
///    frame, frontal ones included — is an anatomical identity that would hold
///    for a wrong frame too, so it is not evidence.)
///
/// Every `t` below is a **fraction of the forehead→chin distance** and every `u`
/// is compared against **face width**, so nothing in the reshape maths carries a
/// pixel constant (docs/PLAN.md §2: reshape deltas are relative to face width so
/// a preset transfers between images).
public struct FaceMeshFrame: Sendable {
    /// `landmarks[10]`, the forehead centre. `t == 0` here.
    public let origin: CGPoint
    /// Unit vector from the forehead centre to the chin.
    public let down: CGVector
    /// Unit vector perpendicular to ``down``, pointing at the subject's left
    /// cheek (`landmarks[454]`).
    public let lateral: CGVector
    /// `|chin − forehead|` in pixels. The denominator of ``t(_:)``.
    public let length: CGFloat
    /// `|454 − 234|` in pixels — `FaceRenderInput.faceWidth`, taken from the
    /// caller rather than recomputed so the graph and the analysis agree on one
    /// number.
    public let width: CGFloat

    /// Mean `t` of the four eye corners. Measured 0.295–0.320 over 11 frames.
    public let tEyeLine: CGFloat
    /// Mean `t` of the two cheek extremes. Measured 0.404–0.463.
    public let tCheekLine: CGFloat
    /// Mean `t` of the two mouth corners. Measured 0.669–0.736.
    public let tMouthLine: CGFloat
    /// `t` of the nasion (168). Measured 0.271–0.298.
    public let tNasion: CGFloat
    /// `t` of the nose tip (1). Measured 0.505–0.569.
    public let tNoseTip: CGFloat
    /// `t` of the columella base (2). Measured 0.557–0.600.
    public let tNoseBase: CGFloat

    /// `nil` when the mesh is too short or the face is degenerate (zero length or
    /// zero width) — in which case the warp node falls back to an exact copy
    /// rather than dividing by zero and producing a NaN grid.
    public init?(landmarks: [CGPoint], faceWidth: CGFloat) {
        guard landmarks.count > FaceMesh.highestIndex, faceWidth.isFinite, faceWidth > 0
        else { return nil }
        let top = landmarks[FaceMesh.foreheadTop]
        let chin = landmarks[FaceMesh.chin]
        let axis = CGVector(dx: chin.x - top.x, dy: chin.y - top.y)
        let length = hypot(axis.dx, axis.dy)
        guard length.isFinite, length > 0 else { return nil }
        self.origin = top
        self.length = length
        self.width = faceWidth
        let unit = CGVector(dx: axis.dx / length, dy: axis.dy / length)
        self.down = unit
        // Rotate `down` by +90° in the y-down frame, then flip if it points at
        // the subject's right instead of the left.
        var side = CGVector(dx: -unit.dy, dy: unit.dx)
        let cheekSpan = CGVector(
            dx: landmarks[FaceMesh.cheekLeft].x - landmarks[FaceMesh.cheekRight].x,
            dy: landmarks[FaceMesh.cheekLeft].y - landmarks[FaceMesh.cheekRight].y)
        if side.dx * cheekSpan.dx + side.dy * cheekSpan.dy < 0 {
            side = CGVector(dx: -side.dx, dy: -side.dy)
        }
        self.lateral = side

        func t(_ point: CGPoint) -> CGFloat {
            ((point.x - top.x) * unit.dx + (point.y - top.y) * unit.dy) / length
        }
        func meanT(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + t(landmarks[$1]) } / CGFloat(indices.count)
        }
        self.tEyeLine = meanT([
            FaceMesh.eyeOuterRight, FaceMesh.eyeInnerRight,
            FaceMesh.eyeInnerLeft, FaceMesh.eyeOuterLeft,
        ])
        self.tCheekLine = meanT([FaceMesh.cheekRight, FaceMesh.cheekLeft])
        self.tMouthLine = meanT([FaceMesh.mouthCornerRight, FaceMesh.mouthCornerLeft])
        self.tNasion = t(landmarks[FaceMesh.nasion])
        self.tNoseTip = t(landmarks[FaceMesh.noseTip])
        self.tNoseBase = t(landmarks[FaceMesh.noseBase])
    }

    /// Position along the face axis: 0 at the forehead centre, 1 at the chin.
    public func t(_ point: CGPoint) -> CGFloat {
        ((point.x - origin.x) * down.dx + (point.y - origin.y) * down.dy) / length
    }

    /// Signed perpendicular distance from the face midline, in pixels. Positive
    /// on the subject's left.
    public func u(_ point: CGPoint) -> CGFloat {
        (point.x - origin.x) * lateral.dx + (point.y - origin.y) * lateral.dy
    }

    /// How much a *lateral* slider is allowed to move a point that sits on the
    /// midline: nothing.
    ///
    /// Without this the chin tip (`u ≈ 0`) and the forehead centre would be
    /// pushed sideways by `sign(u)` on whatever side landmark noise happened to
    /// put them, which reads as a wobble rather than a slim. Ramps in over
    /// `0.15 × faceWidth`.
    public func lateralWeight(_ u: CGFloat) -> CGFloat {
        min(1, abs(u) / (0.15 * width))
    }

    /// A displacement of `distance` pixels toward the midline for a point at
    /// lateral offset `u`. Never crosses the midline: capped at half the point's
    /// own distance from it.
    public func towardMidline(u: CGFloat, distance: CGFloat) -> CGVector {
        let capped = min(distance, abs(u) * 0.5)
        let sign: CGFloat = u >= 0 ? -1 : 1
        return CGVector(dx: lateral.dx * sign * capped, dy: lateral.dy * sign * capped)
    }

    /// A displacement of `distance` pixels away from the midline.
    public func awayFromMidline(u: CGFloat, distance: CGFloat) -> CGVector {
        let sign: CGFloat = u >= 0 ? 1 : -1
        return CGVector(dx: lateral.dx * sign * distance, dy: lateral.dy * sign * distance)
    }

    /// `distance` pixels along the face axis. Negative moves toward the forehead.
    public func alongAxis(_ distance: CGFloat) -> CGVector {
        CGVector(dx: down.dx * distance, dy: down.dy * distance)
    }

    // MARK: - Weight curves

    /// `0` at or below `a`, `1` at or above `b`, Hermite in between.
    public static func ramp(_ x: CGFloat, from a: CGFloat, to b: CGFloat) -> CGFloat {
        guard b > a else { return x >= b ? 1 : 0 }
        let s = min(max((x - a) / (b - a), 0), 1)
        return s * s * (3 - 2 * s)
    }

    /// Raised cosine: `1` at `centre`, `0` at `|x − centre| ≥ halfWidth`, and
    /// `C¹`-continuous at both ends so two neighbouring bands blend instead of
    /// meeting at a crease.
    public static func band(_ x: CGFloat, centre: CGFloat, halfWidth: CGFloat) -> CGFloat {
        guard halfWidth > 0 else { return x == centre ? 1 : 0 }
        let s = min(abs(x - centre) / halfWidth, 1)
        return 0.5 * (1 + CGFloat(cos(Double.pi * Double(s))))
    }
}
