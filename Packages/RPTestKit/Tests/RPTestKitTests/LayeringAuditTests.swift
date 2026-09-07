import Foundation
import Testing

import RPCore
@testable import RPTestKit

@Suite("Package layering audit")
struct LayeringAuditTests {
    /// Every shipping package in the repo. RPTestKit is deliberately absent:
    /// nothing may depend on it, and it is allowed to import test frameworks.
    static let shippingPackages = ["RPCore", "RPVision", "RPEngine", "RPImport", "RPUI"]

    @Test("RPTestKit reports its own identity")
    func moduleIdentity() {
        #expect(RPTestKitModule.info.name == "RPTestKit")
        #expect(RPTestKitModule.info.dependsOn == ["RPCore"])
    }

    @Test("RPCore, RPEngine, RPVision and RPImport contain no UIKit / AppKit / SwiftUI imports")
    func noUIFrameworksInLowerLayers() throws {
        let root = try #require(
            SourceAudit.packagesRoot(),
            "Could not locate Packages/ from \(#filePath) — audit skipped, fix the path logic."
        )
        // RPUI is the only package allowed to see a UI framework. RPImport was
        // added when Phase 1 item 3 landed: PhotoKit and ImageCaptureCore both
        // have UIKit-flavoured entry points (`PHPickerViewController`,
        // `ICDeviceBrowserView`) that would drag a view layer into a package
        // that must stay headless and testable (docs/ADR-0003 §5).
        var violations: [SourceAudit.Violation] = []
        for package in ["RPCore", "RPEngine", "RPVision", "RPImport"] {
            violations += SourceAudit.auditSources(
                package: package,
                packagesRoot: root,
                forbidden: ModuleGraph.uiFrameworks,
                reason: "\(package) must stay platform-independent (docs/PLAN.md §2)"
            )
        }
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    @Test("No shipping package imports RPTestKit")
    func noReverseDependencyIntoTestKit() throws {
        let root = try #require(SourceAudit.packagesRoot())
        var violations: [SourceAudit.Violation] = []
        for package in Self.shippingPackages {
            violations += SourceAudit.auditSources(
                package: package,
                packagesRoot: root,
                forbidden: ModuleGraph.testingOnlyPackages,
                reason: "RPTestKit is testing support only"
            )
        }
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    @Test("Nothing below RPUI imports RPUI, and nothing imports RPVision/RPImport upward")
    func noUpwardImports() throws {
        let root = try #require(SourceAudit.packagesRoot())
        // Each entry: package -> modules it is not allowed to import.
        let rules: [String: Set<String>] = [
            "RPCore": ["RPVision", "RPEngine", "RPImport", "RPUI"],
            "RPEngine": ["RPUI", "RPImport"],
            "RPVision": ["RPUI", "RPEngine", "RPImport"],
            "RPImport": ["RPUI", "RPEngine", "RPVision"],
            // RPUI's RPImport edge was removed in the Phase 1 review: it only
            // ever carried `ProjectMutating` / `ProjectSession`, which now live
            // in RPCore. Asserted here so it cannot creep back in — the UI must
            // not pull PhotoKit / ImageCaptureCore in to serialise a write.
            "RPUI": ["RPImport"],
        ]
        var violations: [SourceAudit.Violation] = []
        for (package, forbidden) in rules.sorted(by: { $0.key < $1.key }) {
            violations += SourceAudit.auditSources(
                package: package,
                packagesRoot: root,
                forbidden: forbidden,
                reason: "dependency direction is downward only (docs/PLAN.md §2)"
            )
        }
        #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "\n"))")
    }

    @Test("Import scanner ignores commented-out imports")
    func importScannerIgnoresComments() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rp-audit-\(UUID().uuidString).swift")
        let source = """
            import Foundation
            // import UIKit
            @testable import RPCore
            import Foundation.NSURL
            """
        try source.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let found = try SourceAudit.imports(inSwiftFileAt: tmp)
        #expect(found.map(\.module) == ["Foundation", "RPCore", "Foundation"])
        #expect(found.map(\.line) == [1, 3, 4])
    }
}
