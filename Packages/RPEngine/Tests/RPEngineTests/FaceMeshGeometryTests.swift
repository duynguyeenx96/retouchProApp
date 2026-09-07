import CoreGraphics
import Foundation
import Testing

@testable import RPEngine

/// Are `FaceMesh`'s index lists actually the parts of the face they are named
/// after?
///
/// This is the check spike S3's `FaceReshape.check` introduced and the reason it
/// exists: **a wrong index still produces a warp**, of the wrong part of the
/// face, and every other number in this project — PSNR against the CPU
/// reference, ms/frame, the scale-invariance proof — stays green while it does.
/// Nothing but geometry catches it.
///
/// Measured on the **11 real a6300 meshes** `FaceAnalyzer` produced
/// (`Research/phase2/face-analyzer/results/a6300/twostage.json`, docs/ADR-0008),
/// not on the synthetic face — a synthetic mesh is built from the same
/// assumptions the lists encode, so it could not disagree with them.
/// `WarpBenchTests` writes the same measurements to
/// `Research/bench/p2-warp-*.json`.
@Suite("Phase 2 face mesh geometry")
struct FaceMeshGeometryTests {

    @Test("The 11 real a6300 meshes are present")
    func fixturesArePresent() {
        // Not an #expect: the fixture is a large research artefact and a clone
        // without it must not fail the suite. Every test below skips the same way.
        if FaceLandmarkFixtures.a6300.isEmpty {
            print("P2 warp geometry: SKIP (Research/phase2/face-analyzer results absent)")
        } else {
            print("P2 warp geometry: \(FaceLandmarkFixtures.a6300.count) real a6300 meshes")
        }
    }

    @Test("Every index list sits on the part of the face it is named after")
    func indexListsAreWhereTheirNamesSay() throws {
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else { return }

        var worstOvalEnclosure = 1.0
        for mesh in meshes {
            let report = try #require(
                FaceMeshGeometry.measure(landmarks: mesh.landmarks, faceWidth: mesh.faceWidth),
                "\(mesh.image): unusable frame")

            // 1. The oval must enclose essentially every other landmark. Not all:
            //    a few brow and ear points sit a pixel outside a 36-gon drawn
            //    through the contour.
            #expect(
                report.ovalEnclosedFraction > 0.92,
                "\(mesh.image) oval encloses only \(report.ovalEnclosedFraction)")
            worstOvalEnclosure = min(worstOvalEnclosure, report.ovalEnclosedFraction)

            // 2. Eyes: plausible size and separation, above the mouth, and one on
            //    each side of the face's own midline.
            #expect(
                report.eyeSeparationOverWidth > 0.35 && report.eyeSeparationOverWidth < 0.55,
                "\(mesh.image) eye separation \(report.eyeSeparationOverWidth)")
            #expect(
                report.eyeWidthOverWidth > 0.12 && report.eyeWidthOverWidth < 0.25,
                "\(mesh.image) eye width \(report.eyeWidthOverWidth)")
            #expect(report.eyesStraddleTheMidline, "\(mesh.image) both eyes on one side")
            #expect(report.eyesAboveTheMouth, "\(mesh.image) an eye is below the mouth")

            // 3. Lips: the inner ring is the mouth opening, so it must be inside
            //    the outer ring — all 20 points, on all 11 frames.
            #expect(
                report.innerLipPointsInsideOuter == FaceMesh.lipsInner.count,
                "\(mesh.image) only \(report.innerLipPointsInsideOuter)/20 inner lip points inside")

            // 4. Nose: on the midline strip, between the eyes and the mouth, with
            //    the two alae strictly on opposite sides. This is the list that
            //    was chosen from measured landmark positions rather than from
            //    memory, so it is the one that most needs saying out loud.
            #expect(
                report.noseTRange.lowerBound > 0.18 && report.noseTRange.upperBound < 0.68,
                "\(mesh.image) nose t range \(report.noseTRange)")
            #expect(
                report.noseMidlineMaxOffset < 0.10,
                "\(mesh.image) a bridge/centre point is \(report.noseMidlineMaxOffset)×W off-axis")
            #expect(report.alaeStraddleTheMidline, "\(mesh.image) an ala is on the wrong side")
            #expect(
                report.noseWidthOverFaceWidth > 0.15 && report.noseWidthOverFaceWidth < 0.45,
                "\(mesh.image) nose width \(report.noseWidthOverFaceWidth)")

            // 5. Every iris point is inside the eye it was assigned to.
            #expect(
                report.irisPointsInsideTheirEye == FaceMesh.irisPoints.count,
                "\(mesh.image) \(report.irisPointsInsideTheirEye)/10 iris points inside an eye")

            // 6. The lists do not overlap — a landmark in two regions would be
            //    moved twice by unrelated sliders.
            #expect(report.regionsAreDisjoint, "\(mesh.image) regions overlap")
        }
        print(
            "P2 warp geometry over \(meshes.count) real meshes: worst oval enclosure "
                + "\(worstOvalEnclosure)")
    }

    /// The landmark-derived levels the slider bands hang off. If these drifted,
    /// "Gò má" would stop meaning the cheekbone even with a correct index list.
    @Test("The face-frame levels are stable across the real meshes")
    func frameLevelsAreStable() {
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else { return }
        var eye: [CGFloat] = []
        var cheek: [CGFloat] = []
        var mouth: [CGFloat] = []
        for mesh in meshes {
            guard let frame = FaceMeshFrame(landmarks: mesh.landmarks, faceWidth: mesh.faceWidth)
            else { continue }
            eye.append(frame.tEyeLine)
            cheek.append(frame.tCheekLine)
            mouth.append(frame.tMouthLine)
            // The order the bands assume, on every frame.
            #expect(frame.tEyeLine < frame.tCheekLine, "\(mesh.image)")
            #expect(frame.tCheekLine < frame.tMouthLine, "\(mesh.image)")
            #expect(frame.tNasion < frame.tNoseTip, "\(mesh.image)")
            #expect(frame.tNoseTip < frame.tNoseBase, "\(mesh.image)")
            #expect(frame.tNoseBase < frame.tMouthLine, "\(mesh.image)")
        }
        print(
            "P2 warp frame levels: eye \(eye.min()!)…\(eye.max()!), "
                + "cheek \(cheek.min()!)…\(cheek.max()!), mouth \(mouth.min()!)…\(mouth.max()!)")
        #expect(eye.max()! - eye.min()! < 0.10)
        #expect(cheek.max()! - cheek.min()! < 0.12)
        #expect(mouth.max()! - mouth.min()! < 0.12)
    }

    /// **What the cheek split does and does not prove.**
    ///
    /// ADR-0010 used to cite "on `DSC05123` the left cheek sits at
    /// `u = +0.67 × faceWidth` and the right at `−0.33`, summing to exactly 1" as
    /// evidence that the face-local frame handles yaw correctly. It is not
    /// evidence of anything: `u(454) − u(234)` is the projection of the vector
    /// between the two cheek landmarks onto `lateral`, and `faceWidth` is the
    /// distance between the same two points, so the two coincide whenever the
    /// cheeks are at roughly the same `t` — which they are, on every human face,
    /// whatever the frame does about yaw. This test measures that: the sum is 1
    /// on all 11 frames, including the near-frontal ones where there is no yaw
    /// asymmetry to compensate for. A wrong frame would score the same.
    ///
    /// What is actually verified about the frame is **roll**
    /// (`FaceReshapeTests.reshapeFollowsTheHeadRoll`, an exact invariance under a
    /// rotated mesh). The split *does* vary with pose (0.480…0.683 of the width
    /// on the subject's left over this set) — that is an observation, and this
    /// test records it, not a validation against a ground-truth yaw.
    @Test("The cheek split sums to 1 by anatomy, so it is not yaw evidence")
    func cheekSplitIsAnAnatomyIdentity() {
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else { return }
        var worstSumError = 0.0
        var worstDeltaT = 0.0
        var leftShare: [Double] = []
        for mesh in meshes {
            guard let frame = FaceMeshFrame(landmarks: mesh.landmarks, faceWidth: mesh.faceWidth)
            else { continue }
            let left = Double(frame.u(mesh.landmarks[FaceMesh.cheekLeft]) / mesh.faceWidth)
            let right = Double(frame.u(mesh.landmarks[FaceMesh.cheekRight]) / mesh.faceWidth)
            let deltaT = Double(
                frame.t(mesh.landmarks[FaceMesh.cheekLeft])
                    - frame.t(mesh.landmarks[FaceMesh.cheekRight]))
            worstSumError = max(worstSumError, abs((left - right) - 1))
            worstDeltaT = max(worstDeltaT, abs(deltaT))
            leftShare.append(left)
        }
        print(
            "P2 warp cheek split: left share \(leftShare.min()!)…\(leftShare.max()!), "
                + "worst |split − 1| \(worstSumError), worst |Δt| \(worstDeltaT)")
        // The identity holds everywhere, which is exactly why it discriminates
        // nothing: it is the two cheeks being level, not the frame being right.
        #expect(worstSumError < 0.002)
        #expect(worstDeltaT < 0.06)
        // …including on the most frontal frame in the set, where the split is
        // 0.50/−0.50 and there is no asymmetry to get right.
        #expect(leftShare.min()! < 0.51)
    }

    /// **The nose candidates ADR-0010 says were rejected, re-measured.**
    ///
    /// The claim used to be unreproducible: two candidate pairs were dropped
    /// during development and nothing in the repo backed it. The rejection rule
    /// is that an ala point must be on a known side of the face's own midline on
    /// every frame, because `FaceReshape` reads `sign(u)` to decide which way to
    /// push it. This re-runs the rule on the 11 real meshes.
    @Test("The rejected nose candidates cannot say which side of the midline they are on")
    func rejectedNoseCandidatesFailTheSideTest() {
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else { return }

        func uRange(_ index: Int) -> (min: Double, max: Double) {
            var lo = Double.infinity
            var hi = -Double.infinity
            for mesh in meshes {
                guard
                    let frame = FaceMeshFrame(
                        landmarks: mesh.landmarks, faceWidth: mesh.faceWidth)
                else { continue }
                let u = Double(frame.u(mesh.landmarks[index]) / mesh.faceWidth)
                lo = min(lo, u)
                hi = max(hi, u)
            }
            return (lo, hi)
        }

        // How much clearance the *shipped* alae keep from the midline, as the
        // yardstick the candidates are judged against.
        var shippedMargin = Double.infinity
        for index in FaceMesh.noseAlaRight { shippedMargin = min(shippedMargin, -uRange(index).max) }
        for index in FaceMesh.noseAlaLeft { shippedMargin = min(shippedMargin, uRange(index).min) }

        let candidates = [45, 275, 237, 457]
        var measured: [String] = []
        for index in candidates {
            let r = uRange(index)
            measured.append("\(index): \(r.min)…\(r.max)")
            #expect(!FaceMesh.nose.contains(index), "\(index) is in the shipped nose list")
        }
        print(
            "P2 warp rejected nose candidates u/faceWidth over \(meshes.count) meshes: "
                + measured.joined(separator: ", ")
                + "; shipped alae worst margin \(shippedMargin)")

        // 275 is on the right of the midline on some frames and the left on
        // others: its side is a function of the head's pose, not of anatomy.
        let candidate275 = uRange(275)
        #expect(candidate275.min < 0 && candidate275.max > 0)
        // 457 never crosses, but it comes far closer to the midline than any
        // shipped ala point does — under landmark noise it is a midline point,
        // not a wing.
        let candidate457 = uRange(457)
        #expect(candidate457.min > 0)
        #expect(candidate457.min < shippedMargin / 2)
        // Their partners are unremarkable; it is the pair that is unusable.
        #expect(uRange(45).max < 0)
        #expect(uRange(237).max < 0)
    }

    /// Which oval landmarks each outline slider actually moves, on a real mesh.
    /// The bands are defined by landmark-derived levels, so the membership is
    /// computed rather than listed — this test is what turns it back into a list
    /// a reviewer can read, and pins it against a silent drift.
    @Test("The outline bands land on the right part of the oval")
    func outlineBandsLandWhereExpected() throws {
        guard let mesh = FaceLandmarkFixtures.a6300.first else { return }
        let landmarks = mesh.landmarks
        func moved(_ sliders: FaceSliders) -> Set<Int> {
            Set(
                FaceReshape.handles(
                    landmarks: landmarks, faceWidth: mesh.faceWidth, sliders: sliders
                ).filter { $0.displacement > 0.05 }.map(\.index))
        }
        let cheekbone = moved(FaceSliders(cheekbone: 100))
        let jaw = moved(FaceSliders(jaw: 100))
        let chin = moved(FaceSliders(chin: 100))
        let forehead = moved(FaceSliders(forehead: 100))
        let temple = moved(FaceSliders(temple: 100))
        print(
            "P2 warp bands on \(mesh.image): cheekbone \(cheekbone.sorted()), "
                + "jaw \(jaw.sorted()), chin \(chin.sorted()), forehead \(forehead.sorted()), "
                + "temple \(temple.sorted())")

        // The cheek extremes are the definition of face width, so they must be in
        // the cheekbone band and nowhere else.
        #expect(cheekbone.contains(FaceMesh.cheekLeft) && cheekbone.contains(FaceMesh.cheekRight))
        #expect(!jaw.contains(FaceMesh.cheekLeft) || jaw.count > cheekbone.count)
        // The chin tip belongs to the chin band and not to the forehead one.
        #expect(chin.contains(FaceMesh.chin))
        #expect(!forehead.contains(FaceMesh.chin))
        // The hairline belongs to the forehead band and not to the chin one.
        #expect(forehead.contains(FaceMesh.foreheadTop))
        #expect(!chin.contains(FaceMesh.foreheadTop))
        // Temples are above the cheekbones: their band must not contain the cheek
        // extremes.
        #expect(!temple.contains(FaceMesh.cheekLeft) && !temple.contains(FaceMesh.cheekRight))
        #expect(!temple.isEmpty && !jaw.isEmpty)
    }
}

/// The geometric measurements ``FaceMeshGeometryTests`` asserts on and
/// ``WarpBenchTests`` files. Split out so the assertion and the recorded number
/// are computed by the same code.
enum FaceMeshGeometry {
    struct Report {
        var ovalEnclosedFraction: Double
        var eyeSeparationOverWidth: Double
        var eyeWidthOverWidth: Double
        var eyesStraddleTheMidline: Bool
        var eyesAboveTheMouth: Bool
        var innerLipPointsInsideOuter: Int
        var noseTRange: ClosedRange<Double>
        /// Largest `|u| / faceWidth` over the bridge and centre chains.
        var noseMidlineMaxOffset: Double
        var alaeStraddleTheMidline: Bool
        var noseWidthOverFaceWidth: Double
        var irisPointsInsideTheirEye: Int
        var regionsAreDisjoint: Bool
    }

    static func measure(landmarks: [CGPoint], faceWidth: CGFloat) -> Report? {
        guard let frame = FaceMeshFrame(landmarks: landmarks, faceWidth: faceWidth) else {
            return nil
        }
        let ovalRing = FaceMesh.faceOval.map { landmarks[$0] }
        let ovalSet = Set(FaceMesh.faceOval)
        var enclosed = 0
        var others = 0
        for index in 0..<landmarks.count where !ovalSet.contains(index) {
            others += 1
            if pointInPolygon(landmarks[index], ovalRing) { enclosed += 1 }
        }

        let groups = FaceReshape.eyeGroups(landmarks: landmarks, frame: frame)
        let separation = hypot(
            groups[0].centre.x - groups[1].centre.x, groups[0].centre.y - groups[1].centre.y)
        let eyeWidth = hypot(
            landmarks[FaceMesh.eyeInnerRight].x - landmarks[FaceMesh.eyeOuterRight].x,
            landmarks[FaceMesh.eyeInnerRight].y - landmarks[FaceMesh.eyeOuterRight].y)
        let straddle = frame.u(groups[0].centre) * frame.u(groups[1].centre) < 0
        let aboveMouth = groups.allSatisfy { frame.t($0.centre) < frame.tMouthLine }

        let outerRing = FaceMesh.lipsOuter.map { landmarks[$0] }
        let innerInside = FaceMesh.lipsInner.filter {
            pointInPolygon(landmarks[$0], outerRing)
        }.count

        var noseLow = Double.infinity
        var noseHigh = -Double.infinity
        for index in FaceMesh.nose {
            let t = Double(frame.t(landmarks[index]))
            noseLow = min(noseLow, t)
            noseHigh = max(noseHigh, t)
        }
        var midlineOffset = 0.0
        for index in FaceMesh.noseBridge + FaceMesh.noseCentre {
            midlineOffset = max(
                midlineOffset, Double(abs(frame.u(landmarks[index])) / faceWidth))
        }
        let rightU = FaceMesh.noseAlaRight.map { frame.u(landmarks[$0]) }
        let leftU = FaceMesh.noseAlaLeft.map { frame.u(landmarks[$0]) }
        let straddleAlae = (rightU.max() ?? 0) < 0 && (leftU.min() ?? 0) > 0
        let noseWidth =
            Double(((leftU.max() ?? 0) - (rightU.min() ?? 0)) / faceWidth)

        var irisInside = 0
        for group in groups {
            let ring = group.indices.filter { !FaceMesh.irisPoints.contains($0) }
            let radius = ring.map {
                hypot(landmarks[$0].x - group.centre.x, landmarks[$0].y - group.centre.y)
            }.max() ?? 0
            for iris in group.indices where FaceMesh.irisPoints.contains(iris) {
                let d = hypot(
                    landmarks[iris].x - group.centre.x, landmarks[iris].y - group.centre.y)
                if d <= radius { irisInside += 1 }
            }
        }

        let regions: [Set<Int>] = [
            Set(FaceMesh.faceOval),
            Set(FaceMesh.eyeRingLeft).union(FaceMesh.eyeRingRight).union(FaceMesh.irisPoints),
            Set(FaceMesh.lipsOuter).union(FaceMesh.lipsInner),
            Set(FaceMesh.nose),
        ]
        var disjoint = true
        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count where !regions[i].isDisjoint(with: regions[j]) {
                disjoint = false
            }
        }
        // …and no list repeats an index inside itself.
        if Set(FaceMesh.allHandleIndices).count != FaceMesh.allHandleIndices.count {
            disjoint = false
        }

        return Report(
            ovalEnclosedFraction: others > 0 ? Double(enclosed) / Double(others) : 0,
            eyeSeparationOverWidth: Double(separation / faceWidth),
            eyeWidthOverWidth: Double(eyeWidth / faceWidth),
            eyesStraddleTheMidline: straddle,
            eyesAboveTheMouth: aboveMouth,
            innerLipPointsInsideOuter: innerInside,
            noseTRange: noseLow...noseHigh,
            noseMidlineMaxOffset: midlineOffset,
            alaeStraddleTheMidline: straddleAlae,
            noseWidthOverFaceWidth: noseWidth,
            irisPointsInsideTheirEye: irisInside,
            regionsAreDisjoint: disjoint)
    }

    static func pointInPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
                p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
