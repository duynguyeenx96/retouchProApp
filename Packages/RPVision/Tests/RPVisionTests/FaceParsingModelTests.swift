import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing

@testable import RPVision

/// Locates the spike S2 artefacts.
///
/// Unlike S1, the `.mlpackage` is **not** copied into the test bundle: the parsing
/// model is 25 MB (S1's landmark model is 2.5 MB) and it is still a spike artefact
/// that Phase 2 may replace. The test bundle carries only the 512 px input and its
/// golden label map (~290 KB); the model is read from the spike directory, resolved
/// from `#filePath` so it works from SwiftPM and from Xcode on either destination.
/// `RP_S2_MODEL` overrides the path.
enum SpikeS2Resources {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RPVisionTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RPVision
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    static var model: URL? {
        if let override = ProcessInfo.processInfo.environment["RP_S2_MODEL"] {
            return URL(fileURLWithPath: override)
        }
        let candidate = repoRoot.appendingPathComponent(
            "Research/spikes/S2-face-parsing/models/FaceParsing19.mlpackage")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static let root: URL? = {
        var candidates: [URL] = []
        for base in [Bundle.module.resourceURL, Bundle.module.bundleURL].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent("SpikeS2"))
            candidates.append(base)
            candidates.append(base.appendingPathComponent("Contents/Resources/SpikeS2"))
            candidates.append(base.appendingPathComponent("Contents/Resources"))
        }
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("face_512.png").path)
        }
    }()

    static var face: URL? { root?.appendingPathComponent("face_512.png") }
    static var goldenLabels: URL? { root?.appendingPathComponent("face_512_golden_labels.png") }
    static var golden: URL? { root?.appendingPathComponent("face_512_golden.json") }

    struct Golden: Decodable {
        var labels: [String]
        var histogram: [Int]
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Reads an 8-bit greyscale PNG as raw class indices.
    static func labelBytes(at url: URL) -> [UInt8]? {
        guard let image = image(at: url) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }
}

@Suite("19-class face parsing", .serialized)
struct FaceParsingModelTests {
    /// The parsing path is behind a flag until Phase 2 wires up FaceAnalyzer and the
    /// < 150 ms bar has a real-device number.
    @Test("Constructing the model with the feature flag off throws")
    func flagGatesConstruction() throws {
        RPVisionFeatureFlags.faceParsing19 = false
        #expect(RPVisionFeatureFlags.faceParsing19 == false)
        let url = try #require(SpikeS2Resources.model, "spike S2 model missing")
        #expect(throws: RPVisionFeatureDisabled.self) {
            _ = try FaceParsingModel(url: url)
        }
    }

    /// Pins the class table to the order in upstream `prepropess_data.py`.
    ///
    /// This is the mistake the spike was told to watch for: nothing in the Core ML
    /// file says "17 means hair", so if this table drifts every downstream mask is
    /// silently wrong. `face_512_golden.json` carries the same list, generated from
    /// the Python side, so the two cannot drift apart unnoticed.
    @Test("Class indices match the checkpoint's training labels")
    func classIndicesMatchUpstream() throws {
        let goldenURL = try #require(SpikeS2Resources.golden)
        let golden = try JSONDecoder().decode(
            SpikeS2Resources.Golden.self, from: Data(contentsOf: goldenURL))
        #expect(golden.labels.count == 19)
        for (index, name) in golden.labels.enumerated() {
            let parsed = try #require(FaceParsingClass(rawValue: UInt8(index)))
            #expect(parsed.celebAMaskName == name, "class \(index) should be '\(name)'")
        }
        #expect(FaceParsingClass.skin.rawValue == 1)
        #expect(FaceParsingClass.hair.rawValue == 17)
        #expect(FaceParsingGroup.eyes.classes == [.leftEye, .rightEye])
    }

    @Test("Reproduces the golden parse for the spike's 512px face")
    func matchesGolden() throws {
        let modelURL = try #require(SpikeS2Resources.model, "spike S2 model missing")
        let faceURL = try #require(SpikeS2Resources.face)
        let faceImage = try #require(SpikeS2Resources.image(at: faceURL))
        let goldenLabelsURL = try #require(SpikeS2Resources.goldenLabels)
        let goldenBytes = try #require(SpikeS2Resources.labelBytes(at: goldenLabelsURL))
        let goldenURL = try #require(SpikeS2Resources.golden)
        let golden = try JSONDecoder().decode(
            SpikeS2Resources.Golden.self, from: Data(contentsOf: goldenURL))

        RPVisionFeatureFlags.faceParsing19 = true
        defer { RPVisionFeatureFlags.faceParsing19 = false }

        let model = try FaceParsingModel(url: modelURL)
        let renderer = FaceParsingRenderer()
        let buffer = try renderer.render(faceImage)
        let mask = try model.predict(image: buffer)

        #expect(mask.width == 512 && mask.height == 512)
        let reference = FaceParsingMask(width: 512, height: 512, labels: goldenBytes)

        // Not byte-equality: the golden came from coremltools' own image handling
        // and this path goes through Core Image + a CVPixelBuffer, so a handful of
        // pixels on class boundaries differ. The bar is deliberately far tighter
        // than the fp16-vs-fp32 gap the spike measured (0.024 % of pixels).
        let agreement =
            Double(zip(mask.labels, goldenBytes).count { $0 == $1 }) / Double(goldenBytes.count)
        #expect(agreement > 0.99, "label agreement with golden was \(agreement)")

        for group in [FaceParsingGroup.skin, .hair, .eyes] {
            let iou = try #require(
                mask.intersectionOverUnion(reference, classes: group.classes),
                "\(group.rawValue) missing from both masks")
            #expect(iou > 0.97, "\(group.rawValue) IoU vs golden was \(iou)")
        }

        // The histogram is the mapping check in product code: this crop is a
        // head-and-shoulders portrait, so skin and hair must dominate and the
        // classes that cannot be there must be empty.
        let histogram = mask.histogram()
        #expect(histogram[Int(FaceParsingClass.skin.rawValue)] > 20_000)
        #expect(histogram[Int(FaceParsingClass.hair.rawValue)] > 10_000)
        #expect(histogram[Int(FaceParsingClass.hat.rawValue)] == 0)
        #expect(golden.histogram.count == 19)
    }

    /// Geometry, not counts: hair sits above skin and the eyes sit inside the skin
    /// region. A permuted class table would still produce a plausible histogram but
    /// would fail this.
    @Test("Parsed classes are where a face puts them")
    func classGeometryIsSane() throws {
        let goldenLabelsURL = try #require(SpikeS2Resources.goldenLabels)
        let goldenBytes = try #require(SpikeS2Resources.labelBytes(at: goldenLabelsURL))
        let mask = FaceParsingMask(width: 512, height: 512, labels: goldenBytes)

        func centroidY(_ classes: [FaceParsingClass]) -> Double? {
            var sum = 0.0
            var count = 0
            let member = Set(classes.map(\.rawValue))
            for y in 0..<mask.height {
                for x in 0..<mask.width where member.contains(mask.labels[y * mask.width + x]) {
                    sum += Double(y)
                    count += 1
                }
            }
            return count == 0 ? nil : sum / Double(count)
        }

        let hair = try #require(centroidY([.hair]))
        let skin = try #require(centroidY([.skin]))
        let eyes = try #require(centroidY([.leftEye, .rightEye]))
        let lips = try #require(centroidY([.upperLip, .lowerLip]))
        let neck = try #require(centroidY([.neck]))

        #expect(hair < skin, "hair centroid (\(hair)) should sit above skin (\(skin))")
        #expect(eyes < lips, "eyes (\(eyes)) should sit above lips (\(lips))")
        #expect(lips < neck, "lips (\(lips)) should sit above neck (\(neck))")
    }

    @Test("decode rejects a tensor that is not a square class map")
    func decodeRejectsWrongShape() throws {
        // A converter change that emitted logits instead of argmax would hand back
        // [1, 19, 512, 512]; reading channel 0 of that as a class map would produce
        // masks that look plausible and are meaningless.
        let logitsShaped = try MLMultiArray(shape: [1, 19, 8, 8], dataType: .float32)
        #expect(throws: FaceParsingError.self) {
            _ = try FaceParsingModel.decode(labels: logitsShaped)
        }
        let square = try MLMultiArray(shape: [1, 8, 8], dataType: .int32)
        for i in 0..<64 { square[i] = NSNumber(value: Int32(i % 19)) }
        let mask = try FaceParsingModel.decode(labels: square)
        #expect(mask.width == 8 && mask.height == 8)
        #expect(mask[0, 0] == .background)
        #expect(mask[1, 0] == .skin)
    }

    @Test("Renderer produces the 512px BGRA buffer the model expects")
    func rendererShape() throws {
        let faceURL = try #require(SpikeS2Resources.face)
        let faceImage = try #require(SpikeS2Resources.image(at: faceURL))
        let buffer = try FaceParsingRenderer().render(faceImage)
        #expect(CVPixelBufferGetWidth(buffer) == FaceParsingModel.inputSide)
        #expect(CVPixelBufferGetHeight(buffer) == FaceParsingModel.inputSide)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
    }
}

@Suite("Face parsing mask maths")
struct FaceParsingMaskTests {
    @Test("Binary masks and IoU")
    func binaryAndIoU() {
        // 2x2: skin, hair / hair, background
        let a = FaceParsingMask(width: 2, height: 2, labels: [1, 17, 17, 0])
        let b = FaceParsingMask(width: 2, height: 2, labels: [1, 17, 0, 0])

        #expect(a.binaryMask(for: .skin) == [255, 0, 0, 0])
        #expect(a.binaryMask(for: .hair) == [0, 255, 255, 0])
        #expect(a.histogram()[1] == 1)
        #expect(a.histogram()[17] == 2)

        #expect(a.intersectionOverUnion(b, classes: [.skin]) == 1.0)
        #expect(a.intersectionOverUnion(b, classes: [.hair]) == 0.5)
        // Neither mask has a hat, so IoU is undefined rather than 0.
        #expect(a.intersectionOverUnion(b, classes: [.hat]) == nil)
    }
}
