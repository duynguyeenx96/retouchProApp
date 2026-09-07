import Foundation
import SwiftUI
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// Cheap smoke coverage: every screen can be constructed and its `body`
/// evaluated without a window.
///
/// Stated plainly so nobody over-reads it: this catches "the view tree does not
/// even build" — a missing environment object, a fatal precondition in an
/// initialiser, a bad `ForEach` id. It does **not** check layout or pixels, and
/// it is not a substitute for running the app. The real logic is tested in
/// `CanvasViewportTests`, `FilmstripSelectionTests` and `EditorModelTests`,
/// which is where behaviour lives (see docs/ADR-0004 §4).
@MainActor
@Suite("View construction")
struct ViewConstructionTests {
    @Test("The editor and its four panes build for a real project")
    func editorBuilds() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let cache = PreviewImageCache()

        _ = EditorView(model: model, cache: cache, close: {}).body
        _ = FilmstripView(model: model, cache: cache, axis: .vertical).body
        _ = FilmstripView(model: model, cache: cache, axis: .horizontal).body
        _ = SliderPanelView(model: model).body
        _ = PresetBarView(model: model).body
        _ = CanvasView(model: model, cache: cache).body
    }

    /// The same smoke pass with the **live GPU canvas** attached: the panel's
    /// 45 working sliders, the face selector and the `MTKView` wrapper all have
    /// to build. Skipped on a machine with no Metal device, which is a supported
    /// configuration — `EditorModel.live` is optional and the canvas falls back
    /// to the decoded original.
    @Test("The editor builds with the live preview attached")
    func editorBuildsWithLivePreview() async throws {
        guard let context = MetalContext.shared else { return }
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }

        let live = LivePreviewController(renderer: try LivePreviewRenderer(context: context))
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL, live: live)
        let cache = PreviewImageCache()
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 35)

        _ = EditorView(model: model, cache: cache, close: {}).body
        _ = SliderPanelView(model: model).body
        _ = CanvasView(model: model, cache: cache).body
        // Every comparison mode reaches a different branch of the canvas.
        for mode in BeforeAfterMode.allCases {
            model.beforeAfter.mode = mode
            _ = CanvasView(model: model, cache: cache).body
        }
        model.beforeAfter.isHoldingOriginal = true
        _ = CanvasView(model: model, cache: cache).body

        _ = LivePreviewMetalView(
            controller: live, version: live.version,
            imageFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("The editor builds for an empty project too")
    func emptyProjectBuilds() async throws {
        let temp = try TempProject(shots: 0)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.activeShot == nil)
        #expect(model.previewRequest(maxPixelSize: 512) == nil)
        _ = EditorView(model: model, cache: PreviewImageCache(), close: {}).body
    }

    @Test("The projects list builds")
    func projectsListBuilds() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-views-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ProjectsModel(library: ProjectLibrary(rootURL: root))
        await model.reload()
        #expect(model.entries.isEmpty)

        let url = await model.createProject(named: "Smoke")
        #expect(url != nil)
        await model.reload()
        #expect(model.entries.count == 1)

        // `ProjectsView.body` reads `@Environment(ProjectsModel.self)`, which
        // only resolves inside a hosted view tree, so this constructs it and
        // stops there. ``RetouchProRootView`` is what injects the environment.
        _ = ProjectsView(cache: PreviewImageCache(), open: { _ in })
    }

    @Test("The root view builds")
    func rootBuilds() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-views-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = RetouchProRootView(projects: ProjectsModel(library: ProjectLibrary(rootURL: root))).body
    }
}
