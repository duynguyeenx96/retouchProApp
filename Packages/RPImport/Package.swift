// swift-tools-version: 6.2
import PackageDescription

// RPImport — FilesImporter, PhotosImporter, MTPCameraImporter (ImageCaptureCore),
// FolderWatcher. Depends on RPCore only.
let package = Package(
    name: "RPImport",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPImport", targets: ["RPImport"])
    ],
    dependencies: [
        .package(path: "../RPCore")
    ],
    targets: [
        .target(name: "RPImport", dependencies: [.product(name: "RPCore", package: "RPCore")]),
        .testTarget(name: "RPImportTests", dependencies: ["RPImport"]),
    ]
)
