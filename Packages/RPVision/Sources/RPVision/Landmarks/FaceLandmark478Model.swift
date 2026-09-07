import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Thin wrapper around the Core ML build of MediaPipe's `face_landmarks_detector`
/// (478 points). The model file is *not* bundled with RPVision yet: spike S1 keeps
/// it under `Research/spikes/S1-landmark/models/`, and Phase 2 decides where it ships.
/// Callers pass the URL, so tests and the bench harness can point at the spike copy.
public final class FaceLandmark478Model {
    public struct Output: Sendable {
        public var cropPoints: [CGPoint]
        public var depths: [CGFloat]
        public var score: Float
    }

    private let model: MLModel
    private let options: MLPredictionOptions

    /// - Parameter url: either a compiled `.mlmodelc` or an `.mlpackage`
    ///   (compiled on the fly and cached in the caller's temporary directory).
    public init(url: URL, computeUnits: MLComputeUnits = .all) throws {
        guard RPVisionFeatureFlags.faceLandmarks478 else {
            throw RPVisionFeatureDisabled(feature: "faceLandmarks478")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled = try CompiledModelCache.compiledURL(for: url)
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.options = MLPredictionOptions()
    }

    /// Runs the network on a 256x256 BGRA crop.
    public func predict(crop pixelBuffer: CVPixelBuffer) throws -> Output {
        let value = MLFeatureValue(pixelBuffer: pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": value])
        let result = try model.prediction(from: provider, options: options)
        guard let landmarks = result.featureValue(for: "landmarks")?.multiArrayValue else {
            throw FaceLandmark478Error.missingOutput("landmarks")
        }
        guard let score = result.featureValue(for: "score")?.multiArrayValue else {
            throw FaceLandmark478Error.missingOutput("score")
        }
        return Self.decode(landmarks: landmarks, score: score)
    }

    /// Reads the flat 478x3 output. `MLMultiArray` subscripting is used rather
    /// than a typed buffer so the same code works whether Core ML hands back
    /// float32 or float16 for a given compute unit.
    static func decode(landmarks: MLMultiArray, score: MLMultiArray) -> Output {
        let count = FaceLandmarks478.pointCount
        var points = [CGPoint](repeating: .zero, count: count)
        var depths = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            points[i] = CGPoint(
                x: CGFloat(truncating: landmarks[i * 3]),
                y: CGFloat(truncating: landmarks[i * 3 + 1]))
            depths[i] = CGFloat(truncating: landmarks[i * 3 + 2])
        }
        return Output(cropPoints: points, depths: depths, score: score[0].floatValue)
    }
}

public enum FaceLandmark478Error: Error, CustomStringConvertible {
    case missingOutput(String)
    case noFaceDetected

    public var description: String {
        switch self {
        case .missingOutput(let name): "Core ML model produced no '\(name)' output"
        case .noFaceDetected: "Vision found no face in the image"
        }
    }
}
