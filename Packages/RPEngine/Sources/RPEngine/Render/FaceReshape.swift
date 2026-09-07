import CoreGraphics
import Foundation

/// Turns ``FaceSliders`` plus a 478-point mesh into the MLS handles
/// ``MLSMeshWarp`` deforms the image with.
///
/// This is the whole of the "Mặt" group's maths, and it is deliberately **pure**:
/// value types in, value types out, no Metal, no state. Everything that can be
/// wrong about a reshape slider — which landmarks move, how far, in which
/// direction, and whether it scales with the face — is decided here and can be
/// tested without a GPU.
///
/// ## The rule for what becomes a handle
///
/// > A slider contributes its **whole** region as handles: the points its weight
/// > curve moves, *and* the points in the same region whose weight is 0, which
/// > become identity handles. Sliders at 0 contribute nothing.
///
/// The identity handles are the load-bearing half. MLS's far field converges to
/// one similarity transform fitted to every handle, so a region that is a handle
/// set stays where it is put; a region that is not one gets carried along by the
/// smooth field. That is why "Môi đầy" pins the inner lip ring (the lips thicken
/// but the mouth opening does not grow) and why "Bóp mặt" carries the upper oval
/// as identity handles (the temples do not follow the jaw in) — the same
/// construction spike S3's `FaceReshape` used for its two-slider benchmark.
///
/// Two handles never disagree: displacements **accumulate** per landmark, in
/// ``FaceSliders/values``' declaration order, and the handle list is emitted
/// sorted by index. Both orders are fixed so one `EditState` gives one mesh.
///
/// ## Every magnitude is relative to the face
///
/// A slider's effect at 100 is either `fraction × faceWidth` or a dimensionless
/// gain on a landmark-derived distance. Neither carries a pixel constant, so
/// `f(k · landmarks, k · faceWidth) == k · f(landmarks, faceWidth)` exactly —
/// which is the property that lets a preset move between images and between a
/// 2048 px preview and a 24 MP export
/// (`FaceReshapeTests.displacementsScaleWithTheFace`).
///
/// ## The magnitudes are not tuned
///
/// The constants below are plausible retouch amounts of the same order as spike
/// S3's `maxSlimFraction = 0.040` / `maxEyeGain = 0.20`. **Nothing has measured
/// what looks right** — that needs a human comparing renders, which is a later
/// task with a UI. What *is* measured is that they behave: the maximum
/// displacement the whole group can produce on a real a6300 face is filed in
/// `Research/bench/p2-warp-*.json`.
public enum FaceReshape {

    // MARK: - Magnitudes at slider = 100

    /// Bóp mặt: the jaw moves in by this fraction of face width.
    public static let slimFraction: CGFloat = 0.045
    /// Gò má.
    public static let cheekboneFraction: CGFloat = 0.035
    /// Hàm.
    public static let jawFraction: CGFloat = 0.050
    /// Cằm: the chin rises by this fraction of face width.
    public static let chinFraction: CGFloat = 0.045
    /// Trán: the hairline drops by this fraction of face width.
    public static let foreheadFraction: CGFloat = 0.045
    /// Thái dương: the temples push out by this fraction of face width.
    public static let templeFraction: CGFloat = 0.030
    /// Mũi thu nhỏ: the nose shrinks by this gain about its centroid.
    public static let noseShrinkGain: CGFloat = 0.12
    /// Mũi sống: the bridge narrows by this fraction of face width.
    public static let noseBridgeFraction: CGFloat = 0.020
    /// Mũi đầu: the tip lifts by this fraction of face width…
    public static let noseTipLiftFraction: CGFloat = 0.020
    /// …and the alae pinch in by this fraction of face width.
    public static let noseTipPinchFraction: CGFloat = 0.012
    /// Mắt to: each eye grows by this gain about its own centre.
    public static let eyeSizeGain: CGFloat = 0.18
    /// Mắt khoảng cách: each eye moves out by this fraction of face width.
    public static let eyeSpacingFraction: CGFloat = 0.030
    /// Mắt nghiêng: each eye rotates by this many radians (4.0°).
    public static let eyeTiltRadians: CGFloat = 0.070
    /// Miệng to: the lips grow by this gain about the mouth centre.
    public static let mouthSizeGain: CGFloat = 0.10
    /// Miệng cười: the corners lift by this fraction of face width…
    public static let mouthSmileLiftFraction: CGFloat = 0.030
    /// …and spread out by this fraction of face width.
    public static let mouthSmileSpreadFraction: CGFloat = 0.010
    /// Môi đầy: the outer lip ring's height grows by this gain.
    public static let lipFullnessGain: CGFloat = 0.22

    // MARK: - Where each outline band sits on the face
    //
    // All six outline sliders walk the same 36-point oval; what separates them is
    // *where* along the face axis their weight lives. Every level below is a
    // fraction of a landmark-derived level (`tEyeLine`, `tCheekLine`,
    // `tMouthLine`), never a fixed `t`, so a long face and a round one get the
    // same anatomy. The measured spread of those levels over the 11 real a6300
    // meshes is in `FaceMeshGeometryTests.frameLevelsAreStable`.

    /// Gò má: raised-cosine half-width around `tCheekLine`.
    public static let cheekboneBandHalfWidth: CGFloat = 0.18
    /// Hàm: band centre, as a fraction of the way from the cheek line to the chin.
    public static let jawBandCentreFraction: CGFloat = 0.55
    public static let jawBandHalfWidth: CGFloat = 0.22
    /// Thái dương: band centre, as a fraction of the eye line (i.e. above it).
    public static let templeBandCentreFraction: CGFloat = 0.60
    /// Thái dương: the band's outer half-width is capped so it always stops
    /// *before* the cheek line.
    ///
    /// A fixed 0.25 reached `t = 0.398` on `DSC05123` against a cheek line at
    /// 0.422 — inside the raised cosine's tail, so "Thái dương" moved the two
    /// landmarks that *define* face width by 0.06 px. Small, but it makes the
    /// denominator of every other slider depend on this one. Deriving the width
    /// from `tCheekLine` removes the coupling instead of tuning it away.
    public static let templeBandCheekMargin: CGFloat = 0.90
    /// Cằm: the ramp starts this fraction of the way from the mouth line to the chin.
    public static let chinBandStartFraction: CGFloat = 0.35
    /// Trán: the ramp ends at this fraction of the eye line — roughly the brow.
    public static let foreheadBandEndFraction: CGFloat = 0.55

    static func templeBandHalfWidth(centre: CGFloat, frame: FaceMeshFrame) -> CGFloat {
        min(0.25, max(0.02, templeBandCheekMargin * (frame.tCheekLine - centre)))
    }

    /// Identity handles per image edge, passed to
    /// `MLSDeformation.ControlPoints.pinningBorder`. **Mandatory** — ADR-0007:
    /// without them MLS's far field is a similarity fit to the face handles and
    /// a jaw slider visibly shifts the background.
    public static let borderAnchorsPerEdge = 4

    /// Which class of local transform the warp may use. `.similarity`, because
    /// "Mắt to" and "Mũi thu nhỏ" are enlargements and `.rigid` provably cannot
    /// express one (`MLSDeformationTests.similarityScalesRigidDoesNot`).
    public static let variant = MLSDeformation.Variant.similarity
    /// MLS weight exponent. 2.0 — a face has dozens of handles a few pixels
    /// apart and `alpha = 1` lets a jaw handle tug on an eyelid (ADR-0007 flags
    /// this as a taste parameter, not a measured one).
    public static let alpha: Double = 2.0

    // MARK: - Output

    /// One landmark that a slider touched.
    public struct Handle: Sendable, Equatable {
        /// Index into the 478-point mesh.
        public var index: Int
        public var source: CGPoint
        public var destination: CGPoint

        public var displacement: CGFloat {
            hypot(destination.x - source.x, destination.y - source.y)
        }
    }

    /// The handles for a whole render, plus the numbers a bench or a diagnostic
    /// wants without recomputing them.
    public struct Built: Sendable {
        /// Face handles **and** the border anchors, ready for `MLSMeshWarp`.
        public var control: MLSDeformation.ControlPoints
        /// Face handles only, in emission order.
        public var handles: [Handle]
        /// Largest displacement over all faces, in pixels.
        public var maxDisplacement: CGFloat
        /// How many handles actually moved (the rest are identity anchors).
        public var movedHandleCount: Int
        /// Border anchors added. `2 * (perEdge + 1) + 2 * (perEdge - 1)`.
        public var borderAnchorCount: Int
    }

    // MARK: - Entry points

    /// Handles for one face. Empty when the sliders are all 0 or the mesh is
    /// unusable (short array, zero face width, degenerate axis).
    public static func handles(
        landmarks: [CGPoint], faceWidth: CGFloat, sliders: FaceSliders
    ) -> [Handle] {
        guard !sliders.isIdentity,
            let frame = FaceMeshFrame(landmarks: landmarks, faceWidth: faceWidth)
        else { return [] }

        var delta: [Int: CGVector] = [:]
        delta.reserveCapacity(FaceMesh.allHandleIndices.count)

        func touch(_ indices: [Int]) {
            for index in indices where delta[index] == nil { delta[index] = .zero }
        }
        func move(_ index: Int, _ vector: CGVector) {
            let current = delta[index] ?? .zero
            delta[index] = CGVector(dx: current.dx + vector.dx, dy: current.dy + vector.dy)
        }

        if sliders.needsOval { touch(FaceMesh.faceOval) }
        if sliders.needsNose { touch(FaceMesh.nose) }
        let eyes = sliders.needsEyes ? eyeGroups(landmarks: landmarks, frame: frame) : []
        for eye in eyes { touch(eye.indices) }
        let mouth = sliders.needsMouth ? mouthGroup(landmarks: landmarks, frame: frame) : nil
        if let mouth { touch(mouth.indices) }

        // --- Face outline ------------------------------------------------

        if sliders.slim > 0 {
            let amount = CGFloat(sliders.slim / 100) * slimFraction * frame.width
            for index in FaceMesh.faceOval {
                let point = landmarks[index]
                let ramp = FaceMeshFrame.ramp(frame.t(point), from: frame.tEyeLine, to: 1)
                // Squared so the jaw and chin take most of the movement and the
                // cheekbones take a little — S3's `FaceReshape` used the same
                // curve, and it is what stops a slim slider reading as "the whole
                // head got narrower".
                let u = frame.u(point)
                let weight = ramp * ramp * frame.lateralWeight(u)
                guard weight > 0 else { continue }
                move(index, frame.towardMidline(u: u, distance: amount * weight))
            }
        }
        if sliders.cheekbone > 0 {
            narrowBand(
                landmarks: landmarks, frame: frame,
                centre: frame.tCheekLine, halfWidth: cheekboneBandHalfWidth,
                amount: CGFloat(sliders.cheekbone / 100) * cheekboneFraction * frame.width,
                outward: false, move: move)
        }
        if sliders.jaw > 0 {
            let centre =
                frame.tCheekLine + jawBandCentreFraction * (1 - frame.tCheekLine)
            narrowBand(
                landmarks: landmarks, frame: frame,
                centre: centre, halfWidth: jawBandHalfWidth,
                amount: CGFloat(sliders.jaw / 100) * jawFraction * frame.width,
                outward: false, move: move)
        }
        if sliders.temple > 0 {
            let centre = templeBandCentreFraction * frame.tEyeLine
            narrowBand(
                landmarks: landmarks, frame: frame,
                centre: centre,
                halfWidth: templeBandHalfWidth(centre: centre, frame: frame),
                amount: CGFloat(sliders.temple / 100) * templeFraction * frame.width,
                outward: true, move: move)
        }
        if sliders.chin > 0 {
            // Starts a third of the way from the mouth line to the chin, so the
            // jaw corners are untouched and only the point of the chin rises.
            let start = frame.tMouthLine + chinBandStartFraction * (1 - frame.tMouthLine)
            let amount = CGFloat(sliders.chin / 100) * chinFraction * frame.width
            for index in FaceMesh.faceOval {
                let weight = FaceMeshFrame.ramp(frame.t(landmarks[index]), from: start, to: 1)
                guard weight > 0 else { continue }
                move(index, frame.alongAxis(-amount * weight))
            }
        }
        if sliders.forehead > 0 {
            let end = foreheadBandEndFraction * frame.tEyeLine  // roughly the brow line
            let amount = CGFloat(sliders.forehead / 100) * foreheadFraction * frame.width
            for index in FaceMesh.faceOval {
                let weight = 1 - FaceMeshFrame.ramp(frame.t(landmarks[index]), from: 0, to: end)
                guard weight > 0 else { continue }
                move(index, frame.alongAxis(amount * weight))
            }
        }

        // --- Nose ----------------------------------------------------------

        if sliders.noseShrink > 0 {
            let centre = centroid(of: FaceMesh.nose, in: landmarks)
            let gain = CGFloat(sliders.noseShrink / 100) * noseShrinkGain
            for index in FaceMesh.nose {
                let point = landmarks[index]
                move(index, CGVector(
                    dx: (centre.x - point.x) * gain, dy: (centre.y - point.y) * gain))
            }
        }
        if sliders.noseBridge > 0 {
            let amount = CGFloat(sliders.noseBridge / 100) * noseBridgeFraction * frame.width
            for index in FaceMesh.nose {
                let point = landmarks[index]
                // 1 at the nasion, 0 at the tip.
                let weight = 1 - FaceMeshFrame.ramp(
                    frame.t(point), from: frame.tNasion, to: frame.tNoseTip)
                guard weight > 0 else { continue }
                move(index, frame.towardMidline(u: frame.u(point), distance: amount * weight))
            }
        }
        if sliders.noseTip > 0 {
            let start = (frame.tNasion + frame.tNoseTip) / 2
            let lift = CGFloat(sliders.noseTip / 100) * noseTipLiftFraction * frame.width
            let pinch = CGFloat(sliders.noseTip / 100) * noseTipPinchFraction * frame.width
            for index in FaceMesh.nose {
                let point = landmarks[index]
                let weight = FaceMeshFrame.ramp(
                    frame.t(point), from: start, to: frame.tNoseBase)
                guard weight > 0 else { continue }
                var vector = frame.alongAxis(-lift * weight)
                let pinchVector = frame.towardMidline(
                    u: frame.u(point), distance: pinch * weight)
                vector.dx += pinchVector.dx
                vector.dy += pinchVector.dy
                move(index, vector)
            }
        }

        // --- Eyes ----------------------------------------------------------

        for eye in eyes {
            if sliders.eyeSize > 0 {
                let gain = CGFloat(sliders.eyeSize / 100) * eyeSizeGain
                for index in eye.indices {
                    let point = landmarks[index]
                    move(index, CGVector(
                        dx: (point.x - eye.centre.x) * gain,
                        dy: (point.y - eye.centre.y) * gain))
                }
            }
            if sliders.eyeSpacing > 0 {
                let amount = CGFloat(sliders.eyeSpacing / 100) * eyeSpacingFraction * frame.width
                let vector = frame.awayFromMidline(u: frame.u(eye.centre), distance: amount)
                for index in eye.indices { move(index, vector) }
            }
            if sliders.eyeTilt > 0 {
                let angle = CGFloat(sliders.eyeTilt / 100) * eyeTiltRadians * eye.liftSign
                let (sine, cosine) = (sin(angle), cos(angle))
                for index in eye.indices {
                    let point = landmarks[index]
                    let dx = point.x - eye.centre.x
                    let dy = point.y - eye.centre.y
                    move(index, CGVector(
                        dx: (cosine * dx - sine * dy) - dx,
                        dy: (sine * dx + cosine * dy) - dy))
                }
            }
        }

        // --- Mouth ---------------------------------------------------------

        if let mouth {
            if sliders.mouthSize > 0 {
                let gain = CGFloat(sliders.mouthSize / 100) * mouthSizeGain
                for index in mouth.indices {
                    let point = landmarks[index]
                    move(index, CGVector(
                        dx: (point.x - mouth.centre.x) * gain,
                        dy: (point.y - mouth.centre.y) * gain))
                }
            }
            if sliders.mouthSmile > 0 {
                let lift =
                    CGFloat(sliders.mouthSmile / 100) * mouthSmileLiftFraction * frame.width
                let spread =
                    CGFloat(sliders.mouthSmile / 100) * mouthSmileSpreadFraction * frame.width
                for index in mouth.indices {
                    let point = landmarks[index]
                    // 0 at the centre of the lip, 1 at the corners. Squared, so
                    // the middle of the lip barely moves and the corners carry
                    // the smile.
                    let offset = (frame.u(point) - mouth.centreU) / mouth.halfWidth
                    let weight = min(abs(offset), 1) * min(abs(offset), 1)
                    guard weight > 0 else { continue }
                    var vector = frame.alongAxis(-lift * weight)
                    let sign: CGFloat = offset >= 0 ? 1 : -1
                    vector.dx += frame.lateral.dx * sign * spread * weight
                    vector.dy += frame.lateral.dy * sign * spread * weight
                    move(index, vector)
                }
            }
            if sliders.lipFullness > 0 {
                let gain = CGFloat(sliders.lipFullness / 100) * lipFullnessGain
                // Only the outer ring moves. The inner ring is already in
                // `mouth.indices`, so it stays as an identity handle and the
                // mouth opening does not grow with the lip.
                for index in FaceMesh.lipsOuter {
                    let point = landmarks[index]
                    let along = (point.x - mouth.centre.x) * frame.down.dx
                        + (point.y - mouth.centre.y) * frame.down.dy
                    move(index, frame.alongAxis(along * gain))
                }
            }
        }

        return delta.keys.sorted().map { index in
            let source = landmarks[index]
            let vector = delta[index] ?? .zero
            return Handle(
                index: index, source: source,
                destination: CGPoint(x: source.x + vector.dx, y: source.y + vector.dy))
        }
    }

    /// Handles for every face in a request, plus the mandatory border anchors.
    ///
    /// `nil` when there is nothing to warp — all sliders 0, no usable face, or a
    /// face whose geometry produced no movement at all. The node turns that into
    /// an exact copy, so "slider at 0" and "slider on a face the mesh could not
    /// describe" both leave the picture bit-exact rather than resampling it.
    public static func controlPoints(
        faces: [FaceRenderInput], sliders: FaceSliders, imageSize: CGSize
    ) -> Built? {
        guard !sliders.isIdentity, imageSize.width > 0, imageSize.height > 0 else { return nil }
        var handles: [Handle] = []
        for face in faces {
            handles += self.handles(
                landmarks: face.landmarks, faceWidth: face.faceWidth, sliders: sliders)
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
            movedHandleCount: moved,
            borderAnchorCount: control.count - handles.count)
    }

    /// The `MLSDeformation.Options` for a quality level. The grid is
    /// `RenderQuality.meshGrid`: **65 preview / 129 export**, mandatory per
    /// ADR-0007 (grid 33 drops to 43.8 dB against a 1025-vertex reference on the
    /// worst a6300 frame, below the plan's 45 dB bar).
    public static func options(for quality: RenderQuality) -> MLSDeformation.Options {
        MLSDeformation.Options(
            variant: variant, alpha: alpha,
            gridWidth: quality.meshGrid, gridHeight: quality.meshGrid)
    }

    // MARK: - Regions

    /// One eye: its ring, the iris points nearest it, its centre, and which way
    /// a positive rotation lifts its **outer** corner.
    struct EyeGroup {
        var indices: [Int]
        var centre: CGPoint
        /// `+1` or `−1`, so `eyeTilt` always raises the outer corner whatever the
        /// head's roll or which eye this is.
        var liftSign: CGFloat
    }

    /// The two eyes, with the iris points assigned by **distance, not by name**.
    ///
    /// MediaPipe's "left iris" is the image's left, which is the subject's right;
    /// getting that backwards would enlarge one eye and shrink the other by the
    /// iris's contribution and still look plausible in a thumbnail. Nearest
    /// centroid cannot be backwards.
    static func eyeGroups(landmarks: [CGPoint], frame: FaceMeshFrame) -> [EyeGroup] {
        let rings = [FaceMesh.eyeRingRight, FaceMesh.eyeRingLeft]
        let outers = [FaceMesh.eyeOuterRight, FaceMesh.eyeOuterLeft]
        let centres = rings.map { centroid(of: $0, in: landmarks) }
        var indices = rings
        for iris in FaceMesh.irisPoints {
            let point = landmarks[iris]
            let d0 = hypot(point.x - centres[0].x, point.y - centres[0].y)
            let d1 = hypot(point.x - centres[1].x, point.y - centres[1].y)
            indices[d0 <= d1 ? 0 : 1].append(iris)
        }
        return (0..<2).map { side in
            EyeGroup(
                indices: indices[side].sorted(), centre: centres[side],
                liftSign: liftSign(
                    outer: landmarks[outers[side]], centre: centres[side], frame: frame))
        }
    }

    /// Which sign of rotation about `centre` moves `outer` toward the forehead.
    ///
    /// Derived, not hard-coded: rotate the outer corner by a small positive angle
    /// and look at whether it went up the face axis. A hard-coded `+1` for the
    /// left eye and `−1` for the right is right only for one handedness of the
    /// coordinate system and one definition of "left".
    private static func liftSign(
        outer: CGPoint, centre: CGPoint, frame: FaceMeshFrame
    ) -> CGFloat {
        let dx = outer.x - centre.x
        let dy = outer.y - centre.y
        let angle: CGFloat = 0.01
        let rotated = CGPoint(
            x: centre.x + cos(angle) * dx - sin(angle) * dy,
            y: centre.y + sin(angle) * dx + cos(angle) * dy)
        // `down` points at the chin, so a negative projection means "moved up".
        let along = (rotated.x - outer.x) * frame.down.dx + (rotated.y - outer.y) * frame.down.dy
        return along < 0 ? 1 : -1
    }

    /// The lips: outer ring + inner ring, the mouth's centre, and the half-width
    /// the smile weight is measured against.
    struct MouthGroup {
        var indices: [Int]
        var centre: CGPoint
        /// `frame.u(centre)`, cached because the smile weight needs it per point.
        var centreU: CGFloat
        /// Largest `|u − centreU|` over the outer ring. Always > 0, because a
        /// mouth with zero measured width means the frame is unusable.
        var halfWidth: CGFloat
    }

    static func mouthGroup(landmarks: [CGPoint], frame: FaceMeshFrame) -> MouthGroup? {
        let centre = centroid(of: FaceMesh.lipsOuter, in: landmarks)
        let centreU = frame.u(centre)
        var halfWidth: CGFloat = 0
        for index in FaceMesh.lipsOuter {
            halfWidth = max(halfWidth, abs(frame.u(landmarks[index]) - centreU))
        }
        guard halfWidth > 0 else { return nil }
        var indices = FaceMesh.lipsOuter
        indices.append(contentsOf: FaceMesh.lipsInner)
        return MouthGroup(
            indices: indices.sorted(), centre: centre, centreU: centreU, halfWidth: halfWidth)
    }

    // MARK: - Helpers

    /// A raised-cosine band of the face oval pulled toward (or pushed away from)
    /// the midline. Gò má, Hàm and Thái dương are the same operation at three
    /// levels of the face, so they are one function.
    private static func narrowBand(
        landmarks: [CGPoint], frame: FaceMeshFrame,
        centre: CGFloat, halfWidth: CGFloat, amount: CGFloat, outward: Bool,
        move: (Int, CGVector) -> Void
    ) {
        for index in FaceMesh.faceOval {
            let point = landmarks[index]
            let u = frame.u(point)
            let weight =
                FaceMeshFrame.band(frame.t(point), centre: centre, halfWidth: halfWidth)
                * frame.lateralWeight(u)
            guard weight > 0 else { continue }
            move(
                index,
                outward
                    ? frame.awayFromMidline(u: u, distance: amount * weight)
                    : frame.towardMidline(u: u, distance: amount * weight))
        }
    }

    static func centroid(of indices: [Int], in landmarks: [CGPoint]) -> CGPoint {
        guard !indices.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in indices {
            x += landmarks[index].x
            y += landmarks[index].y
        }
        return CGPoint(x: x / CGFloat(indices.count), y: y / CGFloat(indices.count))
    }
}
