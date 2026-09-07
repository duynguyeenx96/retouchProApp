import CoreGraphics
import CoreML
import Foundation
import ImageIO
import RPVision
import UniformTypeIdentifiers

// Spike S1 harness.
//
//   s1harness run   <spikeDir>   detect + mesh every image, write crops/ and results/swift_landmarks.json
//   s1harness bench <spikeDir>   time the pipeline on this Mac, write results/bench_macos.json
//
// <spikeDir> defaults to Research/spikes/S1-landmark relative to this file.

let spikeDir: URL = {
    if CommandLine.arguments.count > 2 {
        return URL(fileURLWithPath: CommandLine.arguments[2])
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/s1harness
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // SwiftHarness
        .deletingLastPathComponent()  // S1-landmark
}()

let modelURL = spikeDir.appendingPathComponent("models/FaceLandmark478.mlpackage")
let imagesDir = spikeDir.appendingPathComponent("images/raw")
let cropsDir = spikeDir.appendingPathComponent("crops")
let resultsDir = spikeDir.appendingPathComponent("results")

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

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func imageURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil)
        .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
    var out: CGImage?
    VTCreateCGImageFromCVPixelBufferShim(buffer, &out)
    return out
}

// Minimal BGRA -> CGImage, avoids pulling in VideoToolbox.
func VTCreateCGImageFromCVPixelBufferShim(_ buffer: CVPixelBuffer, _ out: inout CGImage?) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let data = Data(bytes: base, count: stride * height)
    guard let provider = CGDataProvider(data: data as CFData) else { return }
    out = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

RPVisionFeatureFlags.faceLandmarks478 = true

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run"

switch command {
case "run":
    try FileManager.default.createDirectory(at: cropsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    let detector = try FaceLandmarkDetector(modelURL: modelURL, computeUnits: .all)
    var records: [[String: Any]] = []
    for url in try imageURLs() {
        let image = try loadImage(url)
        let faces = try await detector.detectFaces(in: image)
        guard let face = faces.first else {
            FileHandle.standardError.write(
                Data("no face: \(url.lastPathComponent)\n".utf8))
            continue
        }
        let crop = FaceCrop.mediaPipeStyle(
            boundingBox: face.boundingBox, rightEye: face.rightEye, leftEye: face.leftEye,
            scale: FaceCrop.visionBoxScale)
        let renderer = FaceCropRenderer()
        let buffer = try renderer.render(image, crop: crop)
        if let cropImage = cgImage(from: buffer) {
            let name = url.deletingPathExtension().lastPathComponent + ".png"
            try writePNG(cropImage, to: cropsDir.appendingPathComponent(name))
        }
        let result = try detector.landmarks(in: image, crop: crop)
        records.append([
            "image": url.lastPathComponent,
            "image_w": image.width, "image_h": image.height,
            "vision_box": [
                face.boundingBox.origin.x, face.boundingBox.origin.y,
                face.boundingBox.width, face.boundingBox.height,
            ],
            "crop": [
                "center_x": crop.center.x, "center_y": crop.center.y,
                "side": crop.side, "rotation": crop.rotation,
            ],
            "score": result.score,
            "crop_points": result.cropPoints.flatMap { [$0.x, $0.y] },
            "image_points": result.imagePoints.flatMap { [$0.x, $0.y] },
        ])
        print(
            "\(url.lastPathComponent) score=\(String(format: "%.4f", result.score)) "
                + "side=\(String(format: "%.1f", crop.side)) "
                + "rot=\(String(format: "%.3f", crop.rotation))")
    }
    let json = try JSONSerialization.data(
        withJSONObject: ["records": records], options: [.sortedKeys])
    let out = resultsDir.appendingPathComponent("swift_landmarks.json")
    try json.write(to: out)
    print("wrote \(out.path) (\(records.count) faces)")

case "sweep":
    // How much of the Swift end-to-end error is just "Vision's face box is not
    // BlazeFace's box"? Re-run every image at several ROI scale factors so the
    // Python side can pick the one that matches MediaPipe best.
    try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    let detector = try FaceLandmarkDetector(modelURL: modelURL, computeUnits: .all)
    // Override with S1_SWEEP_SCALES="1.2,1.3,..." to widen the sweep on a new dataset.
    let defaultScales: [CGFloat] = [1.30, 1.35, 1.40, 1.425, 1.45, 1.50, 1.55]
    var scales: [CGFloat] = defaultScales
    if let raw = ProcessInfo.processInfo.environment["S1_SWEEP_SCALES"] {
        let parsed: [CGFloat] = raw.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        }
        if !parsed.isEmpty { scales = parsed }
    }
    var configs: [String: Any] = [:]
    for scale in scales {
        var records: [[String: Any]] = []
        for url in try imageURLs() {
            let image = try loadImage(url)
            guard let face = try await detector.detectFaces(in: image).first else { continue }
            let crop = FaceCrop.mediaPipeStyle(
                boundingBox: face.boundingBox, rightEye: face.rightEye,
                leftEye: face.leftEye, scale: scale)
            let result = try detector.landmarks(in: image, crop: crop)
            records.append([
                "image": url.lastPathComponent,
                "crop": ["side": crop.side, "rotation": crop.rotation],
                "image_points": result.imagePoints.flatMap { [$0.x, $0.y] },
            ])
        }
        configs[String(format: "scale_%.3f", scale)] = records
        print("swept scale \(scale): \(records.count) faces")
    }
    let data = try JSONSerialization.data(withJSONObject: configs, options: [.sortedKeys])
    let out = resultsDir.appendingPathComponent("swift_roi_sweep.json")
    try data.write(to: out)
    print("wrote \(out.path)")

case "bench":
    try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    let url = try imageURLs().first ?? { throw Failure("no images") }()
    // Decode once into an uncompressed bitmap. Benchmarking straight off a
    // JPEG-backed CGImage measures libjpeg on every iteration, which is not what
    // the render graph will do (it hands the crop stage a decoded surface).
    let image = try decoded(try loadImage(url))
    let probe = try FaceLandmarkDetector(modelURL: modelURL, computeUnits: .all)
    let faces = try await probe.detectFaces(in: image)
    guard let face = faces.first else { throw Failure("no face in \(url.lastPathComponent)") }
    let crop = FaceCrop.mediaPipeStyle(
        boundingBox: face.boundingBox, rightEye: face.rightEye, leftEye: face.leftEye,
        scale: FaceCrop.visionBoxScale)

    var report: [String: Any] = [
        "host": ProcessInfo.processInfo.hostName,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "image": url.lastPathComponent,
        "iterations": 200,
    ]
    var byUnits: [String: Any] = [:]
    for (label, units) in [
        ("all", MLComputeUnits.all),
        ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
        ("cpuAndGPU", .cpuAndGPU),
        ("cpuOnly", .cpuOnly),
    ] {
        let model = try FaceLandmark478Model(url: modelURL, computeUnits: units)
        let renderer = FaceCropRenderer()
        let buffer = try renderer.render(image, crop: crop)
        for _ in 0..<20 { _ = try model.predict(crop: buffer) }  // warm up
        var inference: [Double] = []
        for _ in 0..<200 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try model.predict(crop: buffer)
            inference.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        var full: [Double] = []
        for _ in 0..<200 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let b = try renderer.render(image, crop: crop)
            _ = try model.predict(crop: b)
            full.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        func stats(_ xs: [Double]) -> [String: Double] {
            let s = xs.sorted()
            return [
                "mean_ms": xs.reduce(0, +) / Double(xs.count),
                "median_ms": s[s.count / 2],
                "p95_ms": s[Int(Double(s.count) * 0.95)],
                "min_ms": s.first!,
                "max_ms": s.last!,
            ]
        }
        byUnits[label] = ["inference": stats(inference), "crop_plus_inference": stats(full)]
        print(label, stats(inference)["median_ms"]!, "ms median inference")
    }

    // Vision face detection cost, measured once separately: it runs per image, not per face.
    var detect: [Double] = []
    for _ in 0..<20 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = try await probe.detectFaces(in: image)
        detect.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    report["compute_units"] = byUnits
    report["vision_detect_ms_median"] = detect.sorted()[detect.count / 2]
    report["note"] =
        "Mac host measurement. The plan's pass bar is a real iPad A-series; see the simulator "
        + "number in bench_ios_simulator.json and the pending-hardware note in S1-landmark.md."
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let out = resultsDir.appendingPathComponent("bench_macos.json")
    try data.write(to: out)
    print("wrote \(out.path)")

default:
    throw Failure("unknown command \(command)")
}
