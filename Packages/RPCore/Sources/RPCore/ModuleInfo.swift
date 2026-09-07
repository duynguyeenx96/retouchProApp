import Foundation

/// Compile-time identity of one Retouch Pro package.
///
/// This is skeleton scaffolding: it exists so every package has a linkable,
/// testable symbol before the real Phase 1–3 types land, and so a build can
/// report which module versions are actually linked into it.
public struct ModuleInfo: Sendable, Hashable, Codable {
    /// Package name, e.g. `"RPEngine"`.
    public let name: String
    /// Semantic version of the package, bumped by hand as phases land.
    public let version: String
    /// Names of the in-repo packages this package links against.
    /// Used by `ModuleGraph` to assert the dependency direction.
    public let dependsOn: [String]

    public init(name: String, version: String, dependsOn: [String] = []) {
        self.name = name
        self.version = version
        self.dependsOn = dependsOn
    }
}

/// Identity of the RPCore package itself.
public enum RPCoreModule {
    public static let info = ModuleInfo(name: "RPCore", version: "0.2.0")
}

/// The intended dependency direction of the repo, expressed as data so tests
/// can check it instead of relying on review.
///
/// Rules encoded here (see docs/PLAN.md §2):
/// - `RPCore` is a leaf; nothing in the repo is below it. It owns the domain
///   model *and* project ownership (`ProjectSession`), so a package needing a
///   serialised writer does not have to link an importer to get one.
/// - `RPVision`, `RPEngine`, `RPImport` sit above `RPCore` and do not depend on
///   each other.
/// - `RPUI` may depend on `RPEngine` and `RPCore`, never the reverse. It does
///   not depend on `RPImport`; the app target wires importers to the UI's
///   `ProjectMutating` conformance.
/// - `RPTestKit` is testing support: it may depend downward, but no shipping
///   package may depend on it.
public enum ModuleGraph {
    /// Packages that must not be linked by any shipping (non-test) package.
    public static let testingOnlyPackages: Set<String> = ["RPTestKit"]

    /// Frameworks that must not appear in `RPCore` / `RPEngine` sources.
    public static let uiFrameworks: Set<String> = ["UIKit", "AppKit", "SwiftUI"]

    /// Returns `true` when `graph` has no cycles and no shipping package links
    /// a testing-only package.
    public static func isWellFormed(_ graph: [ModuleInfo]) -> Bool {
        let byName = Dictionary(uniqueKeysWithValues: graph.map { ($0.name, $0) })

        for module in graph where !testingOnlyPackages.contains(module.name) {
            if module.dependsOn.contains(where: { testingOnlyPackages.contains($0) }) {
                return false
            }
        }

        // Depth-first cycle check over the declared edges.
        var state: [String: Int] = [:]  // 0 = visiting, 1 = done
        func visit(_ name: String) -> Bool {
            if let s = state[name] { return s == 1 }
            state[name] = 0
            for next in byName[name]?.dependsOn ?? [] where !visit(next) { return false }
            state[name] = 1
            return true
        }
        return graph.allSatisfy { visit($0.name) }
    }
}
