import CoreGraphics
import Foundation

/// Turns the detector's two raw tensors into detections.
///
/// This is MediaPipe's `TensorsToDetectionsCalculator` followed by
/// `NonMaxSuppressionCalculator`, both ported rather than folded into the Core ML
/// graph: they are a few hundred microseconds of scalar maths, and keeping them in
/// Swift means they can be unit-tested without loading a model
/// (`BlazeFaceDecoderTests`).
///
/// `TensorsToDetectionsCalculator` options for `face_detection_short_range`:
/// ```
/// num_classes: 1        num_boxes: 896      num_coords: 16
/// box_coord_offset: 0   keypoint_coord_offset: 4
/// num_keypoints: 6      num_values_per_keypoint: 2
/// sigmoid_score: true   score_clipping_thresh: 100.0
/// reverse_output_order: true
/// x_scale: 128  y_scale: 128  w_scale: 128  h_scale: 128
/// min_score_thresh: 0.5
/// ```
/// `reverse_output_order: true` is what makes the first four regressor values
/// `(x_center, y_center, w, h)` instead of `(y, x, h, w)`, and each keypoint
/// `(x, y)` instead of `(y, x)`.
///
/// NMS options from the same graph: `min_suppression_threshold: 0.3`,
/// `overlap_type: INTERSECTION_OVER_UNION`, `algorithm: WEIGHTED`. Weighted is not
/// the usual "keep the best, drop the rest": the surviving detection's box **and
/// keypoints** are the score-weighted mean of every box it suppressed, so plain
/// greedy NMS would move the ROI by a fraction of a face width.
public enum BlazeFaceDecoder {
    public static let valuesPerAnchor = 16
    public static let keypointOffset = 4

    public struct Options: Sendable, Equatable, Hashable, Codable {
        /// `min_score_thresh` in the graph.
        public var minScore: Float = 0.5
        /// `min_suppression_threshold` in the graph.
        public var iouThreshold: Float = 0.3
        /// `score_clipping_thresh` in the graph.
        public var scoreClip: Float = 100
        /// Cap on the number of faces returned, highest score first. Not a
        /// MediaPipe option; a guard so a noisy frame cannot make the analyzer run
        /// the mesh + parsing models dozens of times.
        public var maxFaces: Int = 8

        public init(
            minScore: Float = 0.5, iouThreshold: Float = 0.3, scoreClip: Float = 100,
            maxFaces: Int = 8
        ) {
            self.minScore = minScore
            self.iouThreshold = iouThreshold
            self.scoreClip = scoreClip
            self.maxFaces = maxFaces
        }
    }

    /// - Parameters:
    ///   - regressors: 896 x 16, row-major.
    ///   - scoreLogits: 896 raw logits (no sigmoid applied yet).
    public static func decode(
        regressors: [Float], scoreLogits: [Float], options: Options = Options()
    ) -> [BlazeFaceDetection] {
        let anchors = BlazeFaceAnchors.centers
        precondition(regressors.count == anchors.count * valuesPerAnchor)
        precondition(scoreLogits.count == anchors.count)
        let scale = CGFloat(BlazeFaceAnchors.inputSide)

        var raw: [BlazeFaceDetection] = []
        for i in 0..<anchors.count {
            let clipped = min(max(scoreLogits[i], -options.scoreClip), options.scoreClip)
            let score = 1 / (1 + exp(-clipped))
            guard score >= options.minScore else { continue }
            let base = i * valuesPerAnchor
            let anchor = anchors[i]
            let cx = CGFloat(regressors[base + 0]) / scale + anchor.x
            let cy = CGFloat(regressors[base + 1]) / scale + anchor.y
            let w = CGFloat(regressors[base + 2]) / scale
            let h = CGFloat(regressors[base + 3]) / scale
            var keypoints: [CGPoint] = []
            keypoints.reserveCapacity(BlazeFaceDetection.keypointCount)
            for k in 0..<BlazeFaceDetection.keypointCount {
                let o = base + keypointOffset + k * 2
                keypoints.append(
                    CGPoint(
                        x: CGFloat(regressors[o + 0]) / scale + anchor.x,
                        y: CGFloat(regressors[o + 1]) / scale + anchor.y))
            }
            raw.append(
                BlazeFaceDetection(
                    boundingBox: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                    keypoints: keypoints, score: score))
        }
        return weightedNonMaxSuppression(raw, options: options)
    }

    /// `NonMaxSuppressionCalculator` with `algorithm: WEIGHTED`.
    static func weightedNonMaxSuppression(
        _ detections: [BlazeFaceDetection], options: Options
    ) -> [BlazeFaceDetection] {
        var remaining = detections.sorted { $0.score > $1.score }
        var output: [BlazeFaceDetection] = []
        while let best = remaining.first, output.count < options.maxFaces {
            var cluster: [BlazeFaceDetection] = []
            var rest: [BlazeFaceDetection] = []
            for candidate in remaining {
                if intersectionOverUnion(candidate.boundingBox, best.boundingBox)
                    > CGFloat(options.iouThreshold)
                {
                    cluster.append(candidate)
                } else {
                    rest.append(candidate)
                }
            }
            output.append(cluster.count > 1 ? weightedMean(cluster, fallback: best) : best)
            remaining = rest
        }
        return output
    }

    static func weightedMean(
        _ cluster: [BlazeFaceDetection], fallback: BlazeFaceDetection
    ) -> BlazeFaceDetection {
        let total = cluster.reduce(CGFloat(0)) { $0 + CGFloat($1.score) }
        guard total > 0 else { return fallback }
        var minX: CGFloat = 0, minY: CGFloat = 0, maxX: CGFloat = 0, maxY: CGFloat = 0
        var keypoints = [CGPoint](repeating: .zero, count: BlazeFaceDetection.keypointCount)
        for d in cluster {
            let w = CGFloat(d.score)
            minX += w * d.boundingBox.minX
            minY += w * d.boundingBox.minY
            maxX += w * d.boundingBox.maxX
            maxY += w * d.boundingBox.maxY
            for k in 0..<BlazeFaceDetection.keypointCount {
                keypoints[k].x += w * d.keypoints[k].x
                keypoints[k].y += w * d.keypoints[k].y
            }
        }
        let box = CGRect(
            x: minX / total, y: minY / total,
            width: (maxX - minX) / total, height: (maxY - minY) / total)
        return BlazeFaceDetection(
            boundingBox: box,
            keypoints: keypoints.map { CGPoint(x: $0.x / total, y: $0.y / total) },
            // MediaPipe keeps the *best* detection's score, not the mean.
            score: fallback.score)
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        return union <= 0 ? 0 : inter / union
    }
}
