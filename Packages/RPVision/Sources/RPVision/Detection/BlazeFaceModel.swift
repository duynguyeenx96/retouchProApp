import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Thin wrapper around the Core ML build of MediaPipe's
/// `blaze_face_short_range.tflite`.
///
/// Same shape as `FaceLandmark478Model` / `FaceParsingModel`: the caller passes the
/// model URL (the `.mlpackage` is not bundled with RPVision yet — it lives in
/// `Research/spikes/S1-landmark/models/BlazeFaceShortRange.mlpackage`), the
/// `.mlpackage` → `.mlmodelc` compile goes through the shared
/// `CompiledModelCache`, and the whole path is behind a default-off flag.
///
/// The graph emits raw tensors on purpose; `BlazeFaceDecoder` does the anchor
/// decode, the sigmoid and the weighted NMS.
public final class BlazeFaceModel {
    public static let inputSide = BlazeFaceAnchors.inputSide

    public struct Output: Sendable {
        /// 896 x 16, row-major.
        public var regressors: [Float]
        /// 896 raw logits.
        public var scoreLogits: [Float]
    }

    private let model: MLModel
    private let options: MLPredictionOptions

    public init(url: URL, computeUnits: MLComputeUnits = .all) throws {
        guard RPVisionFeatureFlags.blazeFaceShortRange else {
            throw RPVisionFeatureDisabled(feature: "blazeFaceShortRange")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled = try CompiledModelCache.compiledURL(for: url)
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.options = MLPredictionOptions()
    }

    /// Runs the network on a 128x128 BGRA buffer.
    public func predict(image pixelBuffer: CVPixelBuffer) throws -> Output {
        let value = MLFeatureValue(pixelBuffer: pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": value])
        let result = try model.prediction(from: provider, options: options)
        guard let regressors = result.featureValue(for: "regressors")?.multiArrayValue else {
            throw BlazeFaceError.missingOutput("regressors")
        }
        guard let logits = result.featureValue(for: "score_logits")?.multiArrayValue else {
            throw BlazeFaceError.missingOutput("score_logits")
        }
        return try Self.decode(regressors: regressors, scoreLogits: logits)
    }

    /// Reads the two output tensors into flat `Float` arrays.
    ///
    /// The element counts are checked rather than assumed: a converter change that
    /// emitted `[1, 896, 16]` with a different anchor count would otherwise decode
    /// into boxes that look plausible and are in the wrong places.
    static func decode(regressors: MLMultiArray, scoreLogits: MLMultiArray) throws -> Output {
        let anchors = BlazeFaceAnchors.count
        guard regressors.count == anchors * BlazeFaceDecoder.valuesPerAnchor else {
            throw BlazeFaceError.unexpectedShape(
                "regressors", regressors.shape.map(\.intValue))
        }
        guard scoreLogits.count == anchors else {
            throw BlazeFaceError.unexpectedShape(
                "score_logits", scoreLogits.shape.map(\.intValue))
        }
        return Output(regressors: flatten(regressors), scoreLogits: flatten(scoreLogits))
    }

    /// `MLMultiArray` subscripting is avoided on the fast path but kept as the
    /// fallback, because Core ML hands back float16 on some compute units.
    private static func flatten(_ array: MLMultiArray) -> [Float] {
        if array.dataType == .float32 {
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

public enum BlazeFaceError: Error, CustomStringConvertible {
    case missingOutput(String)
    case unexpectedShape(String, [Int])
    case noFaceDetected

    public var description: String {
        switch self {
        case .missingOutput(let name):
            "BlazeFace Core ML model produced no '\(name)' output"
        case .unexpectedShape(let name, let shape):
            "BlazeFace '\(name)' has shape \(shape); expected \(BlazeFaceAnchors.count) anchors"
        case .noFaceDetected:
            "BlazeFace found no face in the region it was given"
        }
    }
}
