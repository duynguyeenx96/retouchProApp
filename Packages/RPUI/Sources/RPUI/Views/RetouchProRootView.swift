import RPCore
import RPEngine
import SwiftUI

/// The app's scene content: Projects → Editor.
///
/// A `NavigationStack` here (unlike inside ``EditorView``) because this *is* a
/// hierarchy: you are in the projects list or in one project, never both.
/// One `PreviewImageCache` is owned at this level so moving between projects
/// does not throw away decoded thumbnails.
public struct RetouchProRootView: View {
    @State private var projects: ProjectsModel
    @State private var route: Route?
    @State private var editor: EditorModel?
    @State private var openFailure: String?
    private let cache: PreviewImageCache
    private let renderer: any PreviewRendering
    private let live: LivePreviewController?
    private let importer: (any ShotImporting)?
    private let opener: ExternalOpenCoordinator?

    /// - Parameters:
    ///   - renderer: decodes the file under `originals/` for the filmstrip and
    ///     for the canvas's "before" side. It ignores `EditState` on purpose —
    ///     see ``EditorModel/renderer``.
    ///   - live: the GPU canvas (Phase 2). One per process, because it owns the
    ///     open shot's textures and only one project is open at a time. `nil`
    ///     falls back to showing the decoded original, which is what happens on
    ///     a machine with no Metal device.
    ///   - importer: the Files / Photos import seam (docs/ADR-0014). `nil` hides
    ///     the import controls; the app target passes `RPImportShotImporter`.
    ///   - opener: photos handed over from outside the app — the iOS Share
    ///     Extension (docs/ADR-0017). `nil` on a build with no such entry point.
    public init(
        projects: ProjectsModel = ProjectsModel(),
        renderer: any PreviewRendering = PassthroughPreviewRenderer(),
        live: LivePreviewController? = nil,
        importer: (any ShotImporting)? = nil,
        opener: ExternalOpenCoordinator? = nil
    ) {
        _projects = State(initialValue: projects)
        self.renderer = renderer
        self.live = live
        self.importer = importer
        self.opener = opener
        self.cache = PreviewImageCache(renderer: renderer)
    }

    private struct Route: Hashable {
        var bundleURL: URL
        /// Files to ingest as soon as the editor has opened the bundle. Empty
        /// for every ordinary navigation; non-empty only on the Share Extension
        /// path, which is the one case where opening a project and importing
        /// into it are a single user action (docs/ADR-0017).
        var pendingImport: [URL] = []
        /// Whether those files are a hand-off buffer to delete afterwards.
        var removesSourcesAfterImport: Bool = false
    }

    public var body: some View {
        NavigationStack {
            ProjectsView(cache: cache) { url in
                route = Route(bundleURL: url)
            }
            .environment(projects)
            .navigationDestination(item: $route) { route in
                editorScreen(for: route)
            }
        }
        // The approved design is a fixed dark surface (`#0c0d0f` ground, one
        // mint accent) — see ``RPTheme``. Pinned here, once, rather than by each
        // screen: a photo editor whose surround follows the system appearance
        // would show the same picture against two different greys.
        .preferredColorScheme(.dark)
        .tint(RPTheme.accent)
        .background(RPTheme.canvas)
        // Leaving a project releases its textures **whoever popped the stack**.
        // `EditorView`'s own "Projects" button is one way; a platform-supplied
        // back control is another (iOS's is hidden — see
        // `EditorView.navigationBarBackButtonHidden` — but macOS's chrome is the
        // system's to draw). Hanging the cleanup off the route rather than off
        // one button means no path out of the editor can skip it.
        .onChange(of: route) { _, newRoute in
            guard newRoute == nil else { return }
            editor = nil
            live?.close()
        }
        // The Share Extension hand-off. `initial: true` is what covers the two
        // cases the feature has to get right, without either one knowing which
        // happened: on a **cold start** the request is already pending the first
        // time this view is evaluated (the URL reaches `AppContainer` before any
        // view exists, which is why the coordinator holds it), and on a **warm
        // start** `onOpenURL` sets it while the view is already on screen and
        // the value changes.
        //
        // Deliberately *not* `.task(id: opener?.pending?.id)`: taking the
        // request clears `pending`, which changes that id, which makes SwiftUI
        // cancel the very task doing the work — halfway through creating the
        // project. An unstructured `Task` is owned by the hand-off, not by a
        // view update. `take()` still guarantees once-only.
        .onChange(of: opener?.pending?.id, initial: true) { _, _ in
            guard let opener, let request = opener.take() else { return }
            Task { await openSharedPhotos(request) }
        }
    }

    /// Copies a hand-off's files into the freshly created project and selects
    /// the first of them.
    ///
    /// Deliberately the **same** path as every other import: `EditorModel
    /// .importFiles` → RPUI's `ShotImporting` seam → RPImport's `FilesImporter`
    /// → `ShotIngestor` (docs/ADR-0003 / ADR-0014). De-duplication, the
    /// extension allow-list and RAW preservation are therefore identical to a
    /// Files import, and no second ingest path exists to keep in sync.
    private func ingest(_ route: Route, into model: EditorModel) async {
        guard !route.pendingImport.isEmpty else { return }
        let summary = await model.importFiles(at: route.pendingImport)
        if let first = summary.importedShotIDs.first {
            await model.select(shotID: first)
        }
        opener?.report(summary.message)
        if route.removesSourcesAfterImport {
            ShareHandoff.discard(route.pendingImport)
        }
    }

    /// Creates a project for a handed-over photo and routes straight into the
    /// editor for it — no project picker, no stop at the library
    /// (docs/HANDOFF-remaining-features-2026-09-10.md §4.1).
    private func openSharedPhotos(_ request: ExternalOpenRequest) async {
        // Whatever was open has to go first: `createProject` may take a moment
        // on a slow volume, and leaving the previous project's textures alive
        // behind a new one is how the canvas ends up showing the wrong picture.
        // This is the warm-start case — on a cold start there is nothing open.
        route = nil
        guard let bundleURL = await projects.createProject(named: request.projectName) else {
            opener?.report(
                projects.lastErrorMessage
                    ?? "Không tạo được dự án cho ảnh vừa chia sẻ.")
            return
        }
        route = Route(
            bundleURL: bundleURL,
            pendingImport: request.fileURLs,
            removesSourcesAfterImport: request.removesSourcesAfterImport)
    }

    @ViewBuilder
    private func editorScreen(for route: Route) -> some View {
        Group {
            if let editor, editor.store.bundleURL == route.bundleURL.standardizedFileURL {
                // Clearing the route is enough: the `onChange` above drops the
                // model and closes the GPU canvas.
                // A hand-off route opens straight on the canvas; every other
                // route keeps the project's library as its first screen.
                EditorView(
                    model: editor, cache: cache,
                    opensInEditor: !route.pendingImport.isEmpty
                ) { self.route = nil }
            } else if let openFailure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Không mở được dự án này")
                        .font(RPTheme.text(15, weight: .semibold))
                        .foregroundStyle(RPTheme.textPrimary)
                    Text(openFailure)
                        .font(RPTheme.text(11.5))
                        .foregroundStyle(RPTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    RPSecondaryButton(title: "Về danh sách dự án") { self.route = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RPTheme.canvas)
            } else {
                ProgressView("Đang mở…")
                    .tint(RPTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RPTheme.canvas)
            }
        }
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: route) {
            openFailure = nil
            editor = nil
            // Leaving a project must give back the previous shot's textures —
            // a 2048 px source + output is ~50 MB and there is no reason to
            // hold it while the projects list is on screen.
            live?.close()
            do {
                let model = try await EditorModel.open(
                    bundleURL: route.bundleURL, renderer: renderer, live: live,
                    importer: importer)
                editor = model
                await ingest(route, into: model)
            } catch {
                guard !Task.isCancelled else { return }
                openFailure = String(describing: error)
            }
        }
    }
}
