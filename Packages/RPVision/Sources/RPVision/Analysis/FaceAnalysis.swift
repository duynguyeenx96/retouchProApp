import CoreGraphics
import Foundation

/// Everything RPVision knows about one image: the faces it found, their 478-point
/// meshes and their parsing masks. `docs/PLAN.md` §2/§3 Phase 2 item 4.
///
/// Value type on purpose — it is the thing the analysis cache stores and the
/// render graph reads on the main actor, so it must be `Sendable` and hold no
/// GPU/Core ML resources.
public struct FaceAnalysis: Sendable {
    /// Size of the image these coordinates are in, in pixels.
    public var imageSize: CGSize
    /// Highest-confidence face first.
    public var faces: [AnalyzedFace]
    /// The options this result was produced with. Part of the cache key, so a
    /// cached result can never be served to a caller that asked for something else.
    public var options: FaceAnalyzerOptions
    /// Wall-clock cost of each stage, filled by `FaceAnalyzer`. Written to the
    /// bench JSON; never used to make decisions inside the pipeline.
    public var timings: Timings

    public init(
        imageSize: CGSize, faces: [AnalyzedFace], options: FaceAnalyzerOptions,
        timings: Timings = Timings()
    ) {
        self.imageSize = imageSize
        self.faces = faces
        self.options = options
        self.timings = timings
    }

    public var isEmpty: Bool { faces.isEmpty }

    public struct Timings: Sendable, Equatable, Codable {
        public var visionDetectMs: Double = 0
        public var blazeFaceMs: Double = 0
        public var landmarkMs: Double = 0
        public var parsingMs: Double = 0
        public var totalMs: Double = 0
        public init() {}
    }
}

/// One face.
public struct AnalyzedFace: Sendable {
    /// Rough box from Apple Vision, stage 1. Kept for diagnostics: the difference
    /// between this and `detection.boundingBox` is exactly the error spike S1 §4a
    /// measured, so a regression is visible without re-running the harness.
    public var visionBox: CGRect
    /// The face-centred square stage 2 handed to BlazeFace.
    public var detectorRegion: CropRegion
    /// BlazeFace's refined box + 6 keypoints, **in image pixels, y down**.
    public var detection: BlazeFaceDetection
    /// The 478-point mesh and the ROI it came from.
    public var landmarks: FaceLandmarks478
    /// 19-class parsing, `nil` when parsing was switched off in the options.
    public var parsing: ParsedFace?

    public init(
        visionBox: CGRect, detectorRegion: CropRegion, detection: BlazeFaceDetection,
        landmarks: FaceLandmarks478, parsing: ParsedFace?
    ) {
        self.visionBox = visionBox
        self.detectorRegion = detectorRegion
        self.detection = detection
        self.landmarks = landmarks
        self.parsing = parsing
    }

    /// The mesh in image pixels, y down — the shape `RPEngine`'s MLS warp consumes
    /// (`MLSDeformation.ControlPoints.source` is `[CGPoint]` in the same frame; the
    /// spike S3 harness builds its handles straight off this array).
    public var imagePoints: [CGPoint] { landmarks.imagePoints }

    /// Distance between the two cheek landmarks (MediaPipe 234 / 454), in image
    /// pixels.
    ///
    /// This is the denominator `docs/PLAN.md` §2 requires for reshape sliders:
    /// "Reshape lưu delta tương đối theo face width" is what makes a preset
    /// transfer between images. The same two indices are what spike S3's
    /// `FaceReshape` uses, so the numbers are directly comparable.
    public var faceWidth: CGFloat {
        let points = imagePoints
        guard points.count > FaceMeshIndex.cheekLeft else { return 0 }
        let a = points[FaceMeshIndex.cheekRight]
        let b = points[FaceMeshIndex.cheekLeft]
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// Roll of the ROI, radians, clockwise in the y-down frame. Comes from
    /// BlazeFace's two eye keypoints, i.e. it is MediaPipe's own definition.
    public var roll: CGFloat { landmarks.crop.rotation }
}

/// The handful of MediaPipe mesh indices RPVision itself needs. The reshape
/// sliders' full index lists belong to RPEngine (spike S3 `FaceReshape`); these
/// three are here because `faceWidth` is part of the analysis contract.
public enum FaceMeshIndex {
    /// Subject's right cheek extreme.
    public static let cheekRight = 234
    /// Subject's left cheek extreme.
    public static let cheekLeft = 454
    public static let chin = 152
    public static let foreheadTop = 10
}
