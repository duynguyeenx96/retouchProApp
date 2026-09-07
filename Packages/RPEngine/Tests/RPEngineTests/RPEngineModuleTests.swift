import Testing

import RPCore
@testable import RPEngine

@Suite("RPEngine skeleton")
struct RPEngineModuleTests {
    @Test("Declares a dependency on RPCore and nothing else")
    func dependencyDirection() {
        #expect(RPEngineModule.info.name == "RPEngine")
        #expect(RPEngineModule.info.dependsOn == ["RPCore"])
        #expect(ModuleGraph.isWellFormed([RPCoreModule.info, RPEngineModule.info]))
    }
}
