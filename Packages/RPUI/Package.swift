// swift-tools-version: 6.2
import PackageDescription

// RPUI — SwiftUI layer: ProjectsView, EditorView (Filmstrip / Canvas /
// SliderPanel / PresetBar), BatchExportView, PresetManager.
//
// Depends on RPEngine + RPCore, all strictly downward; nothing depends on RPUI
// except the app target.
//
// There is deliberately **no** RPImport edge. It existed only to reach
// `ProjectMutating` / `ProjectSession` (docs/ADR-0004 §1); the Phase 1 review
// moved those into RPCore, where project ownership belongs, so RPUI no longer
// links PhotoKit / ImageCaptureCore just to serialise a write. The app target
// links RPImport directly and hands importers an `EditorModel`, which still
// conforms to `ProjectMutating`.
let package = Package(
    name: "RPUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPUI", targets: ["RPUI"])
    ],
    dependencies: [
        .package(path: "../RPCore"),
        .package(path: "../RPEngine"),
    ],
    targets: [
        .target(
            name: "RPUI",
            dependencies: [
                .product(name: "RPCore", package: "RPCore"),
                .product(name: "RPEngine", package: "RPEngine"),
            ]
        ),
        .testTarget(name: "RPUITests", dependencies: ["RPUI"]),
    ]
)
