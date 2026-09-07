import CoreGraphics
import Foundation
import Metal
import RPEngine

/// `s3harness accuracy <root>` — what the fast paths cost in accuracy, on the
/// real a6300 frames. Three questions, all answered with numbers in
/// `results/accuracy.json`:
///
/// 1. how dense does the warp mesh have to be before the piecewise-bilinear
///    approximation stops mattering (in pixels, and as a fraction of face width);
/// 2. how much does the fast (subsampled) guided filter differ from the exact one;
/// 3. does it matter whether the filter runs on sRGB-encoded or linear-light
///    pixels — the colour-space decision Phase 2 has to make once.
enum AccuracyCommand {
    static func run(_ arguments: [String]) throws {
        let paths = Harness.paths(arguments)
        guard let context = MetalContext.shared else { throw Harness.Failure.noMetal }
        RPEngineFeatureFlags.guidedFilter = true
        RPEngineFeatureFlags.mlsMeshWarp = true
        defer {
            RPEngineFeatureFlags.guidedFilter = false
            RPEngineFeatureFlags.mlsMeshWarp = false
        }
        let filter = try GuidedFilter(context: context)
        let warp = try MLSMeshWarp(context: context, pixelFormat: .rgba32Float)

        var meshRows: [[String: Any]] = []
        var filterRows: [[String: Any]] = []
        var colourRows: [[String: Any]] = []

        for url in try Harness.imageURLs(paths) {
            let name = url.deletingPathExtension().lastPathComponent
            let controlURL = paths.control.appendingPathComponent("\(name).json")
            guard FileManager.default.fileExists(atPath: controlURL.path) else { continue }
            let controlFile = try JSONDecoder().decode(
                ControlPointFile.self, from: Data(contentsOf: controlURL))
            let image = try Harness.loadUpright(url)
            let preview = Harness.previewSize(of: image, maxPixel: 2048)
            let scale = Double(preview.width) / Double(image.width)
            let control = controlFile.scaled(by: scale)
            let imageSize = CGSize(width: preview.width, height: preview.height)

            meshRows.append(
                try meshDensity(
                    context: context, warp: warp, control: control, imageSize: imageSize,
                    name: name, faceWidth: controlFile.faceWidth * scale,
                    image: image, preview: preview))

            let (srgbPixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded, width: preview.width, height: preview.height)
            filterRows.append(
                try subsampleAccuracy(
                    context: context, filter: filter, pixels: srgbPixels,
                    width: preview.width, height: preview.height, name: name))

            let (linearPixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .linearSRGB, width: preview.width, height: preview.height)
            colourRows.append(
                try colourSpaceComparison(
                    context: context, filter: filter, srgb: srgbPixels, linear: linearPixels,
                    width: preview.width, height: preview.height, name: name))
            print("accuracy \(name)")
        }

        try Harness.write(
            [
                "environment": Harness.environment,
                "resolution": "2048 px long edge (the preview the plan's fps bar is stated at)",
                "mesh_density": [
                    "what":
                        "Geometric error of the rasteriser's piecewise-bilinear interpolation "
                        + "between mesh vertices, against the exact MLS map evaluated in Double. "
                        + "Probe groups are reported separately because the error is "
                        + "concentrated where the deformation is.",
                    "images": meshRows,
                    "summary": summarise(meshRows, keysWithPrefix: "grid="),
                ],
                "guided_filter_subsampling": [
                    "what":
                        "PSNR of the fast (subsampled) guided filter against the exact s=1 "
                        + "filter, same radius and epsilon, on the real frames.",
                    "images": filterRows,
                    "summary": summarise(filterRows, keysWithPrefix: "s="),
                ],
                "pixel_space": [
                    "what":
                        "The same filter run on sRGB-encoded and on linear-light pixels, the "
                        + "linear result then re-encoded to sRGB so the two are comparable.",
                    "images": colourRows,
                ],
            ] as [String: Any],
            to: paths.results.appendingPathComponent("accuracy.json"))
    }

    // MARK: - 1. mesh density

    static func meshDensity(
        context: MetalContext, warp: MLSMeshWarp,
        control: MLSDeformation.ControlPoints, imageSize: CGSize,
        name: String, faceWidth: Double, image: CGImage, preview: (width: Int, height: Int)
    ) throws -> [String: Any] {
        // Probe groups. The handles are where the interpolation error peaks, so
        // reporting only a uniform sample would flatter the coarse grids.
        let handleProbes = Array(control.source.prefix(control.count - 16))
        var faceMinX = Double.infinity, faceMinY = Double.infinity
        var faceMaxX = -Double.infinity, faceMaxY = -Double.infinity
        for p in handleProbes {
            faceMinX = min(faceMinX, p.x); faceMaxX = max(faceMaxX, p.x)
            faceMinY = min(faceMinY, p.y); faceMaxY = max(faceMaxY, p.y)
        }
        var state: UInt64 = 99
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let faceProbes = (0..<4000).map { _ in
            CGPoint(
                x: faceMinX + next() * (faceMaxX - faceMinX),
                y: faceMinY + next() * (faceMaxY - faceMinY))
        }
        let frameProbes = (0..<4000).map { _ in
            CGPoint(x: next() * Double(imageSize.width), y: next() * Double(imageSize.height))
        }

        var row: [String: Any] = ["image": name, "face_width_px": faceWidth]
        // Reference image: a mesh so fine that a cell is under two pixels, which
        // is the closest thing to "exact" that can be rendered.
        let referenceGrid = 1025
        let referenceImage = try renderWarp(
            context: context, warp: warp, image: image, preview: preview,
            control: control, grid: referenceGrid)

        for grid in [17, 33, 65, 129, 257] {
            let options = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: grid, gridHeight: grid)
            let lattice = MLSDeformation.grid(
                control: control, options: options, imageSize: imageSize)
            func error(_ probes: [CGPoint]) -> (max: Double, mean: Double) {
                var worst = 0.0
                var total = 0.0
                for v in probes {
                    let exact = MLSDeformation.evaluate(
                        v, control: control, options: options,
                        scale: max(Double(imageSize.width), Double(imageSize.height)))
                    let approx = MLSDeformation.interpolate(
                        grid: lattice, gridWidth: grid, gridHeight: grid, at: v,
                        imageSize: imageSize)
                    let d = hypot(exact.x - approx.x, exact.y - approx.y)
                    worst = max(worst, d)
                    total += d
                }
                return (worst, total / Double(max(1, probes.count)))
            }
            let atHandles = error(handleProbes)
            let inFace = error(faceProbes)
            let inFrame = error(frameProbes)
            let rendered = try renderWarp(
                context: context, warp: warp, image: image, preview: preview,
                control: control, grid: grid)
            row["grid=\(grid)"] = [
                "max_error_px_at_handles": atHandles.max,
                "mean_error_px_at_handles": atHandles.mean,
                "max_error_px_in_face_box": inFace.max,
                "mean_error_px_in_face_box": inFace.mean,
                "max_error_px_in_frame": inFrame.max,
                "mean_error_px_in_frame": inFrame.mean,
                "max_error_over_face_width": inFace.max / max(1, faceWidth),
                "psnr_vs_grid\(referenceGrid)_db": SpikeTextureIO.psnr(referenceImage, rendered),
            ]
        }
        return row
    }

    static func renderWarp(
        context: MetalContext, warp: MLSMeshWarp, image: CGImage,
        preview: (width: Int, height: Int), control: MLSDeformation.ControlPoints, grid: Int
    ) throws -> [Float] {
        let (pixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: preview.width, height: preview.height)
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: preview.width, height: preview.height,
            device: context.device, usage: [.shaderRead])
        let destination = try SpikeTextureIO.makeTexture(
            width: preview.width, height: preview.height, device: context.device,
            pixelFormat: .rgba32Float, usage: [.shaderRead, .renderTarget])
        let options = MLSDeformation.Options(
            variant: .similarity, alpha: 2.0, gridWidth: grid, gridHeight: grid)
        let resources = try warp.makeResources(
            imageSize: CGSize(width: preview.width, height: preview.height), options: options)
        guard let cb = context.commandQueue.makeCommandBuffer() else { return [] }
        try warp.encode(
            into: cb, source: source, destination: destination, resources: resources,
            control: control, options: options)
        cb.commit()
        cb.waitUntilCompleted()
        return try readFloat32(destination, queue: context.commandQueue)
    }

    // MARK: - 2. subsampling

    static func subsampleAccuracy(
        context: MetalContext, filter: GuidedFilter, pixels: [Float],
        width: Int, height: Int, name: String
    ) throws -> [String: Any] {
        let exact = try runFilter(
            context: context, filter: filter, pixels: pixels, width: width, height: height,
            options: GuidedFilter.Options(radius: 16, epsilon: 4e-3, subsample: 1, amount: 1))
        var row: [String: Any] = ["image": name]
        row["psnr_filtered_vs_source_db"] = SpikeTextureIO.psnr(pixels, exact)
        for s in [2, 4, 8, 16] {
            let fast = try runFilter(
                context: context, filter: filter, pixels: pixels, width: width, height: height,
                options: GuidedFilter.Options(radius: 16, epsilon: 4e-3, subsample: s, amount: 1))
            row["s=\(s)"] = [
                "psnr_vs_exact_db": SpikeTextureIO.psnr(exact, fast),
                "max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(exact, fast),
            ]
        }
        return row
    }

    // MARK: - 3. pixel space

    static func colourSpaceComparison(
        context: MetalContext, filter: GuidedFilter, srgb: [Float], linear: [Float],
        width: Int, height: Int, name: String
    ) throws -> [String: Any] {
        let options = GuidedFilter.Options(radius: 16, epsilon: 4e-3, subsample: 4, amount: 1)
        let filteredSRGB = try runFilter(
            context: context, filter: filter, pixels: srgb, width: width, height: height,
            options: options)
        let filteredLinear = try runFilter(
            context: context, filter: filter, pixels: linear, width: width, height: height,
            options: options)
        let filteredLinearEncoded = filteredLinear.map { encodeSRGB($0) }

        // How much each variant changed the picture, per luminance decile of the
        // *source*. This is the number that says the two are not interchangeable:
        // the same epsilon smooths a different part of the tonal range.
        var byDecileSRGB = [Double](repeating: 0, count: 10)
        var byDecileLinear = [Double](repeating: 0, count: 10)
        var counts = [Double](repeating: 0, count: 10)
        for i in stride(from: 0, to: srgb.count, by: 4) {
            let luma = Double(srgb[i]) * 0.2126 + Double(srgb[i + 1]) * 0.7152
                + Double(srgb[i + 2]) * 0.0722
            let bucket = min(9, max(0, Int(luma * 10)))
            counts[bucket] += 3
            for c in 0..<3 {
                byDecileSRGB[bucket] += abs(Double(srgb[i + c] - filteredSRGB[i + c]))
                byDecileLinear[bucket] += abs(
                    Double(srgb[i + c] - filteredLinearEncoded[i + c]))
            }
        }
        for i in 0..<10 where counts[i] > 0 {
            byDecileSRGB[i] /= counts[i]
            byDecileLinear[i] /= counts[i]
        }

        return [
            "image": name,
            "psnr_srgb_vs_linear_result_db": SpikeTextureIO.psnr(
                filteredSRGB, filteredLinearEncoded),
            "max_abs_diff_srgb_units": SpikeTextureIO.maxAbsoluteDifference(
                filteredSRGB, filteredLinearEncoded),
            "mean_abs_change_by_source_luma_decile_srgb_space": byDecileSRGB,
            "mean_abs_change_by_source_luma_decile_linear_space": byDecileLinear,
            "pixels_per_decile": counts.map { $0 / 3 },
        ]
    }

    static func encodeSRGB(_ linear: Float) -> Float {
        let v = Double(max(0, min(1, linear)))
        return Float(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    // MARK: - plumbing

    static func runFilter(
        context: MetalContext, filter: GuidedFilter, pixels: [Float],
        width: Int, height: Int, options: GuidedFilter.Options
    ) throws -> [Float] {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        let resources = try filter.makeResources(
            width: width, height: height, options: options)
        guard let cb = context.commandQueue.makeCommandBuffer() else { return [] }
        filter.encode(
            into: cb, source: source, destination: destination, resources: resources,
            options: options)
        cb.commit()
        cb.waitUntilCompleted()
        return try readFloat32(destination, queue: context.commandQueue)
    }

    static func readFloat32(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [Float] {
        let bytesPerRow = texture.width * 16
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * texture.height, options: .storageModeShared),
            let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
        else { return [] }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { raw in
            raw.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.contents(), count: bytesPerRow * texture.height))
        }
        return out
    }

    /// Mean of every numeric leaf under the per-image rows whose key starts with
    /// `keysWithPrefix`, so the report can cite one number per configuration.
    static func summarise(_ rows: [[String: Any]], keysWithPrefix prefix: String) -> [String: Any] {
        var buckets: [String: [String: [Double]]] = [:]
        for row in rows {
            for (key, value) in row where key.hasPrefix(prefix) {
                guard let entry = value as? [String: Any] else { continue }
                for (metric, number) in entry {
                    guard let d = number as? Double, d.isFinite else { continue }
                    buckets[key, default: [:]][metric, default: []].append(d)
                }
            }
        }
        var out: [String: Any] = [:]
        for (key, metrics) in buckets {
            var summary: [String: Any] = [:]
            for (metric, values) in metrics {
                summary[metric + "_mean"] = Harness.mean(values)
                summary[metric + "_worst"] =
                    metric.contains("psnr") ? (values.min() ?? 0) : (values.max() ?? 0)
            }
            out[key] = summary
        }
        return out
    }
}
