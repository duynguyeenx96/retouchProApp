import CoreGraphics
import Foundation
import ImageIO

/// Locates the Phase 2 test artefacts.
///
/// `Phase2/` is copied into the test bundle (the BlazeFace `.mlpackage` is 348 KB);
/// the 25 MB parsing model is not, and is read from the spike directory exactly as
/// `SpikeS2Resources` does, so a checkout without `Research/` still runs everything
/// except the parsing-backed assertions.
enum Phase2Resources {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RPVisionTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RPVision
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    static let root: URL? = {
        var candidates: [URL] = []
        for base in [Bundle.module.resourceURL, Bundle.module.bundleURL].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent("Phase2"))
            candidates.append(base.appendingPathComponent("Contents/Resources/Phase2"))
        }
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("blazeface_128.png").path)
        }
    }()

    static var blazeFaceModel: URL? {
        if let override = ProcessInfo.processInfo.environment["RP_BLAZEFACE_MODEL"] {
            return URL(fileURLWithPath: override)
        }
        guard let root else { return nil }
        // Xcode may compile a bundled `.mlpackage` into `.mlmodelc`; accept either,
        // same as `SpikeResources.model`.
        for name in ["BlazeFaceShortRange.mlmodelc", "BlazeFaceShortRange.mlpackage"] {
            let candidate = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var detectorInput: URL? { root?.appendingPathComponent("blazeface_128.png") }
    static var golden: URL? { root?.appendingPathComponent("blazeface_golden.json") }

    struct Golden: Decodable {
        var score: Double
        var box_xywh_normalised: [Double]
        var keypoints_normalised: [[Double]]
        var n_cluster: Int
    }

    static func loadGolden() throws -> Golden? {
        guard let url = golden else { return nil }
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
