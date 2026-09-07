// swift-tools-version: 6.2
import PackageDescription

// RPVision — FaceAnalyzer: Vision → Core ML 478 landmarks → face parsing →
// SkinCore → FaceAnalysis cache. Depends on RPCore only.
let package = Package(
    name: "RPVision",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RPVision", targets: ["RPVision"])
    ],
    dependencies: [
        .package(path: "../RPCore")
    ],
    targets: [
        .target(name: "RPVision", dependencies: [.product(name: "RPCore", package: "RPCore")]),
        // SpikeS1/ carries the Phase 0 spike S1 artefacts: the converted
        // 478-point Core ML model, one 256px face crop and its golden landmarks.
        // They live in the *test* bundle on purpose — the model does not ship with
        // RPVision until Phase 2 decides where it belongs (Research/spikes/S1-landmark).
        // SpikeS2/ carries the Phase 0 spike S2 fixture: one 512px face crop
        // (Wikimedia Commons, CC BY-SA 4.0) and its golden 19-class label map.
        // The parsing .mlpackage is 25 MB and is *not* copied here — the tests read
        // it from Research/spikes/S2-face-parsing/models/ (see FaceParsingModelTests).
        // Phase2/ carries the BlazeFace detector: the .mlpackage is only 348 KB
        // (against the parsing model's 25 MB) so it is copied in like S1's mesh
        // model rather than read out of Research/, which keeps the two-stage
        // detection tests self-contained. Plus one 128px input and the golden
        // detection the Python side decoded for it.
        .testTarget(
            name: "RPVisionTests",
            dependencies: ["RPVision"],
            resources: [.copy("SpikeS1"), .copy("SpikeS2"), .copy("Phase2")]
        ),
    ]
)
