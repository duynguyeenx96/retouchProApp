import Testing

import RPCore
import RPEngine
@testable import RPUI

@Suite("RPUI module")
struct RPUIModuleTests {
    @Test("Depends downward only, and the graph stays acyclic")
    func dependencyDirection() {
        #expect(RPUIModule.info.name == "RPUI")
        // No RPImport: `ProjectSession` moved to RPCore in the Phase 1 review,
        // so the UI layer no longer links PhotoKit / ImageCaptureCore.
        #expect(Set(RPUIModule.info.dependsOn) == ["RPEngine", "RPCore"])
        #expect(
            ModuleGraph.isWellFormed([
                RPCoreModule.info, RPEngineModule.info, RPUIModule.info,
            ])
        )
    }

    @Test("Placeholder root view can still be constructed")
    @MainActor
    func placeholderViewBuilds() {
        let view = PlaceholderRootView(modules: ["RPCore 0.1.0"])
        _ = view.body
    }
}
