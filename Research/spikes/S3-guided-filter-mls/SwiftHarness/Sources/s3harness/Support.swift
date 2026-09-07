import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import RPEngine
import UniformTypeIdentifiers

/// Paths, image loading and JSON plumbing shared by the S3 harness commands.
enum Harness {
    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

    struct Paths {
        var root: URL
        var full: URL { root.appendingPathComponent("images/full") }
        var control: URL { root.appendingPathComponent("control") }
        var results: URL { root.appendingPathComponent("results") }
        var landmarkModel: URL {
            root.deletingLastPathComponent()
                .appendingPathComponent("S1-landmark/models/FaceLandmark478.mlpackage")
        }
    }

    static func paths(_ arguments: [String]) -> Paths {
        let root = arguments.count > 2 ? arguments[2] : ".."
        return Paths(root: URL(fileURLWithPath: root).standardizedFileURL)
    }

    static func imageURLs(_ paths: Paths) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: paths.full, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Decodes a JPEG with its EXIF orientation baked into the pixels. Nine of
    /// the eleven a6300 frames are orientation 8 (portrait), so skipping this
    /// would silently measure a rotated face.
    static func loadUpright(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.cannotDecode(url.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard orientation > 1 else { return raw }
        let oriented = CIImage(cgImage: raw).oriented(forExifOrientation: Int32(orientation))
        guard let result = ciContext.createCGImage(oriented, from: oriented.extent) else {
            throw Failure.cannotDecode(url.lastPathComponent)
        }
        return result
    }

    /// Longest-edge-`maxPixel` size for an image, preserving aspect.
    static func previewSize(of image: CGImage, maxPixel: Int) -> (width: Int, height: Int) {
        let scale = Double(maxPixel) / Double(max(image.width, image.height))
        return (max(1, Int((Double(image.width) * scale).rounded())),
                max(1, Int((Double(image.height) * scale).rounded())))
    }

    enum Failure: Error, CustomStringConvertible {
        case cannotDecode(String)
        case noMetal
        case noFace(String)
        case missing(String)

        var description: String {
            switch self {
            case .cannotDecode(let name): "Cannot decode \(name)."
            case .noMetal: "No Metal device."
            case .noFace(let name): "No face found in \(name)."
            case .missing(let what): "Missing \(what)."
            }
        }
    }

    static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Wall-clock and GPU time for one committed command buffer, milliseconds.
    static func time(
        _ queue: any MTLCommandQueue, iterations: Int, warmup: Int = 3,
        _ body: (any MTLCommandBuffer) -> Void
    ) -> (wall: [Double], gpu: [Double]) {
        for _ in 0..<warmup {
            guard let cb = queue.makeCommandBuffer() else { continue }
            body(cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        var wall: [Double] = []
        var gpu: [Double] = []
        for _ in 0..<iterations {
            guard let cb = queue.makeCommandBuffer() else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            body(cb)
            cb.commit()
            cb.waitUntilCompleted()
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        return (wall, gpu)
    }

    static func stats(_ wall: [Double], _ gpu: [Double]) -> [String: Any] {
        [
            "wall_median_ms": median(wall),
            "wall_p95_ms": percentile(wall, 0.95),
            "wall_min_ms": wall.min() ?? 0,
            "gpu_median_ms": median(gpu),
            "gpu_p95_ms": percentile(gpu, 0.95),
            "iterations": wall.count,
        ]
    }

    static var environment: [String: Any] {
        var info: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "host_cpu_cores": ProcessInfo.processInfo.processorCount,
            "physical_memory_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1e9,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            info["metal_device"] = device.name
            info["has_unified_memory"] = device.hasUnifiedMemory
            info["recommended_working_set_gb"] =
                Double(device.recommendedMaxWorkingSetSize) / 1e9
        }
        return info
    }
}

/// On-disk form of one image's MLS control points. Written by
/// `s3harness controlpoints`, read by the harness benchmarks *and* by
/// `RPEngineTests`, which is how a real face reaches a package that is not
/// allowed to import RPVision.
struct ControlPointFile: Codable {
    var image: String
    var imageWidth: Int
    var imageHeight: Int
    var faceWidth: Double
    var maxDisplacementPx: Double
    var sliders: [String: Double]
    var source: [[Double]]
    var destination: [[Double]]

    var controlPoints: MLSDeformation.ControlPoints {
        MLSDeformation.ControlPoints(
            source: source.map { CGPoint(x: $0[0], y: $0[1]) },
            destination: destination.map { CGPoint(x: $0[0], y: $0[1]) })
    }

    /// The same handles expressed in a `scale`-times-smaller image.
    func scaled(by scale: Double) -> MLSDeformation.ControlPoints {
        MLSDeformation.ControlPoints(
            source: source.map { CGPoint(x: $0[0] * scale, y: $0[1] * scale) },
            destination: destination.map { CGPoint(x: $0[0] * scale, y: $0[1] * scale) })
    }
}
