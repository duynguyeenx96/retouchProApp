// swift-tools-version: 6.2
import PackageDescription

// Spike S3 harness. Lives under Research/ on purpose: it is a measurement tool,
// not product code, and it must not become a dependency of the app workspace.
//
// It depends on *both* RPEngine (the kernels being measured) and RPVision (the
// 478-point landmark model, so the MLS control points come from a real face
// rather than from made-up coordinates). That edge is legal here and illegal in
// the product: `RPEngine` must never import `RPVision`
// (RPTestKitTests/LayeringAuditTests). The bridge is data — the harness writes
// the control points to JSON and RPEngine only ever sees `[CGPoint]`.
let package = Package(
    name: "S3Harness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../../Packages/RPEngine"),
        .package(path: "../../../../Packages/RPVision"),
    ],
    targets: [
        .executableTarget(
            name: "s3harness",
            dependencies: [
                .product(name: "RPEngine", package: "RPEngine"),
                .product(name: "RPVision", package: "RPVision"),
            ]
        )
    ]
)
