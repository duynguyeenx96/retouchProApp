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

    /// The face pipeline, or `nil` when it could not be built. Held so
    /// ``FaceSelfTest`` can drive the very same object the canvas drives
    /// (docs/ADR-0015); `live` already has its own reference.
    let faceProvider: (any FaceInputProviding)?

    /// Which slider groups this launch turned on, for the startup log.
    let enabledRenderGroups: [String]
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

        // Flags first: `RenderGraph.standard` registers a node only if its flag
        // is on, and it is read once at construction.
        let disabled = AppEngineSetup.disabledGroups()
        self.enabledRenderGroups = AppEngineSetup.enableRenderGraph(disabled: disabled)

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
        self.live = LivePreviewController.standard(
            faceProvider: faceProvider ?? NoFaceInputProvider())

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
        return "render groups: \(groups) | live preview: \(gpu) | face analysis: \(faces)"
    }

    /// The startup lines, in the order they should be written. `renderSummary`
    /// says *whether* face analysis works; ``faceModelReport`` says *why*.
    var startupLog: [String] {
        [renderSummary] + faceModelReport
    }

    /// One line per module, for the placeholder view and the startup log.
    var moduleSummary: [String] {
        modules.map { info in
            let deps = info.dependsOn.isEmpty ? "—" : info.dependsOn.joined(separator: ", ")
            return "\(info.name) \(info.version)  →  \(deps)"
        }
    }
}
