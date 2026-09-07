import Foundation
import RPCore

/// Identity of the RPVision package. Real content (FaceAnalyzer, landmark and
/// parsing models, SkinCore port) lands in Phase 2.
public enum RPVisionModule {
    public static let info = ModuleInfo(name: "RPVision", version: "0.1.0", dependsOn: ["RPCore"])
}
