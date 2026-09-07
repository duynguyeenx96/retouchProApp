import Foundation
import RPCore

/// Identity of the RPTestKit package. Golden-image comparison, mask/landmark
/// eval harness and the bench runner land alongside Phase 2.
public enum RPTestKitModule {
    public static let info = ModuleInfo(name: "RPTestKit", version: "0.1.0", dependsOn: ["RPCore"])
}
