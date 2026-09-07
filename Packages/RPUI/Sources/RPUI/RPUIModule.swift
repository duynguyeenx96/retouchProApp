import Foundation
import RPCore
import RPEngine

/// Identity of the RPUI package.
///
/// The Evoto-style shell (preset bar top, filmstrip left, canvas centre, slider
/// panel right) landed in Phase 1 item 4; the sliders themselves are Phase 2 and
/// preset application is Phase 3.
///
/// RPUI links RPEngine and RPCore only. The RPImport edge that ADR-0004 §1
/// described was removed in the Phase 1 review when `ProjectSession` moved to
/// RPCore; the app target owns the importers.
public enum RPUIModule {
    public static let info = ModuleInfo(
        name: "RPUI",
        version: "0.2.0",
        dependsOn: [
            RPEngineModule.info.name,
            RPCoreModule.info.name,
        ]
    )
}
