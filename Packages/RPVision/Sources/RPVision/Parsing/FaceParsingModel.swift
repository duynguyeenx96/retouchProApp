import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Thin wrapper around the Core ML build of BiSeNet face parsing
/// (CelebAMask-HQ, 19 classes). Like `FaceLandmark478Model`, the `.mlpackage`
/// is *not* bundled with RPVision yet — spike S2 keeps it in
/// `Research/spikes/S2-face-parsing/models/` and Phase 2 decides where it ships.
///
/// The model takes RGB 0-255 and applies the ImageNet normalisation inside its own
/// graph (see `convert_bisenet_to_coreml.py`), so there is no preprocessing to get
/// wrong on this side: hand it a 512x512 BGRA buffer and read `labels`.
public final class FaceParsingModel {
    /// Side of the square input the converted model was traced at.
    public static let inputSide = 512

    private let model: MLModel
    private let options: MLPredictionOptions

    public init(url: URL, computeUnits: MLComputeUnits = .all) throws {
        guard RPVisionFeatureFlags.faceParsing19 else {
            throw RPVisionFeatureDisabled(feature: "faceParsing19")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled = try CompiledModelCache.compiledURL(for: url)
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        self.options = MLPredictionOptions()
    }

    /// Runs the network on a 512x512 BGRA buffer and returns the class map.
    public func predict(image pixelBuffer: CVPixelBuffer) throws -> FaceParsingMask {
        let value = MLFeatureValue(pixelBuffer: pixelBuffer)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": value])
        let result = try model.prediction(from: provider, options: options)
        guard let labels = result.featureValue(for: "labels")?.multiArrayValue else {
            throw FaceParsingError.missingOutput("labels")
        }
        return try Self.decode(labels: labels)
    }

    /// Reads the int32 `[1, 512, 512]` output into a byte mask.
    ///
    /// The shape is checked rather than assumed: a converter change that made this
    /// `[1, 19, 512, 512]` (logits instead of argmax) would otherwise be read as a
    /// class map of the first channel and produce plausible-looking garbage.
    static func decode(labels: MLMultiArray) throws -> FaceParsingMask {
        let shape = labels.shape.map(\.intValue)
        let spatial = shape.filter { $0 > 1 }
        guard spatial.count == 2, spatial[0] == spatial[1] else {
            throw FaceParsingError.unexpectedShape(shape)
        }
        let side = spatial[0]
        var bytes = [UInt8](repeating: 0, count: side * side)
        // Fast path when Core ML hands back the int32 the model declares; the
        // generic path covers a runtime that promotes it (some compute units
        // return float32 for integer outputs).
        if labels.dataType == .int32 {
            labels.withUnsafeBufferPointer(ofType: Int32.self) { buffer in
                for i in 0..<bytes.count {
                    let raw = buffer[i]
                    bytes[i] = (raw >= 0 && raw < 19) ? UInt8(raw) : 0
                }
            }
        } else {
            for i in 0..<bytes.count {
                let raw = labels[i].intValue
                bytes[i] = (raw >= 0 && raw < 19) ? UInt8(raw) : 0
            }
        }
        return FaceParsingMask(width: side, height: side, labels: bytes)
    }
}

public enum FaceParsingError: Error, CustomStringConvertible {
    case missingOutput(String)
    case unexpectedShape([Int])

    public var description: String {
        switch self {
        case .missingOutput(let name):
            "Core ML face-parsing model produced no '\(name)' output"
        case .unexpectedShape(let shape):
            "face-parsing 'labels' has shape \(shape); expected one square HxW plane"
        }
    }
}
