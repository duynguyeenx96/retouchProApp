// swift-tools-version: 6.2
import PackageDescription

// RPTestKit — testing support only: golden images, mask/landmark eval harness,
// bench. It may depend downward on RPCore, but no shipping package may depend
// on RPTestKit (enforced by SourceAudit / LayeringAuditTests).
let package = Package(
    name: "RPTestKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPTestKit", targets: ["RPTestKit"])
    ],
    dependencies: [
        .package(path: "../RPCore")
    ],
    targets: [
        .target(name: "RPTestKit", dependencies: [.product(name: "RPCore", package: "RPCore")]),
        .testTarget(name: "RPTestKitTests", dependencies: ["RPTestKit"]),
    ]
)
