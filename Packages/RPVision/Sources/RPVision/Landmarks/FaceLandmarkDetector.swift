import CoreGraphics
import CoreML
import Foundation
import Vision

/// Spike S1 pipeline: Vision face detection → rotated 256x256 crop → Core ML
/// 478-point mesh. This is deliberately the whole surface RPVision exposes for
/// landmarks right now; `FaceAnalyzer`/`FaceAnalysis` are Phase 2.
///
/// Gated by `RPVisionFeatureFlags.faceLandmarks478`.
public final class FaceLandmarkDetector {
    private let model: FaceLandmark478Model
    private let renderer: FaceCropRenderer

    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        self.model = try FaceLandmark478Model(url: modelURL, computeUnits: computeUnits)
        self.renderer = FaceCropRenderer()
    }

    /// Vision face boxes plus eye centres, in image pixels with y down.
    public struct DetectedFace: Sendable {
        public var boundingBox: CGRect
        public var rightEye: CGPoint?
        public var leftEye: CGPoint?
    }

    /// Runs `DetectFaceLandmarksRequest` and converts everything to y-down pixels.
    public func detectFaces(in image: CGImage) async throws -> [DetectedFace] {
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectFaceLandmarksRequest()
        let observations = try await request.perform(on: image)
        return observations.map { observation in
            let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            var right: CGPoint?
            var left: CGPoint?
            if let landmarks = observation.landmarks {
                // Vision's "left/right eye" is named from the viewer's side of the
                // image, MediaPipe's keypoint 0/1 are the subject's right/left eye.
                // In an upright frontal image Vision's `leftEye` sits at the smaller
                // x, which is the subject's right eye — hence the swap.
                right = Self.centroid(of: landmarks.leftEye, imageSize: size)
                left = Self.centroid(of: landmarks.rightEye, imageSize: size)
            }
            return DetectedFace(boundingBox: box, rightEye: right, leftEye: left)
        }
    }

    private static func centroid(
        of region: FaceObservation.Landmarks2D.Region?,
        imageSize: CGSize
    ) -> CGPoint? {
        guard let region else { return nil }
        let points = region.pointsInImageCoordinates(imageSize, origin: .upperLeft)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Landmarks for one already-chosen crop.
    public func landmarks(in image: CGImage, crop: FaceCrop) throws -> FaceLandmarks478 {
        let buffer = try renderer.render(image, crop: crop)
        let output = try model.predict(crop: buffer)
        return FaceLandmarks478(
            cropPoints: output.cropPoints, depths: output.depths,
            score: output.score, crop: crop)
    }

    /// Full path: detect every face, then mesh each one.
    public func landmarks(in image: CGImage) async throws -> [FaceLandmarks478] {
        let faces = try await detectFaces(in: image)
        return try faces.map { face in
            let crop = FaceCrop.mediaPipeStyle(
                boundingBox: face.boundingBox, rightEye: face.rightEye, leftEye: face.leftEye,
                scale: FaceCrop.visionBoxScale)
            return try landmarks(in: image, crop: crop)
        }
    }
}
