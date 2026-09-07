import Foundation
import RPEngine
import RPVision

/// Turns the measured Phase 2 code on **for this app**, and finds the Core ML
/// models.
///
/// ## Why the flags are flipped here and not in the packages (docs/ADR-0013)
///
/// `RPEngineFeatureFlags` and `RPVisionFeatureFlags` default to `false`, and
/// they stay that way. Their contract, written into both files and into
/// docs/PLAN.md §2, is *"an algorithm ships behind a default-off flag until it
/// has a number from the harness"*. That is a statement about **the library**,
/// and it is the reason `RenderGraph.standard()` on a bare `import RPEngine`
/// builds an empty graph and every flag-gating test still means something.
///
/// The app is a different question: it is the product, it is where the numbers
/// get to be used, and all four groups now have them —
/// `Research/bench/p2-{color,skin,warp,eyes-teeth}-*.json`, golden PSNR 79–158 dB
/// against Double references (ADR-0009 … ADR-0012). So the *app target* switches
/// them on at launch, in one place, and a developer can switch any of them back
/// off without a rebuild:
///
/// ```
/// defaults write com.duynguyen.RetouchPro RPDisableGroups -string "skin,warp"
/// ```
///
/// ### What is deliberately still off
/// **Export.** Every number above is a 2048 px preview. ADR-0011 records that
/// the Da group's scratch is 552 MB at 24 MP and the Mắt/Răng group's is 384 MB,
/// ~936 MB together, and that it "must be checked on a real iPhone before
/// enabling both by default". This file only enables the *preview* path
/// (`LivePreviewRenderer` is constructed with `RenderQuality.preview`); the
/// export renderer is Phase 3 and has to make that call with a device in hand.
enum AppEngineSetup {

    /// User-defaults key holding a comma-separated list of groups to keep off:
    /// `color`, `skin`, `warp`, `eyesTeeth`, `face` (face analysis).
    static let disableKey = "RPDisableGroups"

    static func disabledGroups(
        defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        let raw = environment["RP_DISABLE_GROUPS"] ?? defaults.string(forKey: disableKey) ?? ""
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
    }

    /// Enables the four measured slider groups. Idempotent.
    @discardableResult
    static func enableRenderGraph(disabled: Set<String> = disabledGroups()) -> [String] {
        var enabled: [String] = []
        if !disabled.contains("color") {
            RPEngineFeatureFlags.enableColorRenderGraph()
            enabled.append("color")
        }
        if !disabled.contains("skin") {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            enabled.append("skin")
        }
        if !disabled.contains("warp") {
            RPEngineFeatureFlags.enableWarpRenderGraph()
            enabled.append("warp")
        }
        if !disabled.contains("eyesTeeth") {
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
            enabled.append("eyesTeeth")
        }
        return enabled
    }

    /// Enables the face pipeline's flags. Separate from the render graph on
    /// purpose: with no models on this machine the graph still runs (Color is
    /// whole-frame), and the face-dependent groups say why they cannot.
    static func enableFaceAnalysis(disabled: Set<String> = disabledGroups()) -> Bool {
        guard !disabled.contains("face") else { return false }
        RPVisionFeatureFlags.blazeFaceShortRange = true
        RPVisionFeatureFlags.faceLandmarks478 = true
        RPVisionFeatureFlags.faceParsing19 = true
        RPVisionFeatureFlags.faceAnalyzer = true
        return true
    }

    // MARK: - Model discovery

    /// The one model file name per network that the app ships and loads
    /// (docs/ADR-0015).
    ///
    /// Each conversion script writes three or four builds; only the **unsuffixed**
    /// one is a product artefact, and the difference is not cosmetic:
    ///
    /// | file | input | what it is for |
    /// |---|---|---|
    /// | `BlazeFaceShortRange` | 128 px RGB **image**, fp16 | ships (ADR-0008) |
    /// | `BlazeFaceShortRange_fp16` / `_fp32` | `MLMultiArray` | TFLite numeric control |
    /// | `FaceLandmark478` | 256 px RGB **image**, fp16 | ships (ADR-0005) |
    /// | `FaceLandmark478_fp16` / `_fp32` | `MLMultiArray` | TFLite numeric control |
    /// | `FaceParsing19` | 512 px RGB **image**, fp16, `labels` out | ships (ADR-0006) |
    /// | `FaceParsing19_logits_fp16` / `_fp32` | `MLMultiArray`, `logits` out | PyTorch control |
    ///
    /// `BlazeFaceModel.predict(image:)` and `FaceLandmark478Model.predict(crop:)`
    /// hand Core ML a `CVPixelBuffer` for a feature called `image`, so a
    /// MultiArray build cannot be used at all — it fails at the first prediction,
    /// after the analyzer has already been constructed. Before ADR-0015 this list
    /// named the `_fp16` builds *first*, which is exactly what the dev machine
    /// picked up.
    enum ModelName {
        static let blazeFace = "BlazeFaceShortRange"
        static let landmark = "FaceLandmark478"
        static let parsing = "FaceParsing19"

        /// `.mlmodelc` first: that is what Xcode's Core ML rule leaves in the app
        /// bundle. `.mlpackage` second, for `RP_MODELS_DIR` and the source tree,
        /// where `CompiledModelCache` compiles it on first use.
        static let extensions = ["mlmodelc", "mlpackage"]
    }

    /// The outcome of looking for the models, including the misses — so a build
    /// where the bundle copy is broken says so instead of quietly succeeding from
    /// the source tree.
    struct ModelDiscovery {
        var models: FaceAnalyzer.Models?
        /// Human-readable label of the directory the models came from.
        var source: String?
        /// One line per directory searched, in order, with what was found there.
        var searched: [String] = []

        /// The line that goes into `session.log`. Loud on failure: this is the
        /// only trace a user has when every face-dependent slider does nothing.
        var summary: String {
            if let models, let source {
                let parsing = models.parsing?.lastPathComponent ?? "MISSING (skin/eyes masks off)"
                return "face models: \(source) — \(models.blazeFace.lastPathComponent), "
                    + "\(models.landmark.lastPathComponent), \(parsing)"
            }
            return "face models: NOT FOUND — face detection, reshape and skin/eye "
                + "masks are all disabled. Searched: " + searched.joined(separator: "; ")
        }
    }

    /// One place the models might be: a label for the log and the directories to
    /// look in. Plural because the source tree keeps the detectors under
    /// `S1-landmark/` and the parsing model under `S2-face-parsing/`; a bundle
    /// keeps all three side by side.
    struct ModelSource {
        var label: String
        var directories: [URL]
    }

    /// Where the app looks for the three Core ML models, in order.
    ///
    /// 1. `RP_MODELS_DIR` — an explicit override, so a bench or a bisect can point
    ///    the app at a different conversion without a rebuild. Nothing in the
    ///    repository sets it today.
    /// 2. **The app bundle** (`Bundle.main.resourceURL`, plus a `Models/`
    ///    subdirectory in case a later build phase groups them). This is the path
    ///    every real build uses, on every platform, and the only one a sandboxed
    ///    iOS device can reach: the three `.mlpackage`s are build inputs of the app
    ///    target and Xcode's Core ML rule compiles them to `<name>.mlmodelc` in
    ///    exactly this directory (docs/ADR-0015).
    /// 3. `Research/spikes/*/models/` next to the source tree, found from
    ///    `#filePath`. **Last resort, for `xcodebuild test` and quick iteration
    ///    only** — the app-target test bundle has no `TEST_HOST`, so its
    ///    `Bundle.main` is the test runner and never contains the models. It is
    ///    deliberately *after* the bundle so it can never mask a broken embed, and
    ///    it is absent on any machine that is not this repository's.
    static func modelSources() -> [ModelSource] {
        var sources: [ModelSource] = []
        if let override = ProcessInfo.processInfo.environment["RP_MODELS_DIR"] {
            sources.append(
                ModelSource(label: "RP_MODELS_DIR", directories: [URL(fileURLWithPath: override)]))
        }
        if let resources = Bundle.main.resourceURL {
            sources.append(
                ModelSource(
                    label: "app bundle",
                    directories: [resources, resources.appendingPathComponent("Models")]))
        }
        if let repo = repositoryRoot {
            sources.append(
                ModelSource(
                    label: "source tree (dev fallback)",
                    directories: [
                        repo.appendingPathComponent("Research/spikes/S1-landmark/models"),
                        repo.appendingPathComponent("Research/spikes/S2-face-parsing/models"),
                    ]))
        }
        return sources
    }

    /// Finds a **complete** set in one source, or reports why it could not.
    ///
    /// All-or-nothing per source on purpose: two detectors from the bundle plus a
    /// parsing model from the source tree is the failure mode this whole change
    /// exists to remove — it works on the developer's Mac and not on a device.
    static func discoverModels(fileManager: FileManager = .default) -> ModelDiscovery {
        var result = ModelDiscovery()

        func find(_ stem: String, in source: ModelSource) -> URL? {
            source.directories
                .flatMap { dir in
                    ModelName.extensions.map { dir.appendingPathComponent("\(stem).\($0)") }
                }
                .first { fileManager.fileExists(atPath: $0.path) }
        }

        for source in modelSources() {
            let where_ = source.directories.map(\.path).joined(separator: " | ")
            let blazeFace = find(ModelName.blazeFace, in: source)
            let landmark = find(ModelName.landmark, in: source)
            // The parsing model may legitimately be absent — `FaceAnalyzer.Models`
            // takes it as optional and the landmark path still works without it —
            // but the two detectors are what "face analysis" means.
            let parsing = find(ModelName.parsing, in: source)
            guard let blazeFace, let landmark else {
                var missing: [String] = []
                if blazeFace == nil { missing.append(ModelName.blazeFace) }
                if landmark == nil { missing.append(ModelName.landmark) }
                result.searched.append(
                    "\(source.label) [\(where_)] missing \(missing.joined(separator: "+"))")
                continue
            }
            result.searched.append("\(source.label) [\(where_)] complete")
            result.models = FaceAnalyzer.Models(
                blazeFace: blazeFace, landmark: landmark, parsing: parsing)
            result.source = source.label
            return result
        }
        return result
    }

    /// Where the three models are, or `nil` when this build has none.
    static func models(fileManager: FileManager = .default) -> FaceAnalyzer.Models? {
        discoverModels(fileManager: fileManager).models
    }

    /// The repository this build came from, when it is still on disk — derived
    /// from `#filePath`, so it is correct in a Debug build run from Xcode and
    /// simply absent anywhere else.
    static var repositoryRoot: URL? {
        let file = URL(fileURLWithPath: #filePath)  // <repo>/App/AppEngineSetup.swift
        let root = file.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/PLAN.md").path)
            ? root : nil
    }
}
