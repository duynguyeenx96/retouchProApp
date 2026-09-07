import SwiftUI

/// Entry point for the multiplatform app (macOS 15+, iPadOS/iOS 18+).
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
