import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing

@testable import RPEngine

/// Phase 0 spike S3 speed measurement, on whatever destination the test runs on.
///
/// Prints one `RPBENCH-S3 ` line that `Scripts/bench-s3.sh` scrapes into
/// `Research/bench/`, so the number filed there is always the number the test
/// measured — the same arrangement as `Scripts/bench-s2.sh`.
///
/// The plan's bars (docs/PLAN.md §3) are **≥ 30 fps at a 2048 px preview** and
/// **< 8 s for a 24 MP export**, on an iPhone (§0.1). The iOS Simulator has no
/// A-series GPU — it runs on the host Mac — so its figure is a plausibility
/// check, not the verdict. `is_real_device` in the JSON says which it is.
///
/// Inputs are the real Sony a6300 frame and the real MLS control points the
/// harness derived from S1's 478-point landmarks; they are read from
/// `Research/spikes/S3-guided-filter-mls/` rather than copied into the test
/// bundle (17 MB JPEG), the way `FaceParsingModelTests` reads the S2 model.
/// Override the root with `RP_S3_ROOT`.
@Suite("Spike S3 bench", .serialized)
struct SpikeS3BenchTests {
    static var spikeRoot: URL? {
        if let override = ProcessInfo.processInfo.environment["RP_S3_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        // <repo>/Packages/RPEngine/Tests/RPEngineTests/SpikeS3BenchTests.swift
        // — five components up is the repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let root = url.appendingPathComponent("Research/spikes/S3-guided-filter-mls")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// Minimal reader for `control/<image>.json`, which the S3 harness writes.
    /// Deliberately a separate declaration from the harness's `ControlPointFile`:
    /// RPEngine may not depend on anything under `Research/`.
    struct ControlPoints: Decodable {
        var image: String
        var imageWidth: Int
        var imageHeight: Int
        var faceWidth: Double
        var source: [[Double]]
        var destination: [[Double]]

        func scaled(by scale: Double) -> MLSDeformation.ControlPoints {
            MLSDeformation.ControlPoints(
                source: source.map { CGPoint(x: $0[0] * scale, y: $0[1] * scale) },
                destination: destination.map { CGPoint(x: $0[0] * scale, y: $0[1] * scale) })
        }
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    @Test("Measures ms/frame for the guided filter and the MLS mesh warp")
    func benchmark() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-S3-SKIP no Metal device")
            return
        }
        guard let root = Self.spikeRoot else {
            print("RPBENCH-S3-SKIP Research/spikes/S3-guided-filter-mls not reachable")
            return
        }
        let imageName = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        let imageURL = root.appendingPathComponent("images/full/\(imageName).jpg")
        let controlURL = root.appendingPathComponent("control/\(imageName).json")
        guard FileManager.default.fileExists(atPath: imageURL.path),
            FileManager.default.fileExists(atPath: controlURL.path)
        else {
            print("RPBENCH-S3-SKIP fixtures missing (run `s3harness controlpoints`)")
            return
        }

        // Held for the whole benchmark: the flag store is process-global and
        // suites run concurrently (see RPEngineTestFlags).
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.guidedFilter = true
            RPEngineFeatureFlags.mlsMeshWarp = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.guidedFilter = false
                RPEngineFeatureFlags.mlsMeshWarp = false
            }
        }
        let filter = try GuidedFilter(context: context)
        let warp = try MLSMeshWarp(context: context)
        let control = try JSONDecoder().decode(
            ControlPoints.self, from: Data(contentsOf: controlURL))

        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let image = try Self.loadUpright(imageURL)
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1e6

        var report: [String: Any] = [
            "suite": "S3 guided filter + MLS mesh warp",
            "image": imageName,
            "full_size": [image.width, image.height],
            "megapixels": Double(image.width * image.height) / 1e6,
            "control_points": control.source.count,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "jpeg_decode_plus_orient_ms": decodeMs,
            "build_configuration": Self.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "plan_bars": ["preview_2048_fps": 30, "export_24mp_seconds": 8],
        ]
        #if targetEnvironment(simulator)
            report["environment"] = "iOS Simulator (executes on the host Mac's GPU)"
            report["is_real_device"] = false
        #elseif os(iOS)
            report["environment"] = "iOS/iPadOS device"
            report["is_real_device"] = true
        #else
            report["environment"] = "macOS host"
            report["is_real_device"] = true
        #endif

        // ---- preview, 2048 px long edge -----------------------------------
        let scale = 2048.0 / Double(max(image.width, image.height))
        let previewWidth = Int((Double(image.width) * scale).rounded())
        let previewHeight = Int((Double(image.height) * scale).rounded())
        report["preview_size"] = [previewWidth, previewHeight]
        let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: previewWidth, height: previewHeight)
        report["preview"] = try Self.measure(
            context: context, filter: filter, warp: warp, pixels: previewPixels,
            width: previewWidth, height: previewHeight,
            control: control.scaled(by: scale), radius: 16, subsamples: [1, 4],
            grids: [65], iterations: 20)

        // ---- full resolution, 24 MP ---------------------------------------
        let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
        report["full"] = try Self.measure(
            context: context, filter: filter, warp: warp, pixels: fullPixels,
            width: image.width, height: image.height,
            control: control.scaled(by: 1), radius: Int((16.0 / scale).rounded()),
            subsamples: [4], grids: [129], iterations: 5)

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-S3 \(String(decoding: data, as: UTF8.self))")

        // Recorded, not asserted: the plan's bars are for real iPhone hardware,
        // which this environment does not have.
        let chained = (report["preview"] as? [String: Any])?["chained_ms"] as? Double ?? 0
        #expect(chained > 0)
    }

    static func measure(
        context: MetalContext, filter: GuidedFilter, warp: MLSMeshWarp,
        pixels: [Float], width: Int, height: Int,
        control: MLSDeformation.ControlPoints, radius: Int,
        subsamples: [Int], grids: [Int], iterations: Int
    ) throws -> [String: Any] {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let scratch = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        let imageSize = CGSize(width: width, height: height)

        func time(_ body: (any MTLCommandBuffer) -> Void) -> [String: Double] {
            for _ in 0..<2 {
                guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
                body(cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            var wall: [Double] = []
            var gpu: [Double] = []
            for _ in 0..<iterations {
                guard let cb = context.commandQueue.makeCommandBuffer() else { continue }
                let start = DispatchTime.now().uptimeNanoseconds
                body(cb)
                cb.commit()
                cb.waitUntilCompleted()
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return [
                "wall_median_ms": S3BenchStats.median(wall),
                "wall_p95_ms": S3BenchStats.percentile(wall, 0.95),
                "gpu_median_ms": S3BenchStats.median(gpu),
            ]
        }

        var result: [String: Any] = ["radius_px": radius, "iterations": iterations]
        var guided: [String: Any] = [:]
        var lastGuidedOptions = GuidedFilter.Options()
        var lastGuidedResources: GuidedFilter.Resources?
        for s in subsamples {
            let options = GuidedFilter.Options(
                radius: radius, epsilon: 4e-3, subsample: s, amount: 0.7)
            let resources = try filter.makeResources(
                width: width, height: height, options: options)
            guided["s=\(s)"] = time { cb in
                filter.encode(
                    into: cb, source: source, destination: destination,
                    resources: resources, options: options)
            }
            if s == 4 {
                lastGuidedOptions = options
                lastGuidedResources = resources
            }
        }
        result["guided_filter"] = guided

        var mls: [String: Any] = [:]
        var lastWarpOptions = MLSDeformation.Options()
        var lastWarpResources: MLSMeshWarp.Resources?
        for grid in grids {
            let options = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: grid, gridHeight: grid)
            let resources = try warp.makeResources(imageSize: imageSize, options: options)
            mls["grid=\(grid)"] = time { cb in
                try? warp.encode(
                    into: cb, source: source, destination: scratch, resources: resources,
                    control: control, options: options)
            }
            lastWarpOptions = options
            lastWarpResources = resources
        }
        result["mls_mesh_warp"] = mls

        if let gfResources = lastGuidedResources, let warpResources = lastWarpResources {
            let chained = time { cb in
                filter.encode(
                    into: cb, source: source, destination: scratch,
                    resources: gfResources, options: lastGuidedOptions)
                try? warp.encode(
                    into: cb, source: scratch, destination: destination,
                    resources: warpResources, control: control, options: lastWarpOptions)
            }
            result["chained"] = chained
            result["chained_ms"] = chained["wall_median_ms"] ?? 0
            result["chained_fps"] = 1000.0 / max(1e-9, chained["wall_median_ms"] ?? 1)
        }
        return result
    }

    /// EXIF orientation baked in — nine of the eleven a6300 frames are
    /// orientation 8, and a 4000×6000 frame benched as 6000×4000 would still
    /// produce a plausible-looking number for the wrong picture.
    static func loadUpright(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RPEngineError.cannotOpenImage(path: url.path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw RPEngineError.cannotDecodeImage(path: url.path) }
        return image
    }
}
