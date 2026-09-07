import CoreGraphics
import Foundation
import RPEngine
import RPVision

/// `RPEngine.FaceInputProviding` on top of RPVision's `FaceAnalyzer`.
///
/// Lives in the app target for the same reason `FaceAnalysisRenderBridge` does:
/// it is the only place that links both packages, and RPEngine must not link
/// Core ML (docs/ADR-0007, and that file's long note). It is a five-line adapter
/// on purpose — every judgement about geometry and masks is already in the
/// bridge, and duplicating any of it here is how the two would drift apart.
///
/// ## Cache key
///
/// `FaceAnalyzer` caches by whatever string it is handed, and this passes
/// `"<contentHash>@<width>x<height>"`. The pixel size has to be in the key: the
/// same file analysed at 2048 px and at 24 MP gives coordinates in different
/// grids, and Phase 3's export will ask for the second one. Without the size, an
/// export would silently be handed the preview's landmarks.
///
/// ## Where the cost goes
///
/// One analysis per shot per size: cold ~47 ms on an M-series Mac, warm 0.052 ms
/// (`Research/bench/p2-face-analyzer-cache-macos.json`). The actor also
/// coalesces concurrent callers with the same key onto one run, which is exactly
/// the case a fast filmstrip walk produces.
final class FaceAnalyzerFaceInputProvider: FaceInputProviding {
    private let analyzer: FaceAnalyzer

    init(analyzer: FaceAnalyzer) {
        self.analyzer = analyzer
    }

    /// Why there is no provider, when there is none.
    ///
    /// The app still opens without one — an editor that refuses to start because
    /// a 25 MB model is missing would be worse than one whose face-dependent
    /// sliders say they are unavailable — but the reason has to reach
    /// `session.log`. Before docs/ADR-0015 both failures were the same silent
    /// `nil`, which is how "the models are not in the app" looked identical to
    /// "this photo has no face".
    enum Outcome {
        case ready(FaceAnalyzerFaceInputProvider)
        case noModels
        case analyzerFailed(any Error)

        var provider: FaceAnalyzerFaceInputProvider? {
            if case .ready(let provider) = self { return provider }
            return nil
        }

        /// Appended to the model-discovery line in the startup log.
        var diagnostic: String? {
            switch self {
            case .ready: nil
            case .noModels: nil  // discoverModels() already said where it looked.
            case .analyzerFailed(let error):
                "FaceAnalyzer refused the models it found: \(error)"
            }
        }
    }

    /// Builds one if the flags are on and the models were found.
    static func standard(models: FaceAnalyzer.Models?) -> Outcome {
        guard let models else { return .noModels }
        do {
            return .ready(FaceAnalyzerFaceInputProvider(analyzer: try FaceAnalyzer(models: models)))
        } catch {
            return .analyzerFailed(error)
        }
    }

    /// Runs one analysis and **writes the outcome to `session.log`**.
    ///
    /// Not decoration: on a real iPhone this file is the only readable trace of
    /// what the face pipeline did (`devicectl device copy from --domain-type
    /// appDataContainer`). `LivePreviewController` keeps the failure in
    /// `failureMessage` for the canvas and mirrors it to the unified log, but
    /// "0 faces" is not a failure there and still has to be visible — a photo
    /// where detection quietly finds nothing looks exactly like a build with no
    /// models, which is the confusion docs/ADR-0015 was written about.
    ///
    /// One line per shot open, not per frame: the caller
    /// (`LivePreviewController.open`) runs this once per shot and a slider drag
    /// never reaches it (docs/ADR-0013).
    func faceInputs(
        for image: PreviewImage, contentHash: String, kinds: Set<RenderMaskKind>
    ) async throws -> [FaceRenderInput] {
        let key = Self.cacheKey(contentHash: contentHash, size: image.pixelSize)
        let started = ContinuousClock.now
        do {
            let analysis = try await analyzer.analysis(of: image.cgImage, contentHash: key)
            // renderScale 1: the analysis ran on the very pixels the graph renders.
            let inputs = FaceAnalysisRenderBridge.renderInputs(
                from: analysis, renderScale: 1, kinds: kinds)
            let ms = Double((started.duration(to: .now)).components.attoseconds) / 1e15
            AppLog.write(
                "face analysis: \(inputs.count) face(s) in \(key) — "
                    + String(format: "%.1f ms", ms)
                    + (inputs.isEmpty ? "" : ", first box \(FaceAnalyzerFaceInputProvider.box(inputs[0]))"))
            return inputs
        } catch {
            AppLog.write("face analysis FAILED for \(key): \(error)")
            throw error
        }
    }

    /// The detected face's bounding box in preview pixels, rounded — enough to
    /// tell "it found the face" from "it found something" in a log line.
    private static func box(_ input: FaceRenderInput) -> String {
        let xs = input.landmarks.map(\.x)
        let ys = input.landmarks.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return "no landmarks" }
        return String(
            format: "(%.0f,%.0f)-(%.0f,%.0f) %d landmarks",
            minX, minY, maxX, maxY, input.landmarks.count)
    }

    static func cacheKey(contentHash: String, size: CGSize) -> String {
        "\(contentHash)@\(Int(size.width))x\(Int(size.height))"
    }
}
