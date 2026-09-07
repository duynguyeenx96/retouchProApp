// swift-tools-version: 6.2
import PackageDescription

// Spike S2 harness. Lives under Research/ on purpose: it is a measurement tool,
// not product code, and it must not become a dependency of the app workspace.
let package = Package(
    name: "S2Harness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../../Packages/RPVision")
    ],
    targets: [
        .executableTarget(
            name: "s2harness",
            dependencies: [.product(name: "RPVision", package: "RPVision")]
        )
    ]
)
