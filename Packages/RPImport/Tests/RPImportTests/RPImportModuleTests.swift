import Testing

import RPCore
@testable import RPImport

@Suite("RPImport skeleton")
struct RPImportModuleTests {
    @Test("Declares a dependency on RPCore and nothing else")
    func dependencyDirection() {
        #expect(RPImportModule.info.name == "RPImport")
        #expect(RPImportModule.info.dependsOn == ["RPCore"])
        #expect(ModuleGraph.isWellFormed([RPCoreModule.info, RPImportModule.info]))
    }
}
