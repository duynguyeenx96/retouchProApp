import CoreGraphics
import CoreML
import Foundation
import Vision

/// The production face pipeline: one image in, a cached `FaceAnalysis` out.
///
/// ```
/// stage 1  Vision DetectFaceRectanglesRequest      rough box, whole image
/// stage 2  face-centred square crop (3.5 x box)  → BlazeFace 128px → precise ROI
/// stage 3  MediaPipe ROI (square_long, x1.5)     → 478-point mesh 256px
/// stage 4  CelebA-framed roll-normalised crop    → 19-class parsing 512px
/// ```
///
/// **Stage 2 is not optional.** Spike S1 §4a measured the obvious shortcut —
/// Vision's box straight into the mesh model — at **1.399 px** mean error on the
/// user's real a6300 frames against a **< 1 px** bar, and showed it is not a scale
/// error that calibration can remove (the ROI scale sweep bottoms out at 1.293 px;
/// the residual is Vision's box centre being 5.5 % of the ROI off and its roll
/// 2.4° out). The model itself scores 0.193 px on MediaPipe's own ROI, so the ROI
/// is the entire gap. See `docs/ADR-0005` and `Research/spikes/S1-landmark/`.
///
/// An `actor`: it owns three Core ML models and a `CIContext`, the Core ML calls
/// are synchronous, and serialising them is what we want anyway — two frames
/// racing for the Neural Engine is slower than one after the other. Actor
/// isolation is also what makes the cache safe without a lock.
///
/// Gated by `RPVisionFeatureFlags.faceAnalyzer` **and** by the flag of each model
/// it loads, because none of them has a real-device number yet
/// (`Research/spikes/S1-landmark/S1-landmark.md` §5, `S2-face-parsing.md` §6).
public actor FaceAnalyzer {
    /// Where the three `.mlpackage`s live. None of them is bundled with RPVision
    /// yet — same decision as spikes S1 and S2, so the packages stay small and the
    /// bundling question is answered once, later, for all three at the same time.
    public struct Models: Sendable, Equatable {
        public var blazeFace: URL
        public var landmark: URL
        /// `nil` disables parsing regardless of `options.parsing`.
        public var parsing: URL?

        public init(blazeFace: URL, landmark: URL, parsing: URL? = nil) {
            self.blazeFace = blazeFace
            self.landmark = landmark
            self.parsing = parsing
        }
    }

    public let options: FaceAnalyzerOptions

    private let blazeFace: BlazeFaceModel
    private let landmark: FaceLandmark478Model
    private let parsing: FaceParsingModel?
    private let renderer: CropRegionRenderer
    private var cache: FaceAnalysisCache
    private var inFlight: [FaceAnalysisKey: Task<FaceAnalysis, Error>] = [:]

    public init(
        models: Models,
        options: FaceAnalyzerOptions = FaceAnalyzerOptions(),
        computeUnits: MLComputeUnits = .all,
        cacheCapacity: Int = 24
    ) throws {
        guard RPVisionFeatureFlags.faceAnalyzer else {
            throw RPVisionFeatureDisabled(feature: "faceAnalyzer")
        }
        self.options = options
        self.blazeFace = try BlazeFaceModel(url: models.blazeFace, computeUnits: computeUnits)
        self.landmark = try FaceLandmark478Model(
            url: models.landmark, computeUnits: computeUnits)
        if let parsingURL = models.parsing, options.parsing != nil {
            self.parsing = try FaceParsingModel(url: parsingURL, computeUnits: computeUnits)
        } else {
            self.parsing = nil
        }
        self.renderer = CropRegionRenderer()
        self.cache = FaceAnalysisCache(capacity: cacheCapacity)
    }

    // MARK: - Cached entry point

    /// Analyses `image`, reusing a cached result when `contentHash` has been seen
    /// with these options before.
    ///
    /// Concurrent callers asking for the same key share one run: the second caller
    /// awaits the first one's `Task` instead of starting a second inference. That
    /// is the case a slider drag actually produces — several redraws land while the
    /// first analysis is still on the Neural Engine.
    ///
    /// - Parameter visionBoxes: supply stage 1's boxes to skip the Vision call —
    ///   see `analyze(_:visionBoxes:visionDetectMs:)`.
    public func analysis(
        of image: CGImage, contentHash: String, visionBoxes: [CGRect]? = nil
    ) async throws -> FaceAnalysis {
        let key = FaceAnalysisKey(contentHash: contentHash, options: options)
        if let hit = cache.value(for: key) { return hit }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { () throws -> FaceAnalysis in
            if let visionBoxes {
                return try self.analyze(image, visionBoxes: visionBoxes)
            }
            return try await self.analyzeUncached(image)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        cache.store(result, for: key)
        return result
    }

    public func cachedAnalysis(for key: FaceAnalysisKey) -> FaceAnalysis? { cache.peek(key) }

    public func cacheStatistics() -> (hits: Int, misses: Int, evictions: Int, count: Int) {
        (cache.hits, cache.misses, cache.evictions, cache.count)
    }

    public func clearCache() { cache.removeAll() }

    // MARK: - The pipeline

    /// Runs every stage. Public so the measurement harness can time a cold run
    /// without fighting the cache.
    public func analyzeUncached(_ image: CGImage) async throws -> FaceAnalysis {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let boxes = try await Self.visionBoxes(in: image, limit: options.detection.maxFaces)
        let visionMs = Self.ms(since: t0)
        return try analyze(image, visionBoxes: boxes, visionDetectMs: visionMs)
    }

    /// Stages 2-4 with stage 1's boxes supplied by the caller.
    ///
    /// Two callers want this. A render graph that already knows where the faces are
    /// (the user picked one on the canvas) should not pay for Vision again; and the
    /// tests need it because **Apple's `DetectFaceRectanglesRequest` cannot create
    /// an inference context on the iOS 26 Simulator** — it fails with
    /// `com.apple.Vision Code=9 "Could not create inference context"` — so without
    /// this entry point stages 2-4 would have no iOS coverage at all.
    public func analyze(
        _ image: CGImage, visionBoxes: [CGRect], visionDetectMs: Double = 0
    ) throws -> FaceAnalysis {
        let start = DispatchTime.now().uptimeNanoseconds
        var timings = FaceAnalysis.Timings()
        timings.visionDetectMs = visionDetectMs
        let imageSize = CGSize(width: image.width, height: image.height)
        let boxes = Array(visionBoxes.prefix(options.detection.maxFaces))

        var faces: [AnalyzedFace] = []
        for box in boxes {
            let t1 = DispatchTime.now().uptimeNanoseconds
            guard let refined = try refineWithBlazeFace(image: image, visionBox: box) else {
                continue
            }
            timings.blazeFaceMs += Self.ms(since: t1)

            let t2 = DispatchTime.now().uptimeNanoseconds
            let roi = landmarkROI(for: refined.detection)
            let mesh = try meshLandmarks(image: image, roi: roi)
            timings.landmarkMs += Self.ms(since: t2)

            var parsed: ParsedFace?
            if let parsing, let parsingOptions = options.parsing {
                let t3 = DispatchTime.now().uptimeNanoseconds
                let region = parsingRegion(
                    for: refined.detection, roll: roi.rotation, options: parsingOptions)
                let buffer = try renderer.render(image, region: region)
                parsed = ParsedFace(
                    mask: try parsing.predict(image: buffer), region: region)
                timings.parsingMs += Self.ms(since: t3)
            }

            faces.append(
                AnalyzedFace(
                    visionBox: box, detectorRegion: refined.region,
                    detection: refined.detection, landmarks: mesh, parsing: parsed))
        }

        faces.sort { $0.detection.score > $1.detection.score }
        timings.totalMs = visionDetectMs + Self.ms(since: start)
        return FaceAnalysis(
            imageSize: imageSize, faces: faces, options: options, timings: timings)
    }

    // MARK: - Stage 1

    /// Rough boxes in image pixels, y down, biggest first.
    ///
    /// `DetectFaceRectanglesRequest`, not `DetectFaceLandmarksRequest` as spike S1
    /// used: the landmark request exists there only to get eye centroids for the
    /// ROI roll, and BlazeFace now supplies those. All this stage has to do is say
    /// roughly where to look.
    static func visionBoxes(in image: CGImage, limit: Int) async throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectFaceRectanglesRequest()
        let observations = try await request.perform(on: image)
        return
            observations
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
            .sorted { max($0.width, $0.height) > max($1.width, $1.height) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Stage 2

    struct RefinedFace {
        var region: CropRegion
        /// In image pixels, y down.
        var detection: BlazeFaceDetection
    }

    func refineWithBlazeFace(image: CGImage, visionBox: CGRect) throws -> RefinedFace? {
        let side = max(visionBox.width, visionBox.height) * options.detectorRegionScale
        let region = CropRegion(
            center: CGPoint(x: visionBox.midX, y: visionBox.midY),
            side: side, rotation: 0, outputSide: BlazeFaceModel.inputSide)
        let buffer = try renderer.render(image, region: region)
        let output = try blazeFace.predict(image: buffer)
        let detections = BlazeFaceDecoder.decode(
            regressors: output.regressors, scoreLogits: output.scoreLogits,
            options: options.detection)
        guard let chosen = Self.pick(detections, regionScale: options.detectorRegionScale)
        else { return nil }
        return RefinedFace(region: region, detection: chosen.mapped(through: region))
    }

    /// The crop is centred on *one* face, but a second face can intrude at the
    /// edge — the user's `DSC05403` is exactly that frame. So prefer detections
    /// whose centre is within half a face width of the crop centre, and only fall
    /// back to "highest score anywhere" when none is.
    static func pick(_ detections: [BlazeFaceDetection], regionScale: CGFloat)
        -> BlazeFaceDetection?
    {
        let tolerance = 0.5 / regionScale
        let centred = detections.filter {
            hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5) <= tolerance
        }
        return (centred.isEmpty ? detections : centred).max { $0.score < $1.score }
    }

    // MARK: - Stage 3

    func landmarkROI(for detection: BlazeFaceDetection) -> FaceCrop {
        var crop = FaceCrop.mediaPipeStyle(
            boundingBox: detection.boundingBox,
            rightEye: detection.keypoint(.rightEye),
            leftEye: detection.keypoint(.leftEye),
            scale: options.landmarkROIScale)
        if options.roundsLandmarkROISide {
            // RectTransformationCalculator rounds the transformed side to a whole
            // pixel. On a 200 px ROI that is up to 0.25 % of scale, which moves a
            // point at the edge of the 256 crop by ~0.3 px — the same order as the
            // whole error budget, so it is matched rather than ignored.
            crop.side = crop.side.rounded()
        }
        return crop
    }

    func meshLandmarks(image: CGImage, roi: FaceCrop) throws -> FaceLandmarks478 {
        let buffer = try renderer.render(image, region: CropRegion(roi))
        let output = try landmark.predict(crop: buffer)
        return FaceLandmarks478(
            cropPoints: output.cropPoints, depths: output.depths, score: output.score,
            crop: roi)
    }

    // MARK: - Stage 4

    func parsingRegion(
        for detection: BlazeFaceDetection, roll: CGFloat,
        options parsingOptions: FaceAnalyzerOptions.ParsingOptions
    ) -> CropRegion {
        let long = max(detection.boundingBox.width, detection.boundingBox.height)
        let side = (long * parsingOptions.cropScale).rounded()
        let rotation = parsingOptions.rollNormalised ? roll : 0
        // The face centre sits at `faceCenterYFraction` of the crop height, so the
        // crop centre is that much *above* it, measured along the crop's own y axis
        // (which is rotated when the roll is normalised).
        let offset = (0.5 - parsingOptions.faceCenterYFraction) * side
        let c = cos(rotation), s = sin(rotation)
        let center = CGPoint(
            x: detection.boundingBox.midX - offset * s,
            y: detection.boundingBox.midY + offset * c)
        return CropRegion(
            center: center, side: side, rotation: rotation,
            outputSide: FaceParsingModel.inputSide)
    }

    private static func ms(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
}
