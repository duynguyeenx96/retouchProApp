import CoreGraphics
import CoreML
import Foundation
import ImageIO
import RPVision
import UniformTypeIdentifiers

// Spike S2 harness.
//
//   s2harness run     <spikeDir> [--from-raw]  parse every image, write
//                                              results/coreml_labels/*.png and
//                                              results/swift_parsing.json
//   s2harness overlay <spikeDir>                write results/overlays/*.png
//   s2harness bench   <spikeDir>                time it on this Mac ->
//                                              results/bench_macos.json
//
// Input selection matters and is explicit:
//   default     images/in512/*.png  — the exact 512x512 pixels torch_reference.py
//               fed PyTorch, so IoU differences are the model/runtime, not the
//               resampler.
//   --from-raw  images/raw/*.jpg    — the full-size source, resized by
//               FaceParsingRenderer (Core Image). This is what the app would do,
//               and the gap between the two is the cost of the resampler.
//
// <spikeDir> defaults to Research/spikes/S2-face-parsing relative to this file.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "run"
let fromRaw = arguments.contains("--from-raw")

let spikeDir: URL = {
    let positional = arguments.dropFirst(2).first { !$0.hasPrefix("--") }
    if let positional { return URL(fileURLWithPath: positional) }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/s2harness
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // SwiftHarness
        .deletingLastPathComponent()  // S2-face-parsing
}()

// The models always live in the top-level spike dir even when the dataset does not
// (a6300/ is a sibling dataset, like S1's).
let modelsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let modelURL = modelsRoot.appendingPathComponent("models/FaceParsing19.mlpackage")
let inputDir = spikeDir.appendingPathComponent(fromRaw ? "images/raw" : "images/in512")
let resultsDir = spikeDir.appendingPathComponent("results")
let labelsDir = resultsDir.appendingPathComponent(
    fromRaw ? "coreml_labels_fromraw" : "coreml_labels")
let overlaysDir = resultsDir.appendingPathComponent("overlays")

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw Failure("cannot decode \(url.lastPathComponent)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("cannot create \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("cannot write \(url.path)") }
}

/// 8-bit grey CGImage holding raw class indices (0...18), not a visualisation.
func grayImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    else { throw Failure("cannot build label image") }
    return image
}

// Upstream vis_parsing_maps' palette (vendor/test.py), so overlays here can be
// compared with published face-parsing.PyTorch results by eye.
let partColors: [(UInt8, UInt8, UInt8)] = [
    (0, 0, 0), (255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 0, 85), (255, 0, 170),
    (0, 255, 0), (85, 255, 0), (170, 255, 0), (0, 255, 85), (0, 255, 170),
    (0, 0, 255), (85, 0, 255), (170, 0, 255), (0, 85, 255), (0, 170, 255),
    (255, 255, 0), (255, 255, 85), (255, 255, 170),
]

func overlay(_ mask: FaceParsingMask, over image: CGImage) throws -> CGImage {
    let side = mask.width
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("cannot make overlay context") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let base = context.data else { throw Failure("no overlay backing store") }
    let pixels = base.bindMemory(to: UInt8.self, capacity: side * side * 4)
    for i in 0..<(side * side) {
        let label = Int(mask.labels[i])
        guard label > 0, label < partColors.count else { continue }
        let (r, g, b) = partColors[label]
        // 0.5/0.5 blend, close enough to upstream's 0.4/0.6 for eyeballing edges.
        pixels[i * 4] = UInt8((Int(pixels[i * 4]) + Int(r)) / 2)
        pixels[i * 4 + 1] = UInt8((Int(pixels[i * 4 + 1]) + Int(g)) / 2)
        pixels[i * 4 + 2] = UInt8((Int(pixels[i * 4 + 2]) + Int(b)) / 2)
    }
    guard let out = context.makeImage() else { throw Failure("cannot make overlay image") }
    return out
}

func inputURLs() throws -> [URL] {
    let files = try FileManager.default.contentsOfDirectory(
        at: inputDir, includingPropertiesForKeys: nil)
    return
        files
        .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? 0 : s[s.count / 2]
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
    print("wrote \(url.path)")
}

// MARK: - commands

RPVisionFeatureFlags.faceParsing19 = true

func runParse(writeOverlays: Bool) throws {
    try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: labelsDir, withIntermediateDirectories: true)
    if writeOverlays {
        try FileManager.default.createDirectory(
            at: overlaysDir, withIntermediateDirectories: true)
    }
    let model = try FaceParsingModel(url: modelURL)
    let renderer = FaceParsingRenderer()
    var perImage: [String: Any] = [:]
    var timings: [Double] = []

    for url in try inputURLs() {
        let name = url.deletingPathExtension().lastPathComponent
        let image = try loadImage(url)
        let start = DispatchTime.now().uptimeNanoseconds
        let buffer = try renderer.render(image)
        let mask = try model.predict(image: buffer)
        timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)

        try writePNG(
            try grayImage(mask.labels, width: mask.width, height: mask.height),
            to: labelsDir.appendingPathComponent("\(name).png"))
        if writeOverlays {
            try writePNG(
                try overlay(mask, over: image),
                to: overlaysDir.appendingPathComponent("\(name).png"))
        }
        let histogram = mask.histogram()
        perImage[name] = [
            "source": url.lastPathComponent,
            "source_size": [image.width, image.height],
            "histogram": histogram,
            "classes_present": histogram.enumerated().filter { $0.element > 0 }.map(\.offset),
            "ms": timings.last!,
        ]
        print("\(name): \(String(format: "%.1f", timings.last!)) ms")
    }

    try writeJSON(
        [
            "input": fromRaw ? "images/raw (FaceParsingRenderer resize)" : "images/in512 (matched)",
            "model": modelURL.lastPathComponent,
            "labels_dir": labelsDir.lastPathComponent,
            "images": perImage,
            "wall_ms_median_including_render": median(timings),
        ] as [String: Any],
        to: resultsDir.appendingPathComponent(
            fromRaw ? "swift_parsing_fromraw.json" : "swift_parsing.json"))
}

func runBench() throws {
    guard let url = try inputURLs().first else { throw Failure("no input images") }
    let image = try loadImage(url)
    var byUnits: [String: [String: Double]] = [:]
    let configurations: [(String, MLComputeUnits)] = [
        ("all", .all), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly),
    ]
    for (label, units) in configurations {
        let model = try FaceParsingModel(url: modelURL, computeUnits: units)
        let renderer = FaceParsingRenderer()
        let buffer = try renderer.render(image)
        for _ in 0..<5 { _ = try model.predict(image: buffer) }
        var inference: [Double] = []
        var full: [Double] = []
        for _ in 0..<30 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = try model.predict(image: buffer)
            inference.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = try model.predict(image: try renderer.render(image))
            full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        byUnits[label] = [
            "inference_median_ms": median(inference),
            "resize_plus_inference_median_ms": median(full),
        ]
        print("\(label): \(String(format: "%.2f", median(inference))) ms inference")
    }
    try writeJSON(
        [
            "suite": "S2 face parsing 19", "image": url.lastPathComponent,
            "iterations": 30, "compute_units": byUnits,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ] as [String: Any],
        to: resultsDir.appendingPathComponent("bench_macos.json"))
}

do {
    switch command {
    case "run": try runParse(writeOverlays: false)
    case "overlay": try runParse(writeOverlays: true)
    case "bench": try runBench()
    default: throw Failure("unknown command '\(command)'")
    }
} catch {
    FileHandle.standardError.write(Data("s2harness: \(error)\n".utf8))
    exit(1)
}
