import RPUI
import SwiftUI

/// Scene content: `RPUI.RetouchProRootView` — Projects → Editor.
///
/// The view layer lives in `RPUI` (docs/PLAN.md §2); `App/` only builds it and
/// hands it what the container owns. `ProjectsModel` is created once in
/// `AppContainer` so navigating in and out of a project does not rescan the
/// library folder from scratch.
struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        RetouchProRootView(
            projects: container.projects,
            renderer: container.previewRenderer,
            live: container.live,
            importer: container.importer
        )
        .task {
            container.startupLog.forEach(AppLog.write)
            // Off unless RP_FACE_SELFTEST is set; see FaceSelfTest for why a
            // real device cannot be checked any other way.
            if let target = FaceSelfTest.target() {
                await FaceSelfTest.run(
                    target: target,
                    renderer: container.previewRenderer,
                    faceProvider: container.faceProvider)
            }
        }
    }
}
