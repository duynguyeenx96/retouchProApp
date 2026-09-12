import SwiftUI

/// Entry point for the multiplatform app (macOS 15+, iOS 18+ — iPhone only,
/// iPadOS deployment removed 2026-09-11, see docs/PLAN.md §0.2).
///
/// The scene shows `RPUI.RetouchProRootView`: the projects list, then the
/// project the user opens — library (docs/design 2a / 2c) and editor (1a / 1b).
@main
struct RetouchProApp: App {
    @State private var container = AppContainer()

    init() {
        AppLog.startSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                // "Mở với RetouchPro": the Share Extension opens
                // `retouchpro://open?file=…` (docs/ADR-0017). SwiftUI delivers
                // it here in both cases the feature has to handle — a cold
                // start, where the URL arrives just after this scene connects,
                // and a warm start, where the app was already in the background.
                .onOpenURL { url in container.open(url: url) }
                #if os(macOS)
                    // Below `RPUI.EditorLayout.threePaneMinimumWidth` (900) the
                    // editor drops to its compact arrangement, which is correct
                    // but is not what a Mac window should default to.
                    .frame(minWidth: 720, minHeight: 480)
                #endif
        }
        #if os(macOS)
            .defaultSize(width: 1440, height: 900)
            // The approved macOS design (docs/design/RetouchPro.dc.html#1b) is a
            // 46 pt app row carrying the tool group, the "Thư viện"/"Chỉnh sửa"
            // switcher, a caption and "Xuất" — a shape `NSToolbar` cannot
            // produce, so `RPUI.EditorToolbar` draws it in the content and the
            // system title bar is made transparent rather than removed: the
            // window still needs its traffic lights, and hiding the window
            // toolbar takes them with it (see `RPUI.EditorView`'s note). The
            // result is the lights on a transparent strip directly above the
            // design's row.
            .windowStyle(.hiddenTitleBar)
        #endif
    }
}
