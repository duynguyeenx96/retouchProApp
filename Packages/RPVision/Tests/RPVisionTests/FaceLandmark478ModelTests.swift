import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing

@testable import RPVision

/// Locates the spike S1 artefacts copied into the test bundle.
enum SpikeResources {
    /// SwiftPM, Xcode-for-macOS and Xcode-for-iOS each lay the copied `SpikeS1`
    /// directory out slightly differently, so probe for the marker file.
    static let root: URL? = {
        var candidates: [URL] = []
        for base in [Bundle.module.resourceURL, Bundle.module.bundleURL].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent("SpikeS1"))
            candidates.append(base)
            candidates.append(base.appendingPathComponent("Contents/Resources/SpikeS1"))
            candidates.append(base.appendingPathComponent("Contents/Resources"))
        }
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("face_crop_256.png").path)
        }
    }()

    /// Xcode may compile a bundled `.mlpackage` into `.mlmodelc`; accept either.
    static var model: URL? {
        guard let root else { return nil }
        for name in ["FaceLandmark478.mlmodelc", "FaceLandmark478.mlpackage"] {
            let candidate = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var faceCrop: URL? { root?.appendingPathComponent("face_crop_256.png") }
    static var golden: URL? { root?.appendingPathComponent("face_crop_256_golden.json") }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    struct Golden: Decodable {
        var score: Double
        var crop_points: [Double]
    }
}

@Suite("478-point landmark model", .serialized)
struct FaceLandmark478ModelTests {
    /// The whole landmark path is behind a flag until Phase 2 wires up FaceAnalyzer.
    @Test("Constructing the model with the feature flag off throws")
    func flagGatesConstruction() throws {
        RPVisionFeatureFlags.faceLandmarks478 = false
        #expect(RPVisionFeatureFlags.faceLandmarks478 == false)
        let url = try #require(SpikeResources.model)
        #expect(throws: RPVisionFeatureDisabled.self) {
            _ = try FaceLandmark478Model(url: url)
        }
    }

    @Test("Reproduces the golden landmarks for the spike's 256px crop")
    func matchesGolden() throws {
        let modelURL = try #require(SpikeResources.model, "spike model resource missing")
        let cropURL = try #require(SpikeResources.faceCrop)
        let goldenURL = try #require(SpikeResources.golden)
        let cropImage = try #require(SpikeResources.image(at: cropURL))
        let golden = try JSONDecoder().decode(
            SpikeResources.Golden.self, from: Data(contentsOf: goldenURL))

        RPVisionFeatureFlags.faceLandmarks478 = true
        defer { RPVisionFeatureFlags.faceLandmarks478 = false }

        let model = try FaceLandmark478Model(url: modelURL)
        let renderer = FaceCropRenderer()
        // The resource is already a 256x256 crop, so the identity ROI re-renders it 1:1.
        let identity = FaceCrop(center: CGPoint(x: 128, y: 128), side: 256, rotation: 0)
        let buffer = try renderer.render(cropImage, crop: identity)
        let output = try model.predict(crop: buffer)

        #expect(output.cropPoints.count == FaceLandmarks478.pointCount)
        #expect(output.score > 0.9, "face presence should be ~1 on a real crop, got \(output.score)")

        var maxError = 0.0
        for i in 0..<FaceLandmarks478.pointCount {
            let dx = Double(output.cropPoints[i].x) - golden.crop_points[i * 2]
            let dy = Double(output.cropPoints[i].y) - golden.crop_points[i * 2 + 1]
            maxError = max(maxError, (dx * dx + dy * dy).squareRoot())
        }
        // The golden was captured on the Mac's ANE. A different compute unit (or the
        // Simulator, which has none) reorders fp16 arithmetic, so this is a sanity
        // bound, not a bit-exactness claim; the exact-numerics check against TFLite
        // lives in Research/spikes/S1-landmark/verify_coreml_vs_tflite.py.
        #expect(maxError < 2.0, "max landmark drift from golden: \(maxError) px")
    }

    @Test("Landmarks stay inside the crop and the mesh has sane proportions")
    func outputSanity() throws {
        let modelURL = try #require(SpikeResources.model)
        let cropURL = try #require(SpikeResources.faceCrop)
        let cropImage = try #require(SpikeResources.image(at: cropURL))
        RPVisionFeatureFlags.faceLandmarks478 = true
        defer { RPVisionFeatureFlags.faceLandmarks478 = false }

        let model = try FaceLandmark478Model(url: modelURL)
        let identity = FaceCrop(center: CGPoint(x: 128, y: 128), side: 256, rotation: 0)
        let output = try model.predict(
            crop: try FaceCropRenderer().render(cropImage, crop: identity))

        let xs = output.cropPoints.map(\.x)
        let ys = output.cropPoints.map(\.y)
        #expect(xs.min()! > -32 && xs.max()! < 288)
        #expect(ys.min()! > -32 && ys.max()! < 288)
        // Landmark 1 is the nose tip, 33/263 the outer eye corners: the nose must sit
        // between the eyes horizontally. Catches a transposed or mirrored output.
        let nose = output.cropPoints[1]
        let rightEye = output.cropPoints[33]
        let leftEye = output.cropPoints[263]
        #expect(rightEye.x < nose.x && nose.x < leftEye.x)
    }
}
