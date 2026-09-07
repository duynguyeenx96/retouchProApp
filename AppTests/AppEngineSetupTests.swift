import CoreGraphics
import Foundation
import RPEngine
import RPVision
import Testing

/// Phase 2 — the app's own wiring (docs/ADR-0013): which slider groups this
/// build turns on, and how the face provider keys its cache.
///
/// Like `FaceAnalysisRenderBridgeTests`, this bundle has **no `TEST_HOST`**: it
/// compiles `App/AppEngineSetup.swift` and
/// `App/FaceAnalyzerFaceInputProvider.swift` into itself, so it runs on macOS
/// and in the iOS Simulator without launching the app.
///
/// `.serialized` because `RPEngineFeatureFlags` / `RPVisionFeatureFlags` are
/// process-global stores (docs/ADR-0006), and every test here restores exactly
/// the flags it set rather than calling `resetToDefaults()`.
@Suite("App engine setup", .serialized)
struct AppEngineSetupTests {

    /// Saves and restores the four RPEngine group flags plus the two kernel
    /// flags, so this suite cannot switch another suite's feature off.
    private func withRestoredFlags(_ body: () throws -> Void) rethrows {
        let color = RPEngineFeatureFlags.colorSliders
        let skin = RPEngineFeatureFlags.skinSliders
        let warp = RPEngineFeatureFlags.warpSliders
        let eyes = RPEngineFeatureFlags.eyesTeethSliders
        let guided = RPEngineFeatureFlags.guidedFilter
        let mls = RPEngineFeatureFlags.mlsMeshWarp
        defer {
            RPEngineFeatureFlags.colorSliders = color
            RPEngineFeatureFlags.skinSliders = skin
            RPEngineFeatureFlags.warpSliders = warp
            RPEngineFeatureFlags.eyesTeethSliders = eyes
            RPEngineFeatureFlags.guidedFilter = guided
            RPEngineFeatureFlags.mlsMeshWarp = mls
        }
        try body()
    }

    @Test("The app turns on all four measured slider groups")
    func enablesEveryGroup() {
        withRestoredFlags {
            let enabled = AppEngineSetup.enableRenderGraph(disabled: [])
            #expect(enabled == ["color", "skin", "warp", "eyesTeeth"])
            #expect(RPEngineFeatureFlags.colorSliders)
            #expect(RPEngineFeatureFlags.skinSliders)
            #expect(RPEngineFeatureFlags.warpSliders)
            #expect(RPEngineFeatureFlags.eyesTeethSliders)
            // …including the kernel flags the groups are built on, which is what
            // the `enable…RenderGraph()` helpers exist for.
            #expect(RPEngineFeatureFlags.guidedFilter)
            #expect(RPEngineFeatureFlags.mlsMeshWarp)
        }
    }

    /// The escape hatch the ADR promises: a developer can switch a group off
    /// without a rebuild, and switching one off must not take another down —
    /// the bug docs/ADR-0010 was written about.
    @Test("A disabled group stays off and does not disturb the others")
    func disablingOneGroup() {
        withRestoredFlags {
            RPEngineFeatureFlags.colorSliders = false
            RPEngineFeatureFlags.skinSliders = false
            RPEngineFeatureFlags.warpSliders = false
            RPEngineFeatureFlags.eyesTeethSliders = false
            let enabled = AppEngineSetup.enableRenderGraph(disabled: ["warp", "skin"])
            #expect(enabled == ["color", "eyesTeeth"])
            #expect(RPEngineFeatureFlags.skinSliders == false)
            #expect(RPEngineFeatureFlags.warpSliders == false)
            #expect(RPEngineFeatureFlags.colorSliders)
            #expect(RPEngineFeatureFlags.eyesTeethSliders)
            // The eyes/teeth group needs the guided-filter kernel and got it,
            // even though the skin group — the other user of that flag — is off.
            #expect(RPEngineFeatureFlags.guidedFilter)
        }
    }

    @Test("Groups can be disabled from the environment or from user defaults")
    func disabledGroupsParsing() {
        let defaults = UserDefaults(suiteName: "rp-tests-\(UUID().uuidString)")!
        #expect(
            AppEngineSetup.disabledGroups(defaults: defaults, environment: [:]).isEmpty)
        #expect(
            AppEngineSetup.disabledGroups(
                defaults: defaults, environment: ["RP_DISABLE_GROUPS": "skin, warp"])
                == ["skin", "warp"])
        defaults.set("face", forKey: AppEngineSetup.disableKey)
        #expect(AppEngineSetup.disabledGroups(defaults: defaults, environment: [:]) == ["face"])
    }

    @Test("Face analysis has its own switch, separate from the render graph")
    func faceAnalysisIsSeparate() {
        let landmarks = RPVisionFeatureFlags.faceLandmarks478
        let parsing = RPVisionFeatureFlags.faceParsing19
        let blaze = RPVisionFeatureFlags.blazeFaceShortRange
        let analyzer = RPVisionFeatureFlags.faceAnalyzer
        defer {
            RPVisionFeatureFlags.faceLandmarks478 = landmarks
            RPVisionFeatureFlags.faceParsing19 = parsing
            RPVisionFeatureFlags.blazeFaceShortRange = blaze
            RPVisionFeatureFlags.faceAnalyzer = analyzer
        }
        #expect(AppEngineSetup.enableFaceAnalysis(disabled: ["face"]) == false)
        #expect(AppEngineSetup.enableFaceAnalysis(disabled: []))
        #expect(RPVisionFeatureFlags.faceAnalyzer)
        #expect(RPVisionFeatureFlags.blazeFaceShortRange)
        #expect(RPVisionFeatureFlags.faceLandmarks478)
        #expect(RPVisionFeatureFlags.faceParsing19)
    }

    /// The pixel size **has** to be in the key: the same file analysed at
    /// 2048 px and at 24 MP produces coordinates in different grids, and Phase 3's
    /// export will ask for the second one on a shot the preview already cached.
    @Test("The face cache key includes the pixel size, not only the content hash")
    func cacheKeyIncludesSize() {
        let preview = FaceAnalyzerFaceInputProvider.cacheKey(
            contentHash: "abc", size: CGSize(width: 2048, height: 1365))
        let full = FaceAnalyzerFaceInputProvider.cacheKey(
            contentHash: "abc", size: CGSize(width: 6000, height: 4000))
        #expect(preview == "abc@2048x1365")
        #expect(preview != full)
    }

    /// Not an assertion about *this* machine: the app bundle carries the models
    /// (docs/ADR-0015) but this bundle has no `TEST_HOST`, so here the source-tree
    /// fallback is what answers, and on a machine without the repository nothing
    /// does. What must hold is that a found set is complete — a `Models` with a
    /// missing landmark model would throw at the first analysis instead of
    /// falling back cleanly.
    @Test("Model discovery either finds a complete set or returns nothing")
    func modelDiscoveryIsAllOrNothing() {
        let discovery = AppEngineSetup.discoverModels()
        print("APPTEST \(discovery.summary)")
        guard let models = discovery.models else {
            #expect(discovery.source == nil)
            return
        }
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: models.blazeFace.path))
        #expect(manager.fileExists(atPath: models.landmark.path))
        if let parsing = models.parsing {
            #expect(manager.fileExists(atPath: parsing.path))
        }
    }

    /// The bug docs/ADR-0015 was written about, half of it: `models()` used to
    /// name `BlazeFaceShortRange_fp16` / `FaceLandmark478_fp16` *first*. Those are
    /// the `MLMultiArray`-input builds kept only as numeric controls against
    /// TFLite; `BlazeFaceModel.predict(image:)` feeds Core ML a `CVPixelBuffer`,
    /// so picking one produces an analyzer that constructs fine and throws on the
    /// first photo. Only the unsuffixed, image-input builds are shippable.
    @Test("Only the image-input model builds are ever chosen")
    func picksTheImageInputBuilds() {
        #expect(AppEngineSetup.ModelName.blazeFace == "BlazeFaceShortRange")
        #expect(AppEngineSetup.ModelName.landmark == "FaceLandmark478")
        #expect(AppEngineSetup.ModelName.parsing == "FaceParsing19")
        // .mlmodelc before .mlpackage: Xcode leaves the compiled form in the app
        // bundle, and preferring it skips CompiledModelCache's first-run compile.
        #expect(AppEngineSetup.ModelName.extensions == ["mlmodelc", "mlpackage"])

        guard let models = AppEngineSetup.models() else { return }
        for url in [models.blazeFace, models.landmark] + [models.parsing].compactMap({ $0 }) {
            let stem = url.deletingPathExtension().lastPathComponent
            #expect(!stem.contains("_fp16"), "\(url.lastPathComponent) is a MultiArray control build")
            #expect(!stem.contains("_fp32"), "\(url.lastPathComponent) is a MultiArray control build")
            #expect(!stem.contains("logits"), "\(url.lastPathComponent) is a logits control build")
        }
    }

    /// The other half: the app bundle must be searched **before** the source
    /// tree, or a device build that failed to embed the models would keep passing
    /// on the developer's Mac — which is exactly what happened.
    @Test("The app bundle outranks the source-tree fallback")
    func bundleOutranksSourceTree() {
        let labels = AppEngineSetup.modelSources().map(\.label)
        guard let bundle = labels.firstIndex(of: "app bundle") else {
            Issue.record("the app bundle is not searched at all: \(labels)")
            return
        }
        if let fallback = labels.firstIndex(of: "source tree (dev fallback)") {
            #expect(bundle < fallback)
        }
        // And the override, when set, outranks both.
        if let override = labels.firstIndex(of: "RP_MODELS_DIR") {
            #expect(override < bundle)
        }
    }

    /// A missing set has to produce a line someone can read, not a silent `nil`.
    @Test("A failed lookup reports every directory it tried")
    func failureIsLoud() {
        let empty = AppEngineSetup.ModelDiscovery(
            models: nil, source: nil,
            searched: ["app bundle [/tmp/x] missing BlazeFaceShortRange+FaceLandmark478"])
        #expect(empty.summary.contains("NOT FOUND"))
        #expect(empty.summary.contains("/tmp/x"))
    }
}
