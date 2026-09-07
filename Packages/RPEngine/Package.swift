// swift-tools-version: 6.2
import PackageDescription

// RPEngine — Metal + Core Image render graph, PreviewRenderer, ExportRenderer,
// BatchQueue. Depends on RPCore only; must never import UIKit / AppKit / SwiftUI.
let package = Package(
    name: "RPEngine",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPEngine", targets: ["RPEngine"])
    ],
    dependencies: [
        .package(path: "../RPCore")
    ],
    targets: [
        // Spike/MetalSources/ holds Shaders.metal and is copied as an **opaque
        // directory**, not as a source file. Two build systems, two problems:
        //   * `swift build` does not compile .metal at all — it reports the file
        //     as "unhandled" and emits no default.metallib, so the Research/
        //     spike harness (built with swift build) would have no shaders;
        //   * `xcodebuild` *does* pick up any .metal it can see, even one listed
        //     under `resources:`, and on Xcode 26 that needs the separately
        //     downloadable Metal Toolchain component, which fails the whole test
        //     run on a machine without it.
        // Copying a directory sidesteps both: neither build system looks inside,
        // and MetalContext compiles the source with makeLibrary(source:) at run
        // time — one code path that behaves the same under swift build,
        // xcodebuild macOS and the iOS Simulator.
        // See MetalContext's doc comment, docs/ADR-0007 and
        // Research/spikes/S3-guided-filter-mls/S3-guided-filter-mls.md.
        .target(
            name: "RPEngine",
            dependencies: [.product(name: "RPCore", package: "RPCore")],
            // Render/RenderShaderSources holds the Phase 2 render kernels (the
            // "Da", "Mắt / Răng" and "Color" groups, one .metal each) and is
            // copied for exactly the same reason. It must **not** also be called
            // MetalSources: `.copy` flattens to the last path component, so two
            // directories with the same leaf name would collide in the bundle.
            resources: [.copy("Spike/MetalSources"), .copy("Render/RenderShaderSources")]
        ),
        .testTarget(name: "RPEngineTests", dependencies: ["RPEngine"]),
    ]
)
