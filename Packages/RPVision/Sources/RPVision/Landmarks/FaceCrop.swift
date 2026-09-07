import CoreGraphics
import Foundation

/// A rotated square region of an image, in **image pixels with the origin at the
/// top-left and y increasing downwards** — the same convention MediaPipe uses, so
/// the numbers here can be compared against its Python reference directly.
///
/// The 478-point model always consumes a 256x256 crop, so `side` is the length of
/// the square in source pixels and `Self.outputSide` is what it is resampled to.
public struct FaceCrop: Sendable, Equatable {
    /// Centre of the square, in image pixels (y down).
    public var center: CGPoint
    /// Side length of the square, in image pixels.
    public var side: CGFloat
    /// Clockwise rotation in radians, in the y-down frame.
    public var rotation: CGFloat

    public static let outputSide: CGFloat = 256

    public init(center: CGPoint, side: CGFloat, rotation: CGFloat) {
        self.center = center
        self.side = side
        self.rotation = rotation
    }

    /// Scale from crop pixels to image pixels.
    public var pixelsPerCropPixel: CGFloat { side / Self.outputSide }

    /// Maps crop space (0…256, y down) to image space (y down).
    public var cropToImage: CGAffineTransform {
        let s = pixelsPerCropPixel
        let half = Self.outputSide / 2
        return CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: rotation)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -half, y: -half)
    }

    /// Maps image space (y down) to crop space (0…256, y down).
    public var imageToCrop: CGAffineTransform { cropToImage.inverted() }

    public func imagePoint(fromCrop point: CGPoint) -> CGPoint {
        point.applying(cropToImage)
    }

    public func cropPoint(fromImage point: CGPoint) -> CGPoint {
        point.applying(imageToCrop)
    }

    /// Builds the region of interest the way MediaPipe's Face Landmarker does:
    /// `DetectionsToRectsCalculator` takes the detector's box centre and the angle
    /// between the two eye keypoints, then `RectTransformationCalculator` runs with
    /// `square_long = true, scale_x = scale_y = 1.5`.
    ///
    /// - Parameters:
    ///   - boundingBox: face box in image pixels, y down.
    ///   - rightEye: the subject's right eye (image-left for a frontal face), y down.
    ///     MediaPipe uses detection keypoint 0 here.
    ///   - leftEye: the subject's left eye, MediaPipe keypoint 1.
    ///   - scale: 1.5 matches `face_landmarker`'s graph.
    public static func mediaPipeStyle(
        boundingBox: CGRect,
        rightEye: CGPoint?,
        leftEye: CGPoint?,
        scale: CGFloat = 1.5
    ) -> FaceCrop {
        var rotation: CGFloat = 0
        if let rightEye, let leftEye {
            // MediaPipe: rotation = NormalizeRadians(target_angle - atan2(-(y1-y0), x1-x0))
            // with target_angle = 0, which reduces to atan2(y1-y0, x1-x0) in a y-down frame.
            rotation = normalizeRadians(atan2(leftEye.y - rightEye.y, leftEye.x - rightEye.x))
        }
        let longSide = max(boundingBox.width, boundingBox.height)
        return FaceCrop(center: CGPoint(x: boundingBox.midX, y: boundingBox.midY),
                        side: longSide * scale,
                        rotation: rotation)
    }

    /// MediaPipe's own graph uses 1.5 because it is fed a BlazeFace box.
    /// Apple's Vision face box is systematically ~6% larger, so 1.5 over-crops.
    /// Sweeping the factor over 20 portraits (Research/spikes/S1-landmark,
    /// `results/accuracy_vs_mediapipe.json` → `C_swift_roi_scale_sweep`) put the
    /// minimum at 1.40: mean landmark error against the MediaPipe Python reference
    /// dropped from 1.014 px to 0.913 px at a 256 px face crop.
    ///
    /// Re-measured on the user's 11 real Sony a6300 frames (`a6300/results/`,
    /// spike report §4a): there the sweep bottoms out at 1.30 (1.293 px) and 1.40
    /// costs 1.399 px, but the curve is flat and no scale reaches the < 1 px bar,
    /// because the residual is Vision's ROI *rotation* and centre, not its size.
    /// Pooling both sweeps by point count (`a6300/results/roi_scale_pooled.json`)
    /// still puts the minimum at 1.40 (1.084 px, vs 1.090 at 1.35 and 1.186 at
    /// 1.30), so the constant stays. Closing the end-to-end gap needs BlazeFace's
    /// ROI, i.e. converting `blaze_face_short_range.tflite` too — a Phase 2 task.
    public static let visionBoxScale: CGFloat = 1.40

    /// Wraps an angle to (-pi, pi], matching MediaPipe's `NormalizeRadians`.
    public static func normalizeRadians(_ angle: CGFloat) -> CGFloat {
        angle - 2 * .pi * ((angle + .pi) / (2 * .pi)).rounded(.down)
    }
}

/// One face's worth of model output.
public struct FaceLandmarks478: Sendable, Equatable {
    /// 478 points in **crop** space (0…256, y down), straight out of the network.
    public var cropPoints: [CGPoint]
    /// Per-point relative depth, same order. Unitless, roughly crop pixels.
    public var depths: [CGFloat]
    /// Face-presence score in 0…1.
    public var score: Float
    /// The crop the points were produced from.
    public var crop: FaceCrop

    public init(cropPoints: [CGPoint], depths: [CGFloat], score: Float, crop: FaceCrop) {
        self.cropPoints = cropPoints
        self.depths = depths
        self.score = score
        self.crop = crop
    }

    /// The same points in image pixels (y down).
    public var imagePoints: [CGPoint] {
        let t = crop.cropToImage
        return cropPoints.map { $0.applying(t) }
    }

    public static let pointCount = 478
}
