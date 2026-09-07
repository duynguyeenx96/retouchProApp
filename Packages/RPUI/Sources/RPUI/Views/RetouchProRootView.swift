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
    public init(
        projects: ProjectsModel = ProjectsModel(),
        renderer: any PreviewRendering = PassthroughPreviewRenderer(),
        live: LivePreviewController? = nil,
        importer: (any ShotImporting)? = nil
    ) {
        _projects = State(initialValue: projects)
        self.renderer = renderer
        self.live = live
        self.importer = importer
        self.cache = PreviewImageCache(renderer: renderer)
    }

    private struct Route: Hashable {
        var bundleURL: URL
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
    }

    @ViewBuilder
    private func editorScreen(for route: Route) -> some View {
        Group {
            if let editor, editor.store.bundleURL == route.bundleURL.standardizedFileURL {
                // Clearing the route is enough: the `onChange` above drops the
                // model and closes the GPU canvas.
                EditorView(model: editor, cache: cache) { self.route = nil }
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
        .task(id: route.bundleURL) {
            openFailure = nil
            editor = nil
            // Leaving a project must give back the previous shot's textures —
            // a 2048 px source + output is ~50 MB and there is no reason to
            // hold it while the projects list is on screen.
            live?.close()
            do {
                editor = try await EditorModel.open(
                    bundleURL: route.bundleURL, renderer: renderer, live: live,
                    importer: importer)
            } catch {
                guard !Task.isCancelled else { return }
                openFailure = String(describing: error)
            }
        }
    }
}
