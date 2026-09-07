import CoreGraphics
import Foundation

/// One BlazeFace detection, in the **0…1 normalised frame of the 128 px detector
/// input** (which is the crop the detector was run on, not the whole photo).
///
/// Keypoint order is MediaPipe's, from the subject's point of view:
/// `0` right eye, `1` left eye, `2` nose tip, `3` mouth centre,
/// `4` right ear tragion, `5` left ear tragion. Only 0 and 1 are used to build the
/// mesh ROI (`DetectionsToRectsCalculator` rotates on those two), but the rest are
/// kept because they are free and make the geometry checkable.
public struct BlazeFaceDetection: Sendable, Equatable {
    /// Box in normalised crop coordinates, y down.
    public var boundingBox: CGRect
    /// Six keypoints in the same frame.
    public var keypoints: [CGPoint]
    /// Confidence after `sigmoid(clip(logit, ±100))`.
    public var score: Float

    public init(boundingBox: CGRect, keypoints: [CGPoint], score: Float) {
        self.boundingBox = boundingBox
        self.keypoints = keypoints
        self.score = score
    }

    public static let keypointCount = 6

    public enum Keypoint: Int, CaseIterable, Sendable {
        case rightEye = 0
        case leftEye = 1
        case noseTip = 2
        case mouthCenter = 3
        case rightEarTragion = 4
        case leftEarTragion = 5
    }

    public func keypoint(_ which: Keypoint) -> CGPoint { keypoints[which.rawValue] }

    /// The same detection expressed in image pixels (y down), given the region the
    /// detector actually saw.
    public func mapped(through region: CropRegion) -> BlazeFaceDetection {
        let topLeft = region.imagePoint(
            fromNormalized: CGPoint(x: boundingBox.minX, y: boundingBox.minY))
        let topRight = region.imagePoint(
            fromNormalized: CGPoint(x: boundingBox.maxX, y: boundingBox.minY))
        let bottomLeft = region.imagePoint(
            fromNormalized: CGPoint(x: boundingBox.minX, y: boundingBox.maxY))
        // The region can be rotated, so the mapped box is a rotated rectangle. The
        // ROI builder only needs its centre and its side lengths, so those are what
        // is reconstructed here — taking the axis-aligned hull instead would inflate
        // the box by up to sqrt(2) on a rolled head and silently change the ROI.
        let width = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let height = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        let center = region.imagePoint(
            fromNormalized: CGPoint(x: boundingBox.midX, y: boundingBox.midY))
        let box = CGRect(
            x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        return BlazeFaceDetection(
            boundingBox: box,
            keypoints: keypoints.map { region.imagePoint(fromNormalized: $0) },
            score: score)
    }
}
