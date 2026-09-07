import Foundation
import RPCore

/// Identity of the RPEngine package. The real render graph
/// (Decode → Color → Skin → Warp(MLS) → Eyes/Teeth → Makeup → Output)
/// lands in Phase 2.
public enum RPEngineModule {
    public static let info = ModuleInfo(name: "RPEngine", version: "0.1.0", dependsOn: ["RPCore"])
}
