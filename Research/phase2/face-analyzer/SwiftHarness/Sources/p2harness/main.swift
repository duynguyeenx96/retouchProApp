import CoreGraphics
import CoreML
import Foundation
import ImageIO
import RPVision

// Phase 2 harness for RPVision's FaceAnalyzer.
//
//   p2harness run   <datasetDir> <label>   two-stage analysis of every image;
//                                          writes results/<label>/twostage.json
//   p2harness bench <datasetDir>           per-stage timings on this Mac;
//                                          writes Research/bench/p2-face-analyzer-macos.json
//   p2harness cache <datasetDir>           cold vs warm cost of the analysis cache;
//                                          appended to the same bench file
//
// <datasetDir> is a spike dataset directory with images/raw/*.jpg (S1's stock set,
// S1's a6300 set, ...). Model paths are overridable so the fp16 / fp32 detector
// builds can be compared:
//   P2_BLAZEFACE_MODEL, P2_LANDMARK_MODEL, P2_PARSING_MODEL
// and P2_PARSING=0 turns stage 4 off.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // p2harness
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // SwiftHarness
    .deletingLastPathComponent()  // face-analyzer
    .deletingLastPathComponent()  // phase2
    .deletingLastPathComponent()  // Research
    .deletingLastPathComponent()  // repo root

let harnessRoot = repoRoot.appendingPathComponent("Research/phase2/face-analyzer")
let env = ProcessInfo.processInfo.environment

func modelURL(_ key: String, default relativePath: String) -> URL {
    if let override = env[key] { return URL(fileURLWithPath: override) }
    return repoRoot.appendingPathComponent(relativePath)
}

let blazeFaceURL = modelURL(
    "P2_BLAZEFACE_MODEL",
    default: "Research/spikes/S1-landmark/models/BlazeFaceShortRange.mlpackage")
let landmarkURL = modelURL(
    "P2_LANDMARK_MODEL",
    default: "Research/spikes/S1-landmark/models/FaceLandmark478.mlpackage")
let parsingURL = modelURL(
    "P2_PARSING_MODEL",
    default: "Research/spikes/S2-face-parsing/models/FaceParsing19.mlpackage")
let parsingEnabled = env["P2_PARSING"] != "0"

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw Failure("cannot decode \(url.lastPathComponent)") }
    return image
}

/// Decode once into an uncompressed bitmap. Timing a JPEG-backed CGImage measures
/// libjpeg on every iteration, which is not what the render graph does.
func decoded(_ image: CGImage) throws -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("cannot make bitmap context") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let out = context.makeImage() else { throw Failure("cannot make bitmap image") }
    return out
}

func imageURLs(_ dataset: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: dataset.appendingPathComponent("images/raw"), includingPropertiesForKeys: nil
    )
    .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func write(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
    print("wrote \(url.path)")
}

func stats(_ xs: [Double]) -> [String: Double] {
    guard !xs.isEmpty else { return [:] }
    let s = xs.sorted()
    return [
        "mean_ms": xs.reduce(0, +) / Double(xs.count),
        "median_ms": s[s.count / 2],
        "p95_ms": s[min(s.count - 1, Int(Double(s.count) * 0.95))],
        "min_ms": s.first!,
        "max_ms": s.last!,
    ]
}

func makeAnalyzer(cacheCapacity: Int = 24) throws -> FaceAnalyzer {
    var options = FaceAnalyzerOptions()
    if !parsingEnabled { options.parsing = nil }
    // Sweep hooks: the stage-2 crop scale decides how many pixels of face BlazeFace
    // actually sees, and the ROI scale is MediaPipe's 1.5. Both are swept rather
    // than assumed; see results/*/sweep_summary.json.
    if let raw = env["P2_DETECTOR_SCALE"], let value = Double(raw) {
        options.detectorRegionScale = CGFloat(value)
    }
    if let raw = env["P2_ROI_SCALE"], let value = Double(raw) {
        options.landmarkROIScale = CGFloat(value)
    }
    return try FaceAnalyzer(
        models: FaceAnalyzer.Models(
            blazeFace: blazeFaceURL, landmark: landmarkURL,
            parsing: parsingEnabled ? parsingURL : nil),
        options: options, computeUnits: .all, cacheCapacity: cacheCapacity)
}

RPVisionFeatureFlags.faceAnalyzer = true
RPVisionFeatureFlags.blazeFaceShortRange = true
RPVisionFeatureFlags.faceLandmarks478 = true
RPVisionFeatureFlags.faceParsing19 = true

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run"
guard CommandLine.arguments.count > 2 else { throw Failure("usage: p2harness <cmd> <datasetDir> [label]") }
let dataset = URL(fileURLWithPath: CommandLine.arguments[2])
let label =
    CommandLine.arguments.count > 3
    ? CommandLine.arguments[3] : dataset.lastPathComponent

switch command {
case "run":
    let analyzer = try makeAnalyzer()
    var records: [[String: Any]] = []
    var skipped: [String] = []
    for url in try imageURLs(dataset) {
        let image = try loadImage(url)
        let analysis = try await analyzer.analyzeUncached(image)
        guard let face = analysis.faces.first else {
            skipped.append(url.lastPathComponent)
            FileHandle.standardError.write(Data("no face: \(url.lastPathComponent)\n".utf8))
            continue
        }
        var record: [String: Any] = [
            "image": url.lastPathComponent,
            "image_w": image.width, "image_h": image.height,
            "faces": analysis.faces.count,
            "vision_box": [
                face.visionBox.origin.x, face.visionBox.origin.y,
                face.visionBox.width, face.visionBox.height,
            ],
            "detector_region": [
                "center_x": face.detectorRegion.center.x,
                "center_y": face.detectorRegion.center.y,
                "side": face.detectorRegion.side,
            ],
            "blazeface_box": [
                face.detection.boundingBox.origin.x, face.detection.boundingBox.origin.y,
                face.detection.boundingBox.width, face.detection.boundingBox.height,
            ],
            "blazeface_score": face.detection.score,
            "blazeface_keypoints": face.detection.keypoints.flatMap { [$0.x, $0.y] },
            "crop": [
                "center_x": face.landmarks.crop.center.x,
                "center_y": face.landmarks.crop.center.y,
                "side": face.landmarks.crop.side,
                "rotation": face.landmarks.crop.rotation,
            ],
            "score": face.landmarks.score,
            "face_width_px": face.faceWidth,
            "image_points": face.imagePoints.flatMap { [$0.x, $0.y] },
        ]
        if let parsed = face.parsing {
            let coverage = parsed.coverage()
            record["parsing"] = [
                "region": [
                    "center_x": parsed.region.center.x, "center_y": parsed.region.center.y,
                    "side": parsed.region.side, "rotation": parsed.region.rotation,
                ],
                "parts_present": parsed.partsPresent(),
                "coverage": coverage,
                "skin_fraction": coverage[Int(FaceParsingClass.skin.rawValue)],
            ]
        }
        records.append(record)
        print(
            "\(url.lastPathComponent) det=\(String(format: "%.3f", face.detection.score)) "
                + "mesh=\(String(format: "%.3f", face.landmarks.score)) "
                + "roi=\(String(format: "%.1f", face.landmarks.crop.side)) "
                + "rot=\(String(format: "%.3f", face.landmarks.crop.rotation)) "
                + "parts=\(face.parsing.map { $0.partsPresent() ? "ok" : "MISSING" } ?? "-")")
    }
    try write(
        [
            "records": records, "skipped": skipped,
            "blazeface_model": blazeFaceURL.lastPathComponent,
            "parsing_enabled": parsingEnabled,
        ],
        to: harnessRoot.appendingPathComponent("results/\(label)/twostage.json"))

case "bench":
    let analyzer = try makeAnalyzer()
    let urls = try imageURLs(dataset)
    guard let first = urls.first else { throw Failure("no images in \(dataset.path)") }
    let image = try decoded(try loadImage(first))
    for _ in 0..<3 { _ = try await analyzer.analyzeUncached(image) }

    var vision: [Double] = [], blaze: [Double] = [], mesh: [Double] = []
    var parse: [Double] = [], total: [Double] = []
    for _ in 0..<30 {
        let a = try await analyzer.analyzeUncached(image)
        vision.append(a.timings.visionDetectMs)
        blaze.append(a.timings.blazeFaceMs)
        mesh.append(a.timings.landmarkMs)
        parse.append(a.timings.parsingMs)
        total.append(a.timings.totalMs)
    }

    // Cost of hashing pixels when the caller has no Shot.contentHash.
    var hash: [Double] = []
    for _ in 0..<10 {
        let t = DispatchTime.now().uptimeNanoseconds
        _ = FaceAnalysisKey.pixelHash(of: image)
        hash.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }

    // Cost of the mask feather a soft-mask consumer pays.
    var feather: [Double] = []
    if let parsed = try await analyzer.analyzeUncached(image).faces.first?.parsing {
        for _ in 0..<20 {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = parsed.feathered(.eyes)
            feather.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
    }

    let report: [String: Any] = [
        "host": ProcessInfo.processInfo.hostName,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "dataset": dataset.lastPathComponent,
        "image": first.lastPathComponent,
        "image_size": [image.width, image.height],
        "iterations": 30,
        "blazeface_model": blazeFaceURL.lastPathComponent,
        "parsing_enabled": parsingEnabled,
        "stages": [
            "vision_detect": stats(vision), "blazeface": stats(blaze),
            "mesh": stats(mesh), "parsing": stats(parse), "total": stats(total),
        ],
        "pixel_hash": stats(hash),
        "feather_eyes_512": stats(feather),
        "note":
            "Mac host measurement, compute units .all. The plan's device bar is a real "
            + "iPhone (PLAN §0.1); like spikes S1/S2 that number is still missing because no "
            + "device is attached to this machine. Stage timings come from "
            + "FaceAnalysis.timings, i.e. the product code's own clock.",
    ]
    try write(report, to: repoRoot.appendingPathComponent("Research/bench/p2-face-analyzer-macos.json"))

case "cache":
    // Does the cache actually stop the models from running again? Measured, not
    // asserted: cold path vs warm path on the same key, plus the hit/miss counters.
    let analyzer = try makeAnalyzer(cacheCapacity: 4)
    let urls = try imageURLs(dataset).prefix(6).map { $0 }
    guard !urls.isEmpty else { throw Failure("no images") }
    var images: [(String, CGImage)] = []
    for url in urls { images.append((url.lastPathComponent, try decoded(try loadImage(url)))) }

    var cold: [Double] = [], warm: [Double] = []
    for (name, image) in images {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try await analyzer.analysis(of: image, contentHash: "test:" + name)
        cold.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    // Re-request the last `capacity` images, which are the ones still resident.
    for (name, image) in images.suffix(4) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try await analyzer.analysis(of: image, contentHash: "test:" + name)
        warm.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    let statistics = await analyzer.cacheStatistics()

    // Concurrent duplicate requests must collapse into one run.
    await analyzer.clearCache()
    let (name, image) = images[0]
    let concurrentStart = DispatchTime.now().uptimeNanoseconds
    async let a = analyzer.analysis(of: image, contentHash: "dup:" + name)
    async let b = analyzer.analysis(of: image, contentHash: "dup:" + name)
    async let c = analyzer.analysis(of: image, contentHash: "dup:" + name)
    _ = try await (a, b, c)
    let concurrentMs = Double(DispatchTime.now().uptimeNanoseconds - concurrentStart) / 1e6

    let report: [String: Any] = [
        "host": ProcessInfo.processInfo.hostName,
        "dataset": dataset.lastPathComponent,
        "cache_capacity": 4,
        "images": images.count,
        "cold": stats(cold),
        "warm": stats(warm),
        "speedup_median": (stats(cold)["median_ms"] ?? 0) / max(stats(warm)["median_ms"] ?? 1, 1e-9),
        "hits": statistics.hits, "misses": statistics.misses,
        "evictions": statistics.evictions, "resident": statistics.count,
        "three_concurrent_same_key_ms": concurrentMs,
        "note":
            "cold = first analysis of each image, warm = same key again while resident. "
            + "The eviction count is the LRU doing its job: 6 images through a 4-entry cache. "
            + "three_concurrent_same_key_ms should be one cold analysis, not three.",
    ]
    try write(report, to: repoRoot.appendingPathComponent("Research/bench/p2-face-analyzer-cache-macos.json"))

default:
    throw Failure("unknown command \(command)")
}
