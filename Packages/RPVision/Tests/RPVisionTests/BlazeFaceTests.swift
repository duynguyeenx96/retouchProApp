import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import RPVision

@Suite("BlazeFace anchors")
struct BlazeFaceAnchorTests {
    /// The anchor grid is a *reconstruction* of MediaPipe's `SsdAnchorsCalculator`
    /// config, and nothing in the `.mlpackage` says it is right. The count is the
    /// first check — the model's anchor axis is 896 and only one layer layout gives
    /// that — and the layout is the second.
    @Test("896 anchors, 16x16x2 then 8x8x6")
    func layout() {
        #expect(BlazeFaceAnchors.centers.count == BlazeFaceAnchors.count)
        #expect(BlazeFaceAnchors.count == 16 * 16 * 2 + 8 * 8 * 6)

        // First cell of the stride-8 layer: centre of the top-left 8px cell.
        #expect(abs(BlazeFaceAnchors.centers[0].x - 0.5 / 16) < 1e-12)
        #expect(abs(BlazeFaceAnchors.centers[0].y - 0.5 / 16) < 1e-12)
        // Two anchors share every stride-8 cell.
        #expect(BlazeFaceAnchors.centers[0] == BlazeFaceAnchors.centers[1])
        #expect(BlazeFaceAnchors.centers[1] != BlazeFaceAnchors.centers[2])
        // ... and six share every stride-16 cell.
        #expect(BlazeFaceAnchors.centers[512] == BlazeFaceAnchors.centers[517])
        #expect(BlazeFaceAnchors.centers[512] != BlazeFaceAnchors.centers[518])
        #expect(abs(BlazeFaceAnchors.centers[512].x - 0.5 / 8) < 1e-12)
        // Last anchor is the bottom-right 16px cell.
        let last = BlazeFaceAnchors.centers[BlazeFaceAnchors.count - 1]
        #expect(abs(last.x - 7.5 / 8) < 1e-12)
        #expect(abs(last.y - 7.5 / 8) < 1e-12)
    }
}

@Suite("BlazeFace decode and NMS")
struct BlazeFaceDecoderTests {
    /// Builds a raw tensor with one strongly-positive anchor.
    private func tensors(
        anchorIndex: Int, logit: Float, dx: Float = 0, dy: Float = 0, size: Float = 32
    ) -> (regressors: [Float], logits: [Float]) {
        var regressors = [Float](
            repeating: 0, count: BlazeFaceAnchors.count * BlazeFaceDecoder.valuesPerAnchor)
        var logits = [Float](repeating: -20, count: BlazeFaceAnchors.count)
        let base = anchorIndex * BlazeFaceDecoder.valuesPerAnchor
        regressors[base + 0] = dx
        regressors[base + 1] = dy
        regressors[base + 2] = size
        regressors[base + 3] = size
        for k in 0..<BlazeFaceDetection.keypointCount {
            regressors[base + BlazeFaceDecoder.keypointOffset + k * 2] = Float(k) - 2
            regressors[base + BlazeFaceDecoder.keypointOffset + k * 2 + 1] = Float(k)
        }
        logits[anchorIndex] = logit
        return (regressors, logits)
    }

    @Test("Anchor offsets decode to a normalised box")
    func decodesOneBox() {
        let index = 600  // a stride-16 anchor
        let anchor = BlazeFaceAnchors.centers[index]
        let (regressors, logits) = tensors(anchorIndex: index, logit: 4, dx: 8, dy: -4)
        let detections = BlazeFaceDecoder.decode(regressors: regressors, scoreLogits: logits)

        #expect(detections.count == 1)
        let d = try! #require(detections.first)
        // x_center = raw/128 + anchor.x, w = raw/128 (fixed_anchor_size => anchor 1x1)
        #expect(abs(d.boundingBox.midX - (anchor.x + 8.0 / 128)) < 1e-6)
        #expect(abs(d.boundingBox.midY - (anchor.y - 4.0 / 128)) < 1e-6)
        #expect(abs(d.boundingBox.width - 32.0 / 128) < 1e-6)
        #expect(abs(Double(d.score) - 1 / (1 + exp(-4.0))) < 1e-6)
        #expect(d.keypoints.count == 6)
        // Keypoint k is (k-2, k) in input pixels relative to the anchor centre.
        #expect(abs(d.keypoint(.noseTip).x - (anchor.x + 0.0 / 128)) < 1e-6)
        #expect(abs(d.keypoint(.noseTip).y - (anchor.y + 2.0 / 128)) < 1e-6)
    }

    @Test("Anchors below min_score_thresh are dropped")
    func thresholds() {
        let (regressors, logits) = tensors(anchorIndex: 10, logit: -0.5)  // sigmoid 0.378
        #expect(BlazeFaceDecoder.decode(regressors: regressors, scoreLogits: logits).isEmpty)
        var options = BlazeFaceDecoder.Options()
        options.minScore = 0.3
        #expect(
            BlazeFaceDecoder.decode(
                regressors: regressors, scoreLogits: logits, options: options
            ).count == 1)
    }

    /// The distinguishing feature of MediaPipe's WEIGHTED NMS: the survivor is the
    /// score-weighted mean of the whole cluster, not the top box. Plain greedy NMS
    /// would return `a` unchanged and move the ROI by a fraction of a face width.
    @Test("Weighted NMS averages the cluster it suppresses")
    func weightedNMS() {
        func detection(x: CGFloat, score: Float) -> BlazeFaceDetection {
            BlazeFaceDetection(
                boundingBox: CGRect(x: x, y: 0, width: 0.4, height: 0.4),
                keypoints: (0..<6).map { _ in CGPoint(x: x, y: 0) }, score: score)
        }
        let a = detection(x: 0.30, score: 0.9)
        let b = detection(x: 0.34, score: 0.3)
        let far = detection(x: 0.90, score: 0.8)
        let merged = BlazeFaceDecoder.weightedNonMaxSuppression(
            [a, b, far], options: BlazeFaceDecoder.Options())

        #expect(merged.count == 2)
        let first = merged[0]
        let expected = (0.30 * 0.9 + 0.34 * 0.3) / (0.9 + 0.3)
        #expect(abs(first.boundingBox.minX - CGFloat(expected)) < 1e-6)
        #expect(abs(first.keypoints[0].x - CGFloat(expected)) < 1e-6)
        // MediaPipe keeps the best detection's score, not the cluster mean.
        #expect(first.score == 0.9)
        #expect(abs(merged[1].boundingBox.minX - 0.90) < 1e-6)
    }

    @Test("maxFaces caps the output")
    func caps() {
        var detections: [BlazeFaceDetection] = []
        for i in 0..<10 {
            detections.append(
                BlazeFaceDetection(
                    boundingBox: CGRect(x: CGFloat(i) * 0.1, y: 0, width: 0.05, height: 0.05),
                    keypoints: Array(repeating: .zero, count: 6), score: Float(10 - i) / 10))
        }
        var options = BlazeFaceDecoder.Options()
        options.maxFaces = 3
        let kept = BlazeFaceDecoder.weightedNonMaxSuppression(detections, options: options)
        #expect(kept.count == 3)
        #expect(kept.map(\.score) == [1.0, 0.9, 0.8])
    }

    @Test("Detections map into image space through the region they were found in")
    func mapping() {
        let region = CropRegion(
            center: CGPoint(x: 500, y: 400), side: 200, rotation: 0, outputSide: 128)
        let d = BlazeFaceDetection(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            keypoints: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 6), score: 1)
        let mapped = d.mapped(through: region)
        #expect(abs(mapped.boundingBox.midX - 500) < 1e-9)
        #expect(abs(mapped.boundingBox.midY - 400) < 1e-9)
        #expect(abs(mapped.boundingBox.width - 100) < 1e-9)
        #expect(abs(mapped.keypoints[0].x - 500) < 1e-9)
    }
}

@Suite("BlazeFace Core ML model", .serialized)
struct BlazeFaceModelTests {
    /// Restores the flag to `true` rather than leaving it off: `FaceAnalyzerTests`
    /// runs in a different suite, Swift Testing runs suites concurrently, and a
    /// flag left `false` here switches that suite's analyzer off mid-construction.
    /// Same hazard `RPVisionFeatureFlags.resetToDefaults()` documents.
    @Test("Constructing the model with the feature flag off throws")
    func flagGatesConstruction() throws {
        let url = try #require(Phase2Resources.blazeFaceModel, "Phase2 model missing")
        RPVisionFeatureFlags.blazeFaceShortRange = false
        #expect(throws: RPVisionFeatureDisabled.self) {
            _ = try BlazeFaceModel(url: url)
        }
        RPVisionFeatureFlags.blazeFaceShortRange = true
    }

    /// The golden was decoded on the Python side (`make_test_fixture.py`), so this
    /// checks the Swift anchor table, the reverse-output-order decode and the
    /// weighted NMS against an independent implementation of the same MediaPipe
    /// calculators — not against themselves.
    @Test("Reproduces the Python-decoded golden detection")
    func matchesGolden() throws {
        let modelURL = try #require(Phase2Resources.blazeFaceModel, "Phase2 model missing")
        let inputURL = try #require(Phase2Resources.detectorInput)
        let image = try #require(Phase2Resources.image(at: inputURL))
        let golden = try #require(try Phase2Resources.loadGolden())

        RPVisionFeatureFlags.blazeFaceShortRange = true
        let model = try BlazeFaceModel(url: modelURL)
        let renderer = CropRegionRenderer()
        // Identity region: the fixture is already 128px, so nothing is resampled
        // and the only difference from the Python run is Core Image's colour
        // handling, not geometry.
        let region = CropRegion(
            center: CGPoint(x: 64, y: 64), side: 128, rotation: 0, outputSide: 128)
        let buffer = try renderer.render(image, region: region)
        let output = try model.predict(image: buffer)
        #expect(output.regressors.count == BlazeFaceAnchors.count * 16)
        #expect(output.scoreLogits.count == BlazeFaceAnchors.count)

        let detections = BlazeFaceDecoder.decode(
            regressors: output.regressors, scoreLogits: output.scoreLogits)
        let best = try #require(detections.first)

        #expect(abs(Double(best.score) - golden.score) < 0.01)
        let box = golden.box_xywh_normalised
        // Tolerance is in normalised units: 0.01 is 1.28 px of the 128px input.
        #expect(abs(Double(best.boundingBox.minX) - box[0]) < 0.01)
        #expect(abs(Double(best.boundingBox.minY) - box[1]) < 0.01)
        #expect(abs(Double(best.boundingBox.width) - box[2]) < 0.01)
        #expect(abs(Double(best.boundingBox.height) - box[3]) < 0.01)
        for (index, expected) in golden.keypoints_normalised.enumerated() {
            #expect(abs(Double(best.keypoints[index].x) - expected[0]) < 0.01)
            #expect(abs(Double(best.keypoints[index].y) - expected[1]) < 0.01)
        }

        // Geometry, not just numbers: a swapped keypoint table would still be
        // within tolerance of *some* golden, so assert the face makes sense.
        #expect(best.keypoint(.rightEye).x < best.keypoint(.leftEye).x)
        #expect(best.keypoint(.rightEye).y < best.keypoint(.mouthCenter).y)
        #expect(best.keypoint(.noseTip).y < best.keypoint(.mouthCenter).y)
        #expect(best.keypoint(.rightEarTragion).x < best.keypoint(.rightEye).x)
    }

    @Test("decode rejects a tensor with the wrong anchor count")
    func decodeRejectsWrongShape() throws {
        let regressors = try MLMultiArray(shape: [100, 16], dataType: .float32)
        let logits = try MLMultiArray(shape: [896], dataType: .float32)
        #expect(throws: BlazeFaceError.self) {
            _ = try BlazeFaceModel.decode(regressors: regressors, scoreLogits: logits)
        }
    }
}
