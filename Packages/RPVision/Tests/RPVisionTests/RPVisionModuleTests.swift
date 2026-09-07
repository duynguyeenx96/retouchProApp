import Testing

import RPCore
@testable import RPVision

@Suite("RPVision skeleton")
struct RPVisionModuleTests {
    @Test("Declares a dependency on RPCore and nothing else")
    func dependencyDirection() {
        #expect(RPVisionModule.info.name == "RPVision")
        #expect(RPVisionModule.info.dependsOn == ["RPCore"])
        #expect(ModuleGraph.isWellFormed([RPCoreModule.info, RPVisionModule.info]))
    }
}
