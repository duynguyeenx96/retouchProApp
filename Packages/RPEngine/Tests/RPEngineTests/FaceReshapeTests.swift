import CoreGraphics
import Foundation
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — the "Mặt" group's maths. Pure CPU, no GPU, no fixtures: every
/// property here must hold for **any** face, so it is tested on
/// ``SyntheticFaceMesh`` and runs on a machine with no `Research/` directory.
///
/// Not `.serialized` and it takes no flag lock: nothing in this suite touches
/// `RPEngineFeatureFlags` (`FaceReshape` and `FaceSliders` are unflagged value
/// types — the flag gates the *node*, which is where the GPU work is).
@Suite("Phase 2 face reshape maths")
struct FaceReshapeTests {
    static let width: CGFloat = 600
    static let centre = CGPoint(x: 900, y: 700)

    static var landmarks: [CGPoint] {
        SyntheticFaceMesh.make(width: width, centre: centre)
    }
    static var face: FaceRenderInput {
        SyntheticFaceMesh.renderInput(width: width, centre: centre)
    }
    static var frame: FaceMeshFrame {
        FaceMeshFrame(landmarks: landmarks, faceWidth: SyntheticFaceMesh.faceWidth(of: landmarks))!
    }

    /// Every slider at a mid value, so no term of the accumulation is skipped.
    static let allSliders = FaceSliders(
        slim: 60, cheekbone: 40, jaw: 55, chin: 35, forehead: 30, temple: 45,
        noseShrink: 50, noseBridge: 40, noseTip: 45,
        eyeSize: 50, eyeSpacing: 35, eyeTilt: 40,
        mouthSize: 30, mouthSmile: 50, lipFullness: 45)

    static func handles(_ sliders: FaceSliders, landmarks: [CGPoint]? = nil) -> [FaceReshape.Handle] {
        let points = landmarks ?? Self.landmarks
        return FaceReshape.handles(
            landmarks: points, faceWidth: SyntheticFaceMesh.faceWidth(of: points),
            sliders: sliders)
    }

    static func moved(_ handles: [FaceReshape.Handle]) -> Set<Int> {
        Set(handles.filter { $0.displacement > 1e-9 }.map(\.index))
    }
    static func touched(_ handles: [FaceReshape.Handle]) -> Set<Int> {
        Set(handles.map(\.index))
    }
    static func handle(_ handles: [FaceReshape.Handle], _ index: Int) -> FaceReshape.Handle? {
        handles.first { $0.index == index }
    }

    // MARK: - EditState contract

    @Test("Every Mặt slider round-trips through EditState and clamps to 0…100")
    func slidersRoundTripThroughEditState() {
        let sliders = Self.allSliders
        var state = EditState()
        sliders.write(into: &state)
        #expect(FaceSliders(state) == sliders)
        #expect(FaceSliders.Key.all.count == 15)
        #expect(Set(FaceSliders.Key.all).count == 15)
        #expect(sliders.values.count == 15)

        #expect(FaceSliders(slim: 400).slim == 100)
        #expect(FaceSliders(slim: -10).slim == 0)
        #expect(FaceSliders(slim: .nan).slim == 0)

        // A zeroed slider leaves no key behind (EditSection.setSlider's contract),
        // so "absent" and "0" are the same document.
        var zeroed = state
        FaceSliders().write(into: &zeroed)
        #expect(zeroed.isDefault)

        // …and the group writes into `face`, not into `skin`.
        var only = EditState()
        FaceSliders(slim: 50).write(into: &only)
        #expect(only[section: EditState.SectionKey.face].slider(FaceSliders.Key.slim) == 50)
        #expect(only[section: EditState.SectionKey.skin].isEmpty)
        #expect(SkinSliders(only).isIdentity)
    }

    @Test("All fifteen sliders at 0 produce no handles at all")
    func zeroSlidersProduceNoHandles() {
        #expect(FaceSliders().isIdentity)
        #expect(Self.handles(FaceSliders()).isEmpty)
        #expect(
            FaceReshape.controlPoints(
                faces: [Self.face], sliders: FaceSliders(),
                imageSize: CGSize(width: 1800, height: 1400)) == nil)
        // …and one slider off zero is enough to make it non-identity.
        for (offset, _) in FaceSliders().values.enumerated() {
            var state = EditState()
            state.setSlider(
                FaceSliders.Key.all[offset], in: EditState.SectionKey.face, to: 1)
            #expect(!FaceSliders(state).isIdentity, "\(FaceSliders.Key.all[offset])")
        }
    }

    @Test("A mesh that is too short, or a zero-width face, produces no handles")
    func degenerateFacesProduceNoHandles() {
        // `faceWidth` is supplied rather than measured here: measuring it needs
        // landmark 454, which a 400-point array does not have.
        #expect(
            FaceReshape.handles(
                landmarks: Array(Self.landmarks.prefix(400)), faceWidth: 600,
                sliders: Self.allSliders
            ).isEmpty)
        #expect(
            FaceReshape.handles(
                landmarks: Self.landmarks, faceWidth: 0, sliders: Self.allSliders
            ).isEmpty)
        #expect(
            FaceReshape.handles(
                landmarks: Self.landmarks, faceWidth: .nan, sliders: Self.allSliders
            ).isEmpty)
        // A face whose forehead and chin coincide has no axis.
        var flat = Self.landmarks
        flat[FaceMesh.chin] = flat[FaceMesh.foreheadTop]
        #expect(
            FaceReshape.handles(landmarks: flat, faceWidth: 600, sliders: Self.allSliders).isEmpty)
    }

    // MARK: - The face-width rule

    /// docs/PLAN.md §2's fixed decision, stated as an equation:
    /// `f(k · landmarks, k · faceWidth) == k · f(landmarks, faceWidth)`.
    ///
    /// This is what makes a "Mặt" preset transfer between images and makes a
    /// 2048 px preview and a 24 MP export the same *shape*. A single pixel
    /// constant anywhere in `FaceReshape` breaks it, and nothing else in the
    /// suite would notice.
    @Test("Displacements scale exactly with the face", arguments: [0.25, 1.0, 3.7, 11.0])
    func displacementsScaleWithTheFace(scale: Double) {
        let k = CGFloat(scale)
        let base = Self.handles(Self.allSliders)
        let scaledPoints = SyntheticFaceMesh.make(
            width: Self.width * k, centre: CGPoint(x: Self.centre.x * k, y: Self.centre.y * k))
        let scaled = Self.handles(Self.allSliders, landmarks: scaledPoints)

        #expect(base.count == scaled.count)
        #expect(base.map(\.index) == scaled.map(\.index))
        var worst = 0.0
        for (a, b) in zip(base, scaled) {
            let expectedX = (a.destination.x - a.source.x) * k
            let expectedY = (a.destination.y - a.source.y) * k
            worst = max(
                worst,
                Double(hypot(
                    (b.destination.x - b.source.x) - expectedX,
                    (b.destination.y - b.source.y) - expectedY)))
        }
        let tolerance = 1e-9 * Double(Self.width * k)
        #expect(worst < tolerance, "scale \(k): worst \(worst) px, tolerance \(tolerance)")
    }

    /// The frame is built from `p[10] → p[152]`, so a rolled head must reshape
    /// along its own axes. If any direction were taken from the image's x/y the
    /// magnitudes would change with the roll.
    @Test("A rolled face gets the same reshape, rotated with it")
    func reshapeFollowsTheHeadRoll() {
        let upright = Self.handles(Self.allSliders)
        let rolled = Self.handles(
            Self.allSliders,
            landmarks: SyntheticFaceMesh.make(
                width: Self.width, centre: Self.centre, rotation: 0.4))
        #expect(upright.map(\.index) == rolled.map(\.index))
        var worst = 0.0
        for (a, b) in zip(upright, rolled) {
            worst = max(worst, Double(abs(a.displacement - b.displacement)))
        }
        #expect(worst < 1e-9 * Double(Self.width), "worst \(worst) px")
    }

    // MARK: - Which landmarks each slider touches

    /// The mapping, stated as a table. A wrong index list still produces a warp —
    /// of the wrong part of the face — with every other number in this project
    /// still green, so it is asserted rather than reviewed.
    @Test(
        "Each slider touches exactly its own region",
        arguments: [
            ("slim", FaceSliders(slim: 100), Set(FaceMesh.faceOval)),
            ("cheekbone", FaceSliders(cheekbone: 100), Set(FaceMesh.faceOval)),
            ("jaw", FaceSliders(jaw: 100), Set(FaceMesh.faceOval)),
            ("chin", FaceSliders(chin: 100), Set(FaceMesh.faceOval)),
            ("forehead", FaceSliders(forehead: 100), Set(FaceMesh.faceOval)),
            ("temple", FaceSliders(temple: 100), Set(FaceMesh.faceOval)),
            ("noseShrink", FaceSliders(noseShrink: 100), Set(FaceMesh.nose)),
            ("noseBridge", FaceSliders(noseBridge: 100), Set(FaceMesh.nose)),
            ("noseTip", FaceSliders(noseTip: 100), Set(FaceMesh.nose)),
            ("eyeSize", FaceSliders(eyeSize: 100), FaceReshapeTests.eyeRegion),
            ("eyeSpacing", FaceSliders(eyeSpacing: 100), FaceReshapeTests.eyeRegion),
            ("eyeTilt", FaceSliders(eyeTilt: 100), FaceReshapeTests.eyeRegion),
            ("mouthSize", FaceSliders(mouthSize: 100), FaceReshapeTests.mouthRegion),
            ("mouthSmile", FaceSliders(mouthSmile: 100), FaceReshapeTests.mouthRegion),
            ("lipFullness", FaceSliders(lipFullness: 100), FaceReshapeTests.mouthRegion),
        ])
    func eachSliderTouchesItsOwnRegion(name: String, sliders: FaceSliders, region: Set<Int>) {
        let handles = Self.handles(sliders)
        #expect(Self.touched(handles) == region, "\(name) touched the wrong set")
        let moved = Self.moved(handles)
        #expect(!moved.isEmpty, "\(name) moved nothing")
        #expect(moved.isSubset(of: region), "\(name) moved outside its region")
    }

    static let eyeRegion: Set<Int> = {
        var set = Set(FaceMesh.eyeRingRight)
        set.formUnion(FaceMesh.eyeRingLeft)
        set.formUnion(FaceMesh.irisPoints)
        return set
    }()
    static let mouthRegion: Set<Int> = {
        var set = Set(FaceMesh.lipsOuter)
        set.formUnion(FaceMesh.lipsInner)
        return set
    }()

    /// "Môi đầy" thickens the lip without opening the mouth — which is only true
    /// because the inner ring is a pinned identity handle. It is the clearest
    /// example of why an unmoved handle is not a wasted one.
    @Test("Lip fullness moves the outer ring only and pins the mouth opening")
    func lipFullnessPinsTheInnerRing() {
        let handles = Self.handles(FaceSliders(lipFullness: 100))
        #expect(Self.moved(handles).isSubset(of: Set(FaceMesh.lipsOuter)))
        for index in FaceMesh.lipsInner {
            let handle = Self.handle(handles, index)
            #expect(handle != nil, "inner lip \(index) missing")
            #expect((handle?.displacement ?? 1) < 1e-9, "inner lip \(index) moved")
        }
        // …and the outer ring really does grow in height: the top of the upper
        // lip goes up and the bottom of the lower lip goes down.
        let frame = Self.frame
        let top = Self.handle(handles, 0)!       // upper lip centre, outer
        let bottom = Self.handle(handles, 17)!   // lower lip centre, outer
        #expect(frame.t(top.destination) < frame.t(top.source))
        #expect(frame.t(bottom.destination) > frame.t(bottom.source))
    }

    /// Every slider's direction, in one place. Each is stated in the face's own
    /// frame (`t` down the axis, `u` across it), which is the frame the doc
    /// comments promise.
    @Test("Every slider moves the face the way its name says")
    func slidersMoveInTheDocumentedDirection() {
        let frame = Self.frame
        let points = Self.landmarks

        // Bóp mặt: the jaw comes in, the forehead does not move.
        let slim = Self.handles(FaceSliders(slim: 100))
        for index in [288, 58, 397, 172] {  // jaw, both sides
            let h = Self.handle(slim, index)!
            #expect(abs(frame.u(h.destination)) < abs(frame.u(h.source)), "slim \(index)")
        }
        #expect(Self.handle(slim, FaceMesh.foreheadTop)!.displacement < 1e-9)

        // Gò má: the cheek extremes come in; the jaw barely does.
        let cheek = Self.handles(FaceSliders(cheekbone: 100))
        for index in [FaceMesh.cheekLeft, FaceMesh.cheekRight] {
            let h = Self.handle(cheek, index)!
            #expect(abs(frame.u(h.destination)) < abs(frame.u(h.source)), "cheekbone \(index)")
        }
        #expect(
            Self.handle(cheek, FaceMesh.cheekLeft)!.displacement
                > Self.handle(cheek, 288)!.displacement)

        // Hàm: the jaw comes in more than the cheekbone does.
        let jaw = Self.handles(FaceSliders(jaw: 100))
        #expect(
            Self.handle(jaw, 288)!.displacement > Self.handle(jaw, FaceMesh.cheekLeft)!.displacement)

        // Cằm: the chin rises; the forehead does not move.
        let chin = Self.handles(FaceSliders(chin: 100))
        let chinTip = Self.handle(chin, FaceMesh.chin)!
        #expect(frame.t(chinTip.destination) < frame.t(chinTip.source))
        #expect(Self.handle(chin, FaceMesh.foreheadTop)!.displacement < 1e-9)

        // Trán: the hairline drops; the chin does not move.
        let forehead = Self.handles(FaceSliders(forehead: 100))
        let hairline = Self.handle(forehead, FaceMesh.foreheadTop)!
        #expect(frame.t(hairline.destination) > frame.t(hairline.source))
        #expect(Self.handle(forehead, FaceMesh.chin)!.displacement < 1e-9)

        // Thái dương: the temples push out, they do not come in.
        let temple = Self.handles(FaceSliders(temple: 100))
        for index in [251, 21] {
            let h = Self.handle(temple, index)!
            #expect(abs(frame.u(h.destination)) > abs(frame.u(h.source)), "temple \(index)")
        }

        // Mũi thu nhỏ: every nose point moves toward the nose centroid.
        let noseCentroid = FaceReshape.centroid(of: FaceMesh.nose, in: points)
        let shrink = Self.handles(FaceSliders(noseShrink: 100))
        for handle in shrink {
            let before = hypot(handle.source.x - noseCentroid.x, handle.source.y - noseCentroid.y)
            let after = hypot(
                handle.destination.x - noseCentroid.x, handle.destination.y - noseCentroid.y)
            #expect(after <= before + 1e-9, "noseShrink \(handle.index)")
        }

        // Mũi sống: the bridge narrows more than the tip does.
        let bridge = Self.handles(FaceSliders(noseBridge: 100))
        #expect(
            Self.handle(bridge, FaceMesh.noseAlaLeft[0])!.displacement
                > Self.handle(bridge, FaceMesh.noseAlaLeft[9])!.displacement)

        // Mũi đầu: the tip rises.
        let tip = Self.handles(FaceSliders(noseTip: 100))
        let noseTip = Self.handle(tip, FaceMesh.noseTip)!
        #expect(frame.t(noseTip.destination) < frame.t(noseTip.source))

        // Mắt to: every eye point moves away from its own eye's centre.
        let eyeGroups = FaceReshape.eyeGroups(landmarks: points, frame: frame)
        let bigger = Self.handles(FaceSliders(eyeSize: 100))
        for eye in eyeGroups {
            for index in eye.indices {
                let h = Self.handle(bigger, index)!
                let before = hypot(h.source.x - eye.centre.x, h.source.y - eye.centre.y)
                let after = hypot(
                    h.destination.x - eye.centre.x, h.destination.y - eye.centre.y)
                #expect(after >= before - 1e-9, "eyeSize \(index)")
            }
        }

        // Mắt khoảng cách: the two eyes move apart.
        let spaced = Self.handles(FaceSliders(eyeSpacing: 100))
        for eye in eyeGroups {
            let h = Self.handle(spaced, eye.indices[0])!
            #expect(abs(frame.u(h.destination)) > abs(frame.u(h.source)))
        }

        // Mắt nghiêng: the outer corner rises and the inner corner drops, on both
        // eyes — which is the only assertion that catches a sign taken from a
        // naming convention rather than from the geometry.
        let tilted = Self.handles(FaceSliders(eyeTilt: 100))
        for outer in [FaceMesh.eyeOuterRight, FaceMesh.eyeOuterLeft] {
            let h = Self.handle(tilted, outer)!
            #expect(frame.t(h.destination) < frame.t(h.source), "eyeTilt outer \(outer)")
        }
        for inner in [FaceMesh.eyeInnerRight, FaceMesh.eyeInnerLeft] {
            let h = Self.handle(tilted, inner)!
            #expect(frame.t(h.destination) > frame.t(h.source), "eyeTilt inner \(inner)")
        }

        // Miệng to: every lip point moves away from the mouth centre.
        let mouth = FaceReshape.mouthGroup(landmarks: points, frame: frame)!
        let bigMouth = Self.handles(FaceSliders(mouthSize: 100))
        for index in mouth.indices {
            let h = Self.handle(bigMouth, index)!
            let before = hypot(h.source.x - mouth.centre.x, h.source.y - mouth.centre.y)
            let after = hypot(
                h.destination.x - mouth.centre.x, h.destination.y - mouth.centre.y)
            #expect(after >= before - 1e-9, "mouthSize \(index)")
        }

        // Miệng cười: the corners rise and the centre of the lip does not.
        let smile = Self.handles(FaceSliders(mouthSmile: 100))
        for corner in [FaceMesh.mouthCornerRight, FaceMesh.mouthCornerLeft] {
            let h = Self.handle(smile, corner)!
            #expect(frame.t(h.destination) < frame.t(h.source), "smile corner \(corner)")
        }
        #expect(
            Self.handle(smile, FaceMesh.mouthCornerLeft)!.displacement
                > Self.handle(smile, 0)!.displacement * 4)
    }

    /// The iris rings are assigned by distance, so a mesh whose iris points are
    /// laid out in the *opposite* order to MediaPipe's naming still gets each
    /// iris scaled with the eye it sits in. `SyntheticFaceMesh` lays them out
    /// that way on purpose.
    @Test("Iris points follow the eye they sit in, not the naming convention")
    func irisPointsFollowTheirOwnEye() {
        let points = Self.landmarks
        let groups = FaceReshape.eyeGroups(landmarks: points, frame: Self.frame)
        for group in groups {
            let irises = group.indices.filter { FaceMesh.irisPoints.contains($0) }
            #expect(irises.count == 5, "expected 5 iris points per eye, got \(irises.count)")
            for iris in irises {
                let toOwn = hypot(
                    points[iris].x - group.centre.x, points[iris].y - group.centre.y)
                let other = groups.first { $0.centre != group.centre }!
                let toOther = hypot(
                    points[iris].x - other.centre.x, points[iris].y - other.centre.y)
                #expect(toOwn < toOther, "iris \(iris) attached to the far eye")
            }
        }
    }

    // MARK: - Accumulation and control points

    /// Two sliders on the same landmark must add, not overwrite. If they
    /// overwrote, the last slider in the declaration order would silently win and
    /// a preset would render differently from the panel that made it.
    @Test("Overlapping sliders accumulate on the landmarks they share")
    func overlappingSlidersAccumulate() {
        let slim = Self.handles(FaceSliders(slim: 100))
        let jaw = Self.handles(FaceSliders(jaw: 100))
        let both = Self.handles(FaceSliders(slim: 100, jaw: 100))
        for index in [288, 58, 172, 397] {
            let a = Self.handle(slim, index)!
            let b = Self.handle(jaw, index)!
            let c = Self.handle(both, index)!
            // Both pull toward the midline, and `towardMidline` caps at half the
            // point's own distance, so the sum is an upper bound rather than an
            // identity — but it must be strictly more than either alone.
            #expect(c.displacement > max(a.displacement, b.displacement), "\(index)")
            #expect(c.displacement <= a.displacement + b.displacement + 1e-9, "\(index)")
        }
    }

    /// A lateral slider must never drag a point across the face's own midline,
    /// whatever the slider value — otherwise the jaw inverts at 100.
    @Test("No lateral slider can pull a landmark across the midline")
    func lateralSlidersNeverCrossTheMidline() {
        let frame = Self.frame
        let handles = Self.handles(
            FaceSliders(slim: 100, cheekbone: 100, jaw: 100, noseBridge: 100, noseTip: 100))
        for handle in handles {
            let before = frame.u(handle.source)
            let after = frame.u(handle.destination)
            guard abs(before) > 1e-6 else { continue }
            #expect(before.sign == after.sign, "landmark \(handle.index) crossed the midline")
            #expect(abs(after) >= abs(before) * 0.5 - 1e-6, "landmark \(handle.index) overshot")
        }
    }

    @Test("Control points carry the mandatory border anchors and nothing else extra")
    func controlPointsPinTheBorder() throws {
        let size = CGSize(width: 1800, height: 1400)
        let built = try #require(
            FaceReshape.controlPoints(
                faces: [Self.face], sliders: Self.allSliders, imageSize: size))
        // 2 * (perEdge + 1) + 2 * (perEdge - 1) = 10 + 6 = 16… plus the corners
        // shared by the top/bottom rows: `borderAnchors` emits 2*(n+1) + 2*(n-1).
        let expected = 2 * (FaceReshape.borderAnchorsPerEdge + 1)
            + 2 * (FaceReshape.borderAnchorsPerEdge - 1)
        #expect(built.borderAnchorCount == expected)
        #expect(built.control.count == built.handles.count + expected)
        #expect(built.movedHandleCount > 0)
        #expect(built.movedHandleCount <= built.handles.count)
        #expect(built.maxDisplacement > 0)

        // Every anchor is on the border and is an identity handle.
        for i in built.handles.count..<built.control.count {
            let p = built.control.source[i]
            #expect(built.control.destination[i] == p)
            let onBorder = p.x == 0 || p.y == 0 || p.x == size.width || p.y == size.height
            #expect(onBorder, "\(p)")
        }
    }

    @Test("Two faces each contribute their own handles")
    func twoFacesEachContribute() throws {
        let a = SyntheticFaceMesh.renderInput(width: 300, centre: CGPoint(x: 400, y: 500))
        let b = SyntheticFaceMesh.renderInput(width: 220, centre: CGPoint(x: 1200, y: 520))
        let one = try #require(
            FaceReshape.controlPoints(
                faces: [a], sliders: Self.allSliders,
                imageSize: CGSize(width: 1600, height: 1000)))
        let two = try #require(
            FaceReshape.controlPoints(
                faces: [a, b], sliders: Self.allSliders,
                imageSize: CGSize(width: 1600, height: 1000)))
        #expect(two.handles.count == one.handles.count * 2)
        // The smaller face gets proportionally smaller displacements — the same
        // face-width rule, this time across two faces in one frame.
        let ratio = Double(two.maxDisplacement / one.maxDisplacement)
        #expect(abs(ratio - 1) < 1e-9, "the larger face must still set the maximum: \(ratio)")
    }

    @Test("The S3 warp configuration is what the node will ask for")
    func optionsCarryTheS3Constraints() {
        let preview = FaceReshape.options(for: .preview)
        let export = FaceReshape.options(for: .export)
        #expect(preview.gridWidth == 65 && preview.gridHeight == 65)
        #expect(export.gridWidth == 129 && export.gridHeight == 129)
        #expect(preview.variant == .similarity && export.variant == .similarity)
        #expect(preview.alpha == 2.0)
        #expect(FaceReshape.borderAnchorsPerEdge == 4)
    }

    // MARK: - Weight curves

    @Test("The band and ramp weights are bounded, monotone and continuous")
    func weightCurvesBehave() {
        for i in 0...100 {
            let x = CGFloat(i) / 100
            let ramp = FaceMeshFrame.ramp(x, from: 0.2, to: 0.8)
            #expect(ramp >= 0 && ramp <= 1)
            let band = FaceMeshFrame.band(x, centre: 0.5, halfWidth: 0.2)
            #expect(band >= 0 && band <= 1)
        }
        #expect(FaceMeshFrame.ramp(0.1, from: 0.2, to: 0.8) == 0)
        #expect(FaceMeshFrame.ramp(0.9, from: 0.2, to: 0.8) == 1)
        #expect(abs(FaceMeshFrame.band(0.5, centre: 0.5, halfWidth: 0.2) - 1) < 1e-12)
        #expect(FaceMeshFrame.band(0.7, centre: 0.5, halfWidth: 0.2) < 1e-12)
        // A degenerate band must not divide by zero.
        #expect(FaceMeshFrame.band(0.5, centre: 0.5, halfWidth: 0) == 1)
        #expect(FaceMeshFrame.ramp(0.5, from: 0.5, to: 0.5) == 1)
    }
}
