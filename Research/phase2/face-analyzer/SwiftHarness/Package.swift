// swift-tools-version: 6.2
import PackageDescription

// Phase 2 measurement harness for RPVision's FaceAnalyzer. Lives under Research/
// for the same reason the spike harnesses do: it is a measurement tool, not
// product code, and it must not become a dependency of the app workspace.
let package = Package(
    name: "P2FaceAnalyzerHarness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../../Packages/RPVision")
    ],
    targets: [
        .executableTarget(
            name: "p2harness",
            dependencies: [.product(name: "RPVision", package: "RPVision")]
        )
    ]
)
