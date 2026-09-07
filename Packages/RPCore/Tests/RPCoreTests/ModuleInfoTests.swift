import Foundation
import Testing

@testable import RPCore

@Suite("RPCore skeleton")
struct ModuleInfoTests {
    @Test("Module identity is populated")
    func moduleIdentity() {
        #expect(RPCoreModule.info.name == "RPCore")
        #expect(RPCoreModule.info.dependsOn.isEmpty)
    }

    @Test("ModuleInfo round-trips through JSON")
    func codableRoundTrip() throws {
        let original = ModuleInfo(name: "RPEngine", version: "0.1.0", dependsOn: ["RPCore"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModuleInfo.self, from: data)
        #expect(decoded == original)
    }

    @Test("A legal graph is accepted")
    func legalGraph() {
        let graph = [
            ModuleInfo(name: "RPCore", version: "0.1.0"),
            ModuleInfo(name: "RPEngine", version: "0.1.0", dependsOn: ["RPCore"]),
            ModuleInfo(name: "RPUI", version: "0.1.0", dependsOn: ["RPEngine", "RPCore"]),
            ModuleInfo(name: "RPTestKit", version: "0.1.0", dependsOn: ["RPCore"]),
        ]
        #expect(ModuleGraph.isWellFormed(graph))
    }

    @Test("A shipping package depending on RPTestKit is rejected")
    func testKitLeakIsRejected() {
        let graph = [
            ModuleInfo(name: "RPCore", version: "0.1.0"),
            ModuleInfo(name: "RPEngine", version: "0.1.0", dependsOn: ["RPCore", "RPTestKit"]),
            ModuleInfo(name: "RPTestKit", version: "0.1.0", dependsOn: ["RPCore"]),
        ]
        #expect(!ModuleGraph.isWellFormed(graph))
    }

    @Test("A cycle is rejected")
    func cycleIsRejected() {
        let graph = [
            ModuleInfo(name: "RPCore", version: "0.1.0", dependsOn: ["RPUI"]),
            ModuleInfo(name: "RPUI", version: "0.1.0", dependsOn: ["RPCore"]),
        ]
        #expect(!ModuleGraph.isWellFormed(graph))
    }
}
