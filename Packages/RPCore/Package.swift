// swift-tools-version: 6.2
import PackageDescription

// RPCore — domain model layer (Project, Shot, EditState, Preset, ProjectStore)
// plus project ownership (ProjectMutating / ProjectSession), so any package
// that has to write a Project concurrently gets the primitive from here rather
// than from an importer.
// Layer rule: RPCore is the bottom of the graph. It depends on nothing inside
// this repo and must never import UIKit / AppKit / SwiftUI.
let package = Package(
    name: "RPCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPCore", targets: ["RPCore"])
    ],
    targets: [
        .target(name: "RPCore"),
        .testTarget(name: "RPCoreTests", dependencies: ["RPCore"]),
    ]
)
