import Foundation
import RPCore
import RPEngine
import RPImport
import RPUI
import RPVision

/// Dependency-injection container.
///
/// Everything the app owns for its whole lifetime is created here and handed
/// down through the SwiftUI environment, so views never reach for singletons.
/// `FaceAnalyzer` (Phase 2) and `BatchQueue` (Phase 3) get registered here as
/// their phases land.
@MainActor
@Observable
final class AppContainer {
    /// Which in-repo modules are actually linked into this build.
    /// Also proves the package graph is wired end-to-end at link time.
    let modules: [ModuleInfo]

    /// The projects library model, created once so navigating out of a project
    /// does not rescan the library folder.
    let projects: ProjectsModel

    /// The decode seam (docs/ADR-0004 §2): the file under `originals/`, EXIF
    /// orientation applied, `EditState` ignored.
    ///
    /// It is **still** `PassthroughPreviewRenderer` after Phase 2's render graph
    /// landed, and that is the right answer rather than a leftover: this
    /// renderer feeds the filmstrip thumbnails and the canvas's *before* side,
    /// both of which want the untouched file. The edited pixels come from
    /// ``live``, which runs the graph on the GPU without a round trip through
    /// `CGImage` (docs/ADR-0013).
    let previewRenderer: any PreviewRendering

    /// The live GPU canvas: `RenderGraph` over a texture uploaded once per shot.
    ///
    /// `nil` when this machine has no Metal device or the graph will not build;
    /// the canvas then shows the decoded original and says so. One per process —
    /// it owns the open shot's textures and only one project is open at a time.
    let live: LivePreviewController?

    /// The import seam (docs/ADR-0014): RPUI raises the pickers, this runs
    /// RPImport's `FilesImporter` / `PhotosImporter`.
    let importer: any ShotImporting

    /// Photos handed over from outside the app — today the iOS Share Extension
    /// (docs/ADR-0017). Owned for the whole process lifetime on purpose: on a
    /// cold start the URL arrives before any view exists, and the request has to
    /// survive until `RetouchProRootView` is there to take it.
    let externalOpen: ExternalOpenCoordinator

    /// Parses `retouchpro://open?file=…` into that request.
    let shareHandoff: ShareHandoffRouter

    /// The face pipeline, or `nil` when it could not be built. Held so
    /// ``FaceSelfTest`` can drive the very same object the canvas drives
    /// (docs/ADR-0015); `live` already has its own reference.
    let faceProvider: (any FaceInputProviding)?

    /// The whole-frame subject mask pipeline
    /// (`VNGeneratePersonSegmentationRequest`), or `nil` when it is switched off
    /// or unsupported. Feeds docs/ADR-0021 §v2's whole-body skin mask; "Khoá nền"
    /// will share it when it is wired.
    let subjectProvider: (any SubjectMaskProviding)?

    /// Which slider groups this launch turned on, for the startup log.
    let enabledRenderGroups: [String]
    /// Which `RPEnableExperiments` entries this launch honoured. Empty on every
    /// normal launch.
    let enabledExperiments: [String]
    /// Why there is no ``subjectProvider``, when there is none.
    let subjectMaskReport: String?
    /// Whether face analysis is available (flags on **and** models loaded).
    let faceAnalysisAvailable: Bool
    /// Where the Core ML models came from, or every directory that was tried and
    /// what was missing there. Always written to `session.log` (docs/ADR-0015):
    /// the bug this replaced was invisible precisely because the failure produced
    /// no line at all.
    let faceModelReport: [String]

    init(previewRenderer: any PreviewRendering = PassthroughPreviewRenderer()) {
        self.modules = [
            RPCoreModule.info,
            RPVisionModule.info,
            RPEngineModule.info,
            RPImportModule.info,
            RPUIModule.info,
        ]
        self.previewRenderer = previewRenderer
        self.importer = RPImportShotImporter()
        self.externalOpen = ExternalOpenCoordinator(log: { AppLog.write($0) })
        self.shareHandoff = ShareHandoffRouter()

        // Flags first: `RenderGraph.standard` registers a node only if its flag
        // is on, and it is read once at construction.
        let disabled = AppEngineSetup.disabledGroups()
        self.enabledRenderGroups = AppEngineSetup.enableRenderGraph(disabled: disabled)
        // Off on every normal launch; `RPEnableExperiments` is the developer
        // escape hatch that lets the §6.2 whole-body skin path be exercised on a
        // real device without a rebuild (AppEngineSetup.enableKey).
        self.enabledExperiments = AppEngineSetup.enableExperiments()

        let faceProvider: (any FaceInputProviding)?
        var report: [String] = []
        if AppEngineSetup.enableFaceAnalysis(disabled: disabled) {
            let discovery = AppEngineSetup.discoverModels()
            report.append(discovery.summary)
            let outcome = FaceAnalyzerFaceInputProvider.standard(models: discovery.models)
            if let diagnostic = outcome.diagnostic { report.append(diagnostic) }
            faceProvider = outcome.provider
        } else {
            report.append("face models: not loaded — face analysis switched off by RPDisableGroups")
            faceProvider = nil
        }
        self.faceModelReport = report
        self.faceProvider = faceProvider
        self.faceAnalysisAvailable = faceProvider != nil

        // The probe costs one 64x48 Vision request and is only paid when the
        // feature is actually on, which on a normal launch it is not — and it is
        // the only honest way to tell "this machine cannot run the request"
        // (the iOS Simulator) from "no person in this photo".
        let segmentation = PersonSegmenterSubjectMaskProvider.standard(
            probe: RPVisionFeatureFlags.personSegmentation)
        self.subjectProvider = segmentation.provider
        self.subjectMaskReport = segmentation.diagnostic

        self.live = LivePreviewController.standard(
            faceProvider: faceProvider ?? NoFaceInputProvider(),
            subjectProvider: segmentation.provider ?? NoSubjectMaskProvider())

        self.projects = ProjectsModel()
    }

    /// `true` when the linked module graph respects the layering rules.
    var moduleGraphIsWellFormed: Bool {
        ModuleGraph.isWellFormed(modules)
    }

    /// One line for the startup log saying what the render path actually is, so
    /// "the sliders do nothing" can be diagnosed from
    /// `~/Library/Containers/<bundle>/Data/Library/Logs/RetouchPro/session.log`
    /// rather than from a screenshot (docs/PLAN.md §5).
    var renderSummary: String {
        let groups = enabledRenderGroups.isEmpty ? "none" : enabledRenderGroups.joined(separator: ", ")
        let gpu = live == nil ? "no Metal device" : "ready"
        let faces = faceAnalysisAvailable ? "available" : "UNAVAILABLE"
        var line = "render groups: \(groups) | live preview: \(gpu) | face analysis: \(faces)"
        // Only when something is on, so the normal launch line is unchanged and
        // an experimental launch is impossible to miss in session.log.
        if !enabledExperiments.isEmpty {
            line += " | experiments: \(enabledExperiments.joined(separator: ", "))"
        }
        return line
    }

    /// The startup lines, in the order they should be written. `renderSummary`
    /// says *whether* face analysis works; ``faceModelReport`` says *why*;
    /// ``presetLibraryReport`` says whether Phase 3's preset stores resolved;
    /// the last line says whether the Share Extension can reach this app at all.
    var startupLog: [String] {
        [renderSummary] + faceModelReport + (subjectMaskReport.map { [$0] } ?? [])
            + [presetLibraryReport, shareHandoff.containerReport]
    }

    /// One line for the preset library (docs/PLAN.md §Phase 3): how many
    /// built-in presets the app bundle actually yielded, and where the user's
    /// cross-project "Của tôi" store landed.
    ///
    /// It is logged unconditionally for the reason `.claude/agents/coder.md`
    /// step 6 exists: `BuiltInPresets` reads JSON out of `Bundle.module`, and a
    /// resource that resolves on macOS and in the Simulator can come back empty
    /// inside a real device's sandbox. An empty "Nổi bật" tab looks identical to
    /// a curated list that happens to be short, so the count goes in the log
    /// where it can be read without a screenshot.
    var presetLibraryReport: String {
        let templates = BuiltInPresets.templates.count
        let looks = BuiltInPresets.looks.count
        let bundled =
            BuiltInPresets.isEmpty
            ? "MISSING (bundle \(BuiltInPresets.resourceRootURL?.path ?? "unavailable"))"
            : "\(templates) mẫu + \(looks) looks"
        let mine =
            (try? PresetLibraryStore.default())
            .map { "\($0.rootURL.path)" } ?? "UNAVAILABLE"
        return "presets: built-in \(bundled) | của tôi: \(mine)"
    }

    /// Entry point for `retouchpro://` (docs/ADR-0017). Called from the scene's
    /// `onOpenURL`, which SwiftUI delivers both on a cold start and while the
    /// app is already running.
    func open(url: URL) {
        shareHandoff.handle(url, with: externalOpen)
    }

    /// Picks up a share the extension staged but could not deliver
    /// (docs/ADR-0017). Called once per launch, after the scene is up; the
    /// coordinator refuses a file it has already accepted, so this and
    /// `open(url:)` cannot both open the same photo.
    func openPendingShares() async {
        // The wait is the whole reason this is `async`. On a cold start opened
        // *by* the extension, `onOpenURL` and this both run within a few
        // hundred ms of the first screen; the URL is the share the user just
        // made and has to win. Losing the race would open some older leftover
        // instead — seen happening before this delay was added.
        try? await Task.sleep(for: .seconds(1.5))
        shareHandoff.handleInbox(with: externalOpen)
    }

    /// One line per module, for the placeholder view and the startup log.
    var moduleSummary: [String] {
        modules.map { info in
            let deps = info.dependsOn.isEmpty ? "—" : info.dependsOn.joined(separator: ", ")
            return "\(info.name) \(info.version)  →  \(deps)"
        }
    }
}
