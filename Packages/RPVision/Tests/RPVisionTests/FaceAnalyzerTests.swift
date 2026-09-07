import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import RPVision

/// End-to-end tests for the Phase 2 analyzer.
///
/// The accuracy numbers do **not** live here — they are a 31-image measurement
/// against the MediaPipe Python reference and live in
/// `Research/phase2/face-analyzer/results/summary.json`, produced by
/// `Research/phase2/face-analyzer/SwiftHarness` + `compare_twostage.py`. What these
/// tests do is pin the wiring: the two stages run in the right order, the ROI comes
/// from BlazeFace rather than Vision, the parsing crop is roll-normalised and
/// CelebA-framed, and the cache actually stops the models from running twice.
@Suite("FaceAnalyzer pipeline", .serialized)
struct FaceAnalyzerTests {
    static var models: FaceAnalyzer.Models? {
        guard let blazeFace = Phase2Resources.blazeFaceModel,
            let landmark = SpikeResources.model
        else { return nil }
        return FaceAnalyzer.Models(
            blazeFace: blazeFace, landmark: landmark, parsing: SpikeS2Resources.model)
    }

    /// A face big enough for Vision to find. `SpikeS2/face_512.png` is the
    /// CC BY-SA Wikimedia headshot both earlier spikes used.
    static func testImage() -> CGImage? {
        guard let url = SpikeS2Resources.face else { return nil }
        return SpikeS2Resources.image(at: url)
    }

    /// Stand-in for stage 1 on the iOS Simulator, where Apple's Vision cannot
    /// create an inference context (`com.apple.Vision Code=9`).
    ///
    /// Not invented: `SpikeS2/face_512.png` was cut by `prepare_a6300.swift` with
    /// the CelebA framing spike S2 measured — a square of 1.87 x face width with
    /// the face centre at 54.4 % of the height. Inverting that gives a face box of
    /// 512/1.87 = 274 px centred at (256, 0.544 x 512 = 279).
    /// `visionAgreesWithTheStandInBox` checks it against the real thing wherever
    /// Vision does work.
    static let standInFaceBox = CGRect(x: 119, y: 142, width: 274, height: 274)

    /// The analyzer loads three models, so it needs three model flags plus its own.
    ///
    /// The teardown deliberately **only clears the two flags this suite owns**
    /// (`faceAnalyzer`, `blazeFaceShortRange`) and leaves `faceLandmarks478` /
    /// `faceParsing19` on. `RPVisionFeatureFlags` storage is process-global and
    /// Swift Testing runs suites concurrently: clearing S1's or S2's flag here
    /// switches their benchmarks off mid-run, which is exactly the failure
    /// `RPVisionFeatureFlags.resetToDefaults()`'s doc comment describes. Leaving
    /// them **on** is safe in the other direction, because every "flag off" test
    /// sets its own flag to false immediately before asserting.
    private func enableFlags() {
        RPVisionFeatureFlags.faceLandmarks478 = true
        RPVisionFeatureFlags.faceParsing19 = true
        RPVisionFeatureFlags.blazeFaceShortRange = true
        RPVisionFeatureFlags.faceAnalyzer = true
    }

    private func disableFlags() {
        RPVisionFeatureFlags.faceAnalyzer = false
    }

    @Test("The analyzer flag gates construction on its own")
    func flagGatesConstruction() throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        RPVisionFeatureFlags.faceAnalyzer = false
        #expect(throws: RPVisionFeatureDisabled.self) { _ = try FaceAnalyzer(models: models) }
    }

    /// Each model keeps its own flag: turning the analyzer on must not silently
    /// load a Core ML model the caller has not opted in to.
    @Test("A model flag left off still throws, with the analyzer flag on")
    func modelFlagsAreIndependent() throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        defer { disableFlags() }
        RPVisionFeatureFlags.faceAnalyzer = true
        RPVisionFeatureFlags.blazeFaceShortRange = false
        #expect(throws: RPVisionFeatureDisabled.self) { _ = try FaceAnalyzer(models: models) }
        RPVisionFeatureFlags.blazeFaceShortRange = true
    }

    @Test("Finds one face and produces a mesh, a parse and a face width")
    func analysesAPortrait() async throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        let image = try #require(Self.testImage(), "spike S2 fixture missing")
        enableFlags()
        defer { disableFlags() }

        let analyzer = try FaceAnalyzer(models: models)
        let analysis = try await analyzer.analyze(image, visionBoxes: [Self.standInFaceBox])
        #expect(analysis.faces.count == 1)
        let face = try #require(analysis.faces.first)

        #expect(face.detection.score > 0.7)
        #expect(face.landmarks.score > 0.9)
        #expect(face.landmarks.cropPoints.count == FaceLandmarks478.pointCount)
        #expect(face.imagePoints.count == FaceLandmarks478.pointCount)

        // Face width is the 234-454 cheek distance and this is a 512px face crop
        // where the face fills most of the frame.
        #expect(face.faceWidth > 100 && face.faceWidth < CGFloat(image.width))

        // Every landmark should land inside the image, generously bounded: a
        // transform error would put them off by hundreds of pixels.
        let margin: CGFloat = 0.5 * face.faceWidth
        for point in face.imagePoints {
            #expect(point.x > -margin && point.x < CGFloat(image.width) + margin)
            #expect(point.y > -margin && point.y < CGFloat(image.height) + margin)
        }

        // Stage 2 must have changed the ROI. If BlazeFace were being skipped the
        // refined box would be Vision's box exactly.
        let visionLong = max(face.visionBox.width, face.visionBox.height)
        let blazeLong = max(face.detection.boundingBox.width, face.detection.boundingBox.height)
        #expect(abs(blazeLong - visionLong) > 1)
        #expect(face.detectorRegion.outputSide == BlazeFaceModel.inputSide)
        #expect(
            abs(face.detectorRegion.side - visionLong * analysis.options.detectorRegionScale)
                < 1e-6)

        if SpikeS2Resources.model != nil {
            let parsed = try #require(face.parsing, "parsing model present but no mask")
            #expect(parsed.mask.width == FaceParsingModel.inputSide)
            #expect(parsed.region.outputSide == FaceParsingModel.inputSide)
            #expect(parsed.partsPresent(), "coverage: \(parsed.coverage())")
            // The parsing crop is CelebA-framed off BlazeFace's box, not the mesh ROI.
            #expect(
                abs(parsed.region.side - (blazeLong * 1.87).rounded()) < 1.5,
                "parsing crop side \(parsed.region.side) for a \(blazeLong) px face")
            // ... and roll-normalised, i.e. it carries the mesh ROI's rotation.
            #expect(abs(parsed.region.rotation - face.roll) < 1e-9)
        }

        #expect(analysis.timings.totalMs > 0)
        #expect(analysis.timings.landmarkMs > 0)
    }

    @Test("Turning parsing off skips stage 4 entirely")
    func parsingCanBeDisabled() async throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        let image = try #require(Self.testImage())
        enableFlags()
        defer { disableFlags() }

        var options = FaceAnalyzerOptions()
        options.parsing = nil
        let analyzer = try FaceAnalyzer(models: models, options: options)
        let analysis = try await analyzer.analyze(image, visionBoxes: [Self.standInFaceBox])
        #expect(analysis.faces.first?.parsing == nil)
        #expect(analysis.timings.parsingMs == 0)
    }

    /// Stage 1 is Apple's and is not covered by the tests above, which inject the
    /// box. This is the test that actually runs it — and it is **expected to fail
    /// on the iOS Simulator**, where `DetectFaceRectanglesRequest` cannot create an
    /// inference context (`com.apple.Vision Code=9 "Could not create inference
    /// context"`, reproducible with `-parallel-testing-enabled NO`). Recorded as a
    /// known issue rather than skipped, so the day the Simulator gains the ability
    /// this turns into an "unexpectedly passed" and someone deletes the branch.
    ///
    /// It also checks `standInFaceBox`: where Vision does run, its box and the
    /// stand-in must produce the same mesh, otherwise every Simulator run above is
    /// measuring a face nobody would ever hand the analyzer.
    @Test("Stage 1 runs on Apple Vision and agrees with the stand-in box")
    func visionAgreesWithTheStandInBox() async throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        let image = try #require(Self.testImage())
        enableFlags()
        defer { disableFlags() }
        let analyzer = try FaceAnalyzer(models: models)

        func check() async throws {
            let boxes = try await FaceAnalyzer.visionBoxes(in: image, limit: 8)
            #expect(boxes.count == 1)
            let box = try #require(boxes.first)
            // Same face, roughly the same size: the two boxes only have to agree
            // well enough that a 3.5x crop around either contains the face.
            #expect(abs(box.midX - Self.standInFaceBox.midX) < 0.25 * box.width)
            #expect(abs(box.midY - Self.standInFaceBox.midY) < 0.25 * box.height)
            #expect(box.width > 0.6 * Self.standInFaceBox.width)
            #expect(box.width < 1.6 * Self.standInFaceBox.width)

            let fromVision = try await analyzer.analyzeUncached(image)
            let fromStandIn = try await analyzer.analyze(
                image, visionBoxes: [Self.standInFaceBox])
            let a = try #require(fromVision.faces.first).imagePoints
            let b = try #require(fromStandIn.faces.first).imagePoints
            let worst = zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            #expect(worst < 4, "worst landmark disagreement \(worst) px")
        }

        #if targetEnvironment(simulator)
            await withKnownIssue("Vision has no inference context on the iOS Simulator") {
                try await check()
            }
        #else
            try await check()
        #endif
    }

    /// The plan's actual requirement (§1.4: "landmark/parsing chạy 1 lần/ảnh, cache
    /// theo hash"). Asserted through the cache counters *and* the clock: a warm
    /// call cannot have run three Core ML models.
    @Test("A second request with the same hash does not re-run the models")
    func cachesByHash() async throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        let image = try #require(Self.testImage())
        enableFlags()
        defer { disableFlags() }

        let analyzer = try FaceAnalyzer(models: models)
        let cold = try await analyzer.analysis(
            of: image, contentHash: "sha256:test-a", visionBoxes: [Self.standInFaceBox])
        let coldStats = await analyzer.cacheStatistics()
        #expect(coldStats.misses == 1 && coldStats.hits == 0)

        let start = DispatchTime.now().uptimeNanoseconds
        let warm = try await analyzer.analysis(
            of: image, contentHash: "sha256:test-a", visionBoxes: [Self.standInFaceBox])
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        let warmStats = await analyzer.cacheStatistics()
        #expect(warmStats.hits == 1)
        #expect(warm.faces.count == cold.faces.count)
        #expect(warm.timings.totalMs == cold.timings.totalMs)  // same object, not a re-run
        #expect(warmMs < cold.timings.totalMs / 4, "warm lookup took \(warmMs) ms")

        // A different hash is a different image as far as the cache is concerned.
        _ = try await analyzer.analysis(
            of: image, contentHash: "sha256:test-b", visionBoxes: [Self.standInFaceBox])
        #expect(await analyzer.cacheStatistics().misses == 2)

        await analyzer.clearCache()
        #expect(await analyzer.cacheStatistics().count == 0)
    }

    @Test("Concurrent requests for the same hash share one run")
    func coalescesConcurrentRequests() async throws {
        let models = try #require(Self.models, "Phase 2 / spike models missing")
        let image = try #require(Self.testImage())
        enableFlags()
        defer { disableFlags() }

        let analyzer = try FaceAnalyzer(models: models)
        async let a = analyzer.analysis(
            of: image, contentHash: "sha256:dup", visionBoxes: [Self.standInFaceBox])
        async let b = analyzer.analysis(
            of: image, contentHash: "sha256:dup", visionBoxes: [Self.standInFaceBox])
        async let c = analyzer.analysis(
            of: image, contentHash: "sha256:dup", visionBoxes: [Self.standInFaceBox])
        let results = try await [a, b, c]

        // All three see the same analysis object, and only one of them paid for it.
        #expect(Set(results.map(\.timings.totalMs)).count == 1)
        let stats = await analyzer.cacheStatistics()
        #expect(stats.count == 1)
    }

    @Test("Face selection prefers the detection nearest the crop centre")
    func picksTheCentredFace() {
        func detection(x: CGFloat, score: Float) -> BlazeFaceDetection {
            BlazeFaceDetection(
                boundingBox: CGRect(x: x, y: 0.4, width: 0.2, height: 0.2),
                keypoints: Array(repeating: .zero, count: 6), score: score)
        }
        // An intruding face at the edge with a *higher* score must not win: the
        // stage-2 crop was built around the face at the centre.
        let edge = detection(x: 0.85, score: 0.99)
        let centre = detection(x: 0.4, score: 0.80)
        let picked = FaceAnalyzer.pick([edge, centre], regionScale: 3.5)
        #expect(picked?.boundingBox.minX == 0.4)

        // With nothing near the centre, fall back to the best available.
        #expect(FaceAnalyzer.pick([edge], regionScale: 3.5)?.boundingBox.minX == 0.85)
        #expect(FaceAnalyzer.pick([], regionScale: 3.5) == nil)
    }

    /// The ROI scale must be MediaPipe's 1.5 for a BlazeFace box, not the 1.40
    /// spike S1 fitted for Apple's box. Using 1.40 here would double-count a
    /// correction that no longer applies.
    @Test("Defaults are the measured ones")
    func defaultsArePinned() {
        let options = FaceAnalyzerOptions()
        #expect(options.landmarkROIScale == 1.5)
        #expect(options.detectorRegionScale == 3.5)
        #expect(options.roundsLandmarkROISide)
        #expect(options.parsing?.cropScale == 1.87)
        #expect(options.parsing?.faceCenterYFraction == 0.544)
        #expect(options.parsing?.rollNormalised == true)
        #expect(options.detection.minScore == 0.5)
        #expect(options.detection.iouThreshold == 0.3)
    }
}
