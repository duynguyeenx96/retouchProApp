import CoreGraphics
import Foundation
import RPEngine
import RPVision
import Testing

/// Tests for `App/FaceAnalysisRenderBridge.swift`.
///
/// ## Why this target exists
///
/// The bridge is the one piece of coordinate-space work in the project that no
/// package test could reach. It lives in the app target because `RPEngine`
/// deliberately does not import `RPVision` (the bridge's own doc comment says
/// why: `FaceAnalysis` is only reachable through the Core ML model wrappers, and
/// a render graph that links Core ML cannot be unit-tested on a machine with no
/// models). That put `renderInputs(from:renderScale:kinds:)` and
/// `renderScale(for:renderedLongEdge:)` — mask transforms, the preview downscale,
/// and the feathered-vs-hard mask choice — outside every test target in the
/// project.
///
/// ## Why it compiles the bridge instead of hosting the app
///
/// The target has **no `TEST_HOST`**; it compiles `App/FaceAnalysisRenderBridge.swift`
/// into itself (the file is listed in this target's Sources phase in
/// `RetouchPro.xcodeproj`) and links `RPEngine`/`RPVision` once. A host-app test
/// bundle would have to link the same static package products a second time,
/// leaving two copies of every RPEngine/RPVision type in one process; and it
/// would launch the SwiftUI app to test a pure function over value types. The
/// source under test is the same file the app builds, so a change to the bridge
/// is caught either way.
///
/// The fixture below is a fabricated `FaceAnalysis` — no models, no GPU, no
/// images — so this runs identically on macOS and on the iOS Simulator.
@Suite("App — FaceAnalysis → FaceRenderInput bridge")
struct FaceAnalysisRenderBridgeTests {

    // MARK: - Fixture

    /// Mask side used by every fixture face. Small enough to build by hand,
    /// large enough that a feather has somewhere to ramp.
    static let maskSide = 64

    /// A hand-built parsing map: hair band across the top, a skin block in the
    /// middle, and every other part drawn inside it.
    ///
    /// Every one of the ten `FaceParsingGroup`s is a **non-empty rectangle with a
    /// boundary and none of them overlap** — later `fill` calls overwrite earlier
    /// ones, so an overlap would silently erase a class and leave a group with an
    /// all-zero mask, for which `feathered == hardMask` and the "always feathered"
    /// assertion below would pass vacuously. (That is not hypothetical: the first
    /// version of this fixture drew the eyeglasses band over both eyes.)
    /// `everyMaskIsFeathered` asserts `feathered != hard` per group, which is what
    /// keeps this property honest.
    static func labels() -> [UInt8] {
        let side = maskSide
        var labels = [UInt8](repeating: FaceParsingClass.background.rawValue, count: side * side)
        func fill(_ cls: FaceParsingClass, x: Range<Int>, y: Range<Int>) {
            for row in y {
                for column in x { labels[row * side + column] = cls.rawValue }
            }
        }
        fill(.hair, x: 8..<56, y: 4..<16)
        fill(.skin, x: 12..<52, y: 16..<52)
        // Glasses are the two temple pieces only, so they do not sit on the eyes.
        fill(.eyeglasses, x: 13..<17, y: 22..<32)
        fill(.eyeglasses, x: 47..<51, y: 22..<32)
        fill(.leftBrow, x: 18..<26, y: 19..<22)
        fill(.rightBrow, x: 38..<46, y: 19..<22)
        fill(.leftEye, x: 18..<26, y: 24..<30)
        fill(.rightEye, x: 38..<46, y: 24..<30)
        fill(.nose, x: 29..<35, y: 30..<38)
        fill(.upperLip, x: 26..<38, y: 40..<43)
        fill(.mouth, x: 26..<38, y: 43..<45)
        fill(.lowerLip, x: 26..<38, y: 45..<48)
        fill(.leftEar, x: 8..<12, y: 26..<36)
        fill(.rightEar, x: 52..<56, y: 26..<36)
        fill(.neck, x: 22..<42, y: 52..<62)
        return labels
    }

    /// One face whose geometry is exactly known.
    ///
    /// The landmark crop has `side == FaceCrop.outputSide` and no rotation, so
    /// crop pixels map to image pixels 1:1 with a pure translation and the cheek
    /// landmarks (MediaPipe 234 / 454) end up `cheekSpan` apart in image pixels —
    /// i.e. `AnalyzedFace.faceWidth == cheekSpan`, with no arithmetic to get
    /// wrong on the test side.
    static func face(
        center: CGPoint, cheekSpan: CGFloat, maskCenter: CGPoint, maskSide side: CGFloat,
        maskRotation: CGFloat = 0, includeParsing: Bool = true
    ) -> AnalyzedFace {
        let crop = FaceCrop(center: center, side: FaceCrop.outputSide, rotation: 0)
        let half = FaceCrop.outputSide / 2
        var points = [CGPoint](repeating: CGPoint(x: half, y: half), count: FaceLandmarks478.pointCount)
        points[FaceMeshIndex.cheekRight] = CGPoint(x: half - cheekSpan / 2, y: half)
        points[FaceMeshIndex.cheekLeft] = CGPoint(x: half + cheekSpan / 2, y: half)
        points[FaceMeshIndex.chin] = CGPoint(x: half, y: half + 40)
        points[FaceMeshIndex.foreheadTop] = CGPoint(x: half, y: half - 40)

        let region = CropRegion(
            center: maskCenter, side: side, rotation: maskRotation, outputSide: maskSide)
        let parsing =
            includeParsing
            ? ParsedFace(
                mask: FaceParsingMask(width: maskSide, height: maskSide, labels: labels()),
                region: region)
            : nil

        return AnalyzedFace(
            visionBox: CGRect(
                x: center.x - cheekSpan / 2, y: center.y - cheekSpan / 2,
                width: cheekSpan, height: cheekSpan),
            detectorRegion: CropRegion(
                center: center, side: cheekSpan * 3.5, rotation: 0, outputSide: 128),
            detection: BlazeFaceDetection(
                boundingBox: CGRect(
                    x: center.x - cheekSpan / 2, y: center.y - cheekSpan / 2,
                    width: cheekSpan, height: cheekSpan),
                keypoints: [CGPoint](repeating: center, count: BlazeFaceDetection.keypointCount),
                score: 0.99),
            landmarks: FaceLandmarks478(
                cropPoints: points,
                depths: [CGFloat](repeating: 0, count: FaceLandmarks478.pointCount),
                score: 0.99, crop: crop),
            parsing: parsing)
    }

    /// A 6000 x 4000 frame — the a6300's aspect, so `renderScale` is exercised
    /// with the number a real preview would produce.
    static func analysis(_ faces: [AnalyzedFace]) -> FaceAnalysis {
        FaceAnalysis(
            imageSize: CGSize(width: 6000, height: 4000), faces: faces,
            options: FaceAnalyzerOptions())
    }

    static var singleFace: FaceAnalysis {
        analysis([
            face(
                center: CGPoint(x: 2400, y: 1500), cheekSpan: 200,
                maskCenter: CGPoint(x: 2400, y: 1500), maskSide: 400)
        ])
    }

    // MARK: - Fixture sanity

    /// If a future edit to `labels()` overlaps two classes, the group that loses
    /// goes all-zero and several assertions below become vacuously true. Say so
    /// here, once, with a message that names the group.
    @Test("The fixture parsing map has every group present and none of them full")
    func fixtureCoversEveryGroup() {
        let mask = FaceParsingMask(
            width: Self.maskSide, height: Self.maskSide, labels: Self.labels())
        for group in FaceParsingGroup.allCases {
            let count = mask.binaryMask(for: group).count { $0 == 255 }
            #expect(count > 0, "fixture has no pixels for \(group)")
            #expect(count < Self.maskSide * Self.maskSide, "fixture is entirely \(group)")
        }
    }

    // MARK: - renderScale

    @Test("renderScale is renderedLongEdge / analysedLongEdge, from the long edge either way round")
    func renderScaleUsesTheLongEdge() {
        let landscape = Self.singleFace
        #expect(
            FaceAnalysisRenderBridge.renderScale(for: landscape, renderedLongEdge: 2048)
                == 2048.0 / 6000.0)

        // Portrait: the long edge is the height, so the same answer must come out
        // of the other component — a `width`-only implementation passes the case
        // above and fails this one.
        let portrait = FaceAnalysis(
            imageSize: CGSize(width: 4000, height: 6000), faces: landscape.faces,
            options: FaceAnalyzerOptions())
        #expect(
            FaceAnalysisRenderBridge.renderScale(for: portrait, renderedLongEdge: 2048)
                == 2048.0 / 6000.0)

        // An analysis with no image size must not divide by zero and must not
        // silently scale everything to nothing.
        let degenerate = FaceAnalysis(
            imageSize: .zero, faces: [], options: FaceAnalyzerOptions())
        #expect(FaceAnalysisRenderBridge.renderScale(for: degenerate, renderedLongEdge: 2048) == 1)
    }

    // MARK: - Geometry at scale 1

    @Test("At scale 1 the bridge copies RPVision's geometry verbatim")
    func unscaledGeometryMatchesTheAnalysis() throws {
        let analysis = Self.singleFace
        let inputs = FaceAnalysisRenderBridge.renderInputs(from: analysis)
        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        let source = try #require(analysis.faces.first)

        #expect(input.faceWidth == source.faceWidth)
        #expect(input.faceWidth == 200)  // the fixture's cheek span, by construction
        #expect(input.landmarks == source.imagePoints)

        let parsing = try #require(source.parsing)
        let mask = try #require(input.masks[.skin])
        #expect(mask.width == parsing.mask.width)
        #expect(mask.height == parsing.mask.height)
        // The exact claim in the bridge: `maskToImage` is `region.outputToImage`.
        #expect(mask.maskToImage == parsing.region.outputToImage)
    }

    /// The mask must be the **feathered** coverage, never `hardMask`.
    ///
    /// Spike S2 §4 measured eye IoU at 0.84 and proved it is the checkpoint's
    /// ceiling — a ~1 px boundary error on a ~15 px object — which is invisible
    /// through a soft mask and obvious through a hard one
    /// (`FaceParsingGroup.requiresFeatheredMask`). This is the assertion that
    /// stops a later edit from "simplifying" the bridge to `hardMask(for:)`.
    @Test("Every mask is the feathered coverage, for every kind, never the hard mask")
    func everyMaskIsFeathered() throws {
        let analysis = Self.singleFace
        let inputs = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, kinds: Set(RenderMaskKind.allCases))
        let input = try #require(inputs.first)
        let parsing = try #require(analysis.faces.first?.parsing)

        for (group, kind) in FaceAnalysisRenderBridge.groups {
            let mask = try #require(input.masks[kind], "no mask for \(kind)")
            let feathered = parsing.feathered(group)
            let hard = parsing.hardMask(for: group)
            #expect(mask.values == feathered, "\(kind) is not the feathered mask")
            // …and the two are genuinely different for this fixture, or the
            // assertion above would hold for a hard mask too.
            #expect(feathered != hard, "\(kind) fixture has no boundary to feather")
            #expect(mask.values != hard, "\(kind) is the hard mask")
            // A feather is a ramp: it must contain values that are neither 0
            // nor 255, which a hard mask never does.
            #expect(
                mask.values.contains { $0 > 0 && $0 < 255 },
                "\(kind) has no partial coverage — that is a hard mask")
        }
    }

    /// The "Mắt / Răng" node asks for `.eyes` and `.mouth`, and spike S2 §4 makes
    /// a feathered mask **mandatory** for both (`FaceParsingGroup.requiresFeatheredMask`
    /// is true for `.eyes`, `.brows`, `.lips`, `.mouth`). `everyMaskIsFeathered`
    /// above covers every kind, but it would still pass if the node quietly
    /// started asking for a kind the bridge cannot feather — so this test asks
    /// for exactly what `EyesTeethRenderNode.maskKinds` says it binds, and
    /// checks those.
    ///
    /// It also pins the negative: **no teeth mask.** CelebAMask-HQ has no teeth
    /// class, so "Trắng răng" derives teeth from luminance inside the mouth
    /// interior (spike S2 §3c). A `teeth` case appearing in `RenderMaskKind` or
    /// a `teeth` group appearing in `FaceParsingGroup` would mean somebody
    /// invented a mask nothing can produce.
    @Test("The eyes/teeth node's mask kinds exist, are feathered, and include no teeth class")
    func eyesTeethNodeMaskKindsAreFeathered() throws {
        let analysis = Self.singleFace
        let kinds = EyesTeethRenderNode.maskKinds
        #expect(kinds == [.eyes, .mouth])

        let input = try #require(
            FaceAnalysisRenderBridge.renderInputs(from: analysis, kinds: kinds).first)
        #expect(Set(input.masks.keys) == kinds)

        let parsing = try #require(analysis.faces.first?.parsing)
        for (group, kind) in FaceAnalysisRenderBridge.groups where kinds.contains(kind) {
            // Mandatory per spike S2 §4 — the model itself says so.
            #expect(group.requiresFeatheredMask, "\(group) is not marked as needing a feather")
            let mask = try #require(input.masks[kind])
            #expect(mask.values == parsing.feathered(group), "\(kind) is not the feathered mask")
            #expect(mask.values != parsing.hardMask(for: group), "\(kind) is the hard mask")
            #expect(
                mask.values.contains { $0 > 0 && $0 < 255 },
                "\(kind) has no partial coverage — that is a hard mask")
        }

        // The mouth mask is the mouth *interior* and nothing else: it must be
        // exactly what `ParsedFace.mouthInterior()` feathers to, not the lips.
        let mouth = try #require(input.masks[.mouth])
        #expect(mouth.values == parsing.feathered(.mouth))
        #expect(parsing.hardMask(for: .mouth) == parsing.mouthInterior())
        #expect(mouth.values != parsing.feathered(.lips))

        // No teeth class anywhere.
        #expect(!RenderMaskKind.allCases.contains { $0.rawValue == "teeth" })
        #expect(!FaceParsingGroup.allCases.contains { $0.rawValue == "teeth" })
    }

    @Test("Mask kinds are exactly the ones asked for; the default is skin only")
    func maskKindSelection() throws {
        let analysis = Self.singleFace

        let byDefault = try #require(FaceAnalysisRenderBridge.renderInputs(from: analysis).first)
        #expect(Set(byDefault.masks.keys) == [.skin])

        let two = try #require(
            FaceAnalysisRenderBridge.renderInputs(from: analysis, kinds: [.eyes, .lips]).first)
        #expect(Set(two.masks.keys) == [.eyes, .lips])

        let none = try #require(
            FaceAnalysisRenderBridge.renderInputs(from: analysis, kinds: []).first)
        #expect(none.masks.isEmpty)
        // Landmarks and face width do not depend on the mask request.
        #expect(none.landmarks.count == FaceLandmarks478.pointCount)
        #expect(none.faceWidth == 200)

        let all = try #require(
            FaceAnalysisRenderBridge.renderInputs(
                from: analysis, kinds: Set(RenderMaskKind.allCases)
            ).first)
        #expect(Set(all.masks.keys) == Set(RenderMaskKind.allCases))
        // The bridge's table must stay total: every RenderMaskKind has a
        // FaceParsingGroup behind it, so no kind can be silently unfillable.
        #expect(FaceAnalysisRenderBridge.groups.count == RenderMaskKind.allCases.count)
        #expect(Set(FaceAnalysisRenderBridge.groups.map(\.1)) == Set(RenderMaskKind.allCases))
    }

    @Test("A face with no parsing yields landmarks and no masks, not a dropped face")
    func faceWithoutParsing() throws {
        let analysis = Self.analysis([
            Self.face(
                center: CGPoint(x: 1000, y: 900), cheekSpan: 150,
                maskCenter: CGPoint(x: 1000, y: 900), maskSide: 300, includeParsing: false)
        ])
        let inputs = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, kinds: Set(RenderMaskKind.allCases))
        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        #expect(input.masks.isEmpty)
        #expect(input.faceWidth == 150)
        #expect(input.landmarks.count == FaceLandmarks478.pointCount)
    }

    // MARK: - Scaling

    /// The bridge's version of `RenderGraphTests.scalingAFaceMovesOnlyTheTransform`,
    /// but through the real conversion: a preview renders at 2048 px while
    /// `FaceAnalyzer` ran on the full 6000 px frame, so this path runs on every
    /// preview frame and getting it wrong puts the mask half a face out of place.
    @Test("Scaling scales geometry, moves only the transform, and never resamples the mask")
    func scalingMovesOnlyTheTransform() throws {
        let analysis = Self.singleFace
        let scale: CGFloat = 0.5
        let full = try #require(FaceAnalysisRenderBridge.renderInputs(from: analysis).first)
        let half = try #require(
            FaceAnalysisRenderBridge.renderInputs(from: analysis, renderScale: scale).first)

        #expect(half.faceWidth == full.faceWidth * scale)
        #expect(half.landmarks.count == full.landmarks.count)
        for (a, b) in zip(full.landmarks, half.landmarks) {
            #expect(abs(b.x - a.x * scale) < 1e-9)
            #expect(abs(b.y - a.y * scale) < 1e-9)
        }

        let fullMask = try #require(full.masks[.skin])
        let halfMask = try #require(half.masks[.skin])
        // The 512² (here 64²) parsing mask is not resampled — resampling would
        // throw away the sub-pixel geometry the feather exists to preserve.
        #expect(halfMask.values == fullMask.values)
        #expect(halfMask.width == fullMask.width)
        #expect(halfMask.height == fullMask.height)

        // A mask pixel must land on half the image coordinate it used to.
        let probe = CGPoint(x: 17, y: 41)
        let before = probe.applying(fullMask.maskToImage)
        let after = probe.applying(halfMask.maskToImage)
        #expect(abs(after.x - before.x * scale) < 1e-9)
        #expect(abs(after.y - before.y * scale) < 1e-9)
        // …and the inverse the shader actually uses must round-trip.
        let back = after.applying(halfMask.imageToMask)
        #expect(abs(back.x - probe.x) < 1e-6)
        #expect(abs(back.y - probe.y) < 1e-6)
    }

    @Test("A rotated parsing crop scales without losing its rotation")
    func rotatedRegionScales() throws {
        // Roll normalisation means real parsing crops are rotated (ADR-0008); a
        // scale implemented as "rewrite tx/ty" instead of "concatenate a scale"
        // passes the axis-aligned case above and fails this one.
        let rotation: CGFloat = 0.4
        let analysis = Self.analysis([
            Self.face(
                center: CGPoint(x: 2400, y: 1500), cheekSpan: 200,
                maskCenter: CGPoint(x: 2400, y: 1500), maskSide: 400, maskRotation: rotation)
        ])
        let scale: CGFloat = 2048.0 / 6000.0
        let full = try #require(FaceAnalysisRenderBridge.renderInputs(from: analysis).first)
        let half = try #require(
            FaceAnalysisRenderBridge.renderInputs(from: analysis, renderScale: scale).first)
        let fullMask = try #require(full.masks[.skin])
        let halfMask = try #require(half.masks[.skin])

        for probe in [CGPoint(x: 0, y: 0), CGPoint(x: 63, y: 0), CGPoint(x: 31, y: 47)] {
            let before = probe.applying(fullMask.maskToImage)
            let after = probe.applying(halfMask.maskToImage)
            #expect(abs(after.x - before.x * scale) < 1e-9, "x at \(probe)")
            #expect(abs(after.y - before.y * scale) < 1e-9, "y at \(probe)")
        }
        // The rotation survived: the transform is not axis-aligned.
        #expect(abs(halfMask.maskToImage.b) > 1e-6)
    }

    @Test("renderScale = 1 takes the fast path and returns the identical value")
    func scaleOfOneIsTheIdentity() throws {
        let analysis = Self.singleFace
        let plain = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, kinds: Set(RenderMaskKind.allCases))
        let explicit = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, renderScale: 1, kinds: Set(RenderMaskKind.allCases))
        #expect(plain == explicit)
    }

    // MARK: - Multi-face

    @Test("Two faces convert independently, in order, each with its own geometry")
    func twoFacesKeepTheirOwnGeometry() throws {
        let a = Self.face(
            center: CGPoint(x: 1500, y: 1200), cheekSpan: 200,
            maskCenter: CGPoint(x: 1500, y: 1200), maskSide: 400)
        let b = Self.face(
            center: CGPoint(x: 4200, y: 2600), cheekSpan: 120,
            maskCenter: CGPoint(x: 4200, y: 2600), maskSide: 240)
        let analysis = Self.analysis([a, b])

        let inputs = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, kinds: [.skin, .eyes])
        #expect(inputs.count == 2)
        // Order is the analysis order (highest confidence first), not sorted or
        // deduplicated — the canvas's face picker indexes into this.
        #expect(inputs[0].faceWidth == 200)
        #expect(inputs[1].faceWidth == 120)
        #expect(inputs[0].faceWidth == a.faceWidth)
        #expect(inputs[1].faceWidth == b.faceWidth)

        // The two masks are byte-identical (same fixture) but must not share a
        // transform, or both faces would be retouched in one place.
        let maskA = try #require(inputs[0].masks[.skin])
        let maskB = try #require(inputs[1].masks[.skin])
        #expect(maskA.values == maskB.values)
        #expect(maskA.maskToImage != maskB.maskToImage)

        // Each mask centre lands on its own face centre. `outputToImage` maps the
        // crop's centre pixel (32, 32) to the region centre.
        let centre = CGPoint(x: 32, y: 32)
        let imageA = centre.applying(maskA.maskToImage)
        let imageB = centre.applying(maskB.maskToImage)
        #expect(abs(imageA.x - 1500) < 1e-6 && abs(imageA.y - 1200) < 1e-6)
        #expect(abs(imageB.x - 4200) < 1e-6 && abs(imageB.y - 2600) < 1e-6)

        // And a preview scale applies to both, not just the first.
        let scale = FaceAnalysisRenderBridge.renderScale(for: analysis, renderedLongEdge: 2048)
        let scaled = FaceAnalysisRenderBridge.renderInputs(
            from: analysis, renderScale: scale, kinds: [.skin, .eyes])
        #expect(scaled.count == 2)
        #expect(abs(scaled[0].faceWidth - 200 * scale) < 1e-9)
        #expect(abs(scaled[1].faceWidth - 120 * scale) < 1e-9)
        let scaledA = try #require(scaled[0].masks[.skin])
        let scaledB = try #require(scaled[1].masks[.skin])
        #expect(abs(centre.applying(scaledA.maskToImage).x - 1500 * scale) < 1e-6)
        #expect(abs(centre.applying(scaledB.maskToImage).x - 4200 * scale) < 1e-6)
        // Both kinds survive the scale for both faces.
        #expect(Set(scaled[0].masks.keys) == [.skin, .eyes])
        #expect(Set(scaled[1].masks.keys) == [.skin, .eyes])
    }

    @Test("An analysis with no faces converts to no inputs, not to one empty face")
    func emptyAnalysis() {
        let empty = FaceAnalysis(
            imageSize: CGSize(width: 6000, height: 4000), faces: [],
            options: FaceAnalyzerOptions())
        #expect(FaceAnalysisRenderBridge.renderInputs(from: empty).isEmpty)
        #expect(FaceAnalysisRenderBridge.renderInputs(from: empty, renderScale: 0.3).isEmpty)
    }
}
