import CoreGraphics
import Foundation
import Metal
import RPEngine

/// `s3harness bench <root>` — the speed numbers for `docs/PLAN.md` §3 spike S3:
/// preview 2048 px ≥ 30 fps while dragging a slider, export < 8 s at 24 MP.
///
/// Every timing is a committed-and-waited command buffer, which is what a frame
/// loop actually feels, plus the GPU-reported time for the same buffer. The
/// run-time shader compile (`MetalContext.libraryCompileMilliseconds`) is paid
/// once before any of this and is reported separately, never folded in.
enum BenchCommand {
    /// Skip a configuration whose intermediates would not fit comfortably.
    static let memoryBudgetBytes = 3_000_000_000

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
        let warp = try MLSMeshWarp(context: context)

        let limit = Int(ProcessInfo.processInfo.environment["S3_BENCH_IMAGES"] ?? "3") ?? 3
        let urls = Array(try Harness.imageURLs(paths).prefix(limit))
        let previewIterations = 40
        let fullIterations = 8

        var perImage: [[String: Any]] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let controlURL = paths.control.appendingPathComponent("\(name).json")
            guard FileManager.default.fileExists(atPath: controlURL.path) else {
                throw Harness.Failure.missing(
                    "control/\(name).json — run `s3harness controlpoints` first")
            }
            let controlFile = try JSONDecoder().decode(
                ControlPointFile.self, from: Data(contentsOf: controlURL))

            let image = try Harness.loadUpright(url)
            var record: [String: Any] = [
                "image": name,
                "full_size": [image.width, image.height],
                "megapixels": Double(image.width * image.height) / 1e6,
                "control_points": controlFile.source.count,
            ]

            // ---- preview, 2048 px long edge -----------------------------------
            let preview = Harness.previewSize(of: image, maxPixel: 2048)
            let previewScale = Double(preview.width) / Double(image.width)
            record["preview_size"] = [preview.width, preview.height]
            let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded, width: preview.width, height: preview.height)
            record["preview"] = try measure(
                context: context, filter: filter, warp: warp, pixels: previewPixels,
                width: preview.width, height: preview.height,
                control: controlFile.scaled(by: previewScale),
                radius: 16, iterations: previewIterations, longEdge: 2048)

            // ---- full resolution, 24 MP ---------------------------------------
            let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded)
            // The skin-smoothing radius is a fraction of the face, so at export
            // it has to scale with the image or the export looks sharper than
            // the preview the user approved.
            let fullRadius = Int((16.0 / previewScale).rounded())
            record["full_radius_px"] = fullRadius
            record["full"] = try measure(
                context: context, filter: filter, warp: warp, pixels: fullPixels,
                width: image.width, height: image.height,
                control: controlFile.controlPoints,
                radius: fullRadius, iterations: fullIterations,
                longEdge: max(image.width, image.height))

            // ---- CPU-side I/O, which an export has to pay too ------------------
            var uploads: [Double] = []
            var readbacks: [Double] = []
            for _ in 0..<3 {
                var start = DispatchTime.now().uptimeNanoseconds
                let texture = try SpikeTextureIO.makeTexture(
                    fromFloatPixels: fullPixels, width: image.width, height: image.height,
                    device: context.device, usage: [.shaderRead])
                uploads.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                start = DispatchTime.now().uptimeNanoseconds
                _ = try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
                readbacks.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            var decodeTimes: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try Harness.loadUpright(url)
                decodeTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            record["cpu_io_full_res"] = [
                "cgimage_to_float32_plus_upload_median_ms": Harness.median(uploads),
                "texture_readback_to_float32_median_ms": Harness.median(readbacks),
                "jpeg_decode_plus_orient_median_ms": Harness.median(decodeTimes),
                "note":
                    "The JPEG decode stands in for the RAW decode; spike S4 owns CIRAWFilter. "
                    + "Listed so the < 8 s export budget is read against the whole cost, not "
                    + "just the GPU part.",
            ]
            perImage.append(record)
            print("benched \(name)")
        }

        try Harness.write(
            [
                "suite": "S3 guided filter + MLS mesh warp",
                "environment": Harness.environment,
                "shader_compile_ms": context.libraryCompileMilliseconds,
                "pixel_space": "sRGBEncoded",
                "plan_bars": [
                    "preview_2048_fps": 30,
                    "export_24mp_seconds": 8,
                    "note":
                        "docs/PLAN.md §3 states these for an iPhone (§0.1). This file is the "
                        + "macOS host; the Simulator figure is in Research/bench/.",
                ],
                "images": perImage,
            ] as [String: Any],
            to: paths.results.appendingPathComponent("bench_macos.json"))
    }

    /// All timings for one resolution of one image.
    static func measure(
        context: MetalContext,
        filter: GuidedFilter,
        warp: MLSMeshWarp,
        pixels: [Float],
        width: Int,
        height: Int,
        control: MLSDeformation.ControlPoints,
        radius: Int,
        iterations: Int,
        longEdge: Int
    ) throws -> [String: Any] {
        let device = context.device
        let queue = context.commandQueue
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: device,
            usage: [.shaderRead, .shaderWrite])
        let scratch = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: device,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: device,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

        var result: [String: Any] = ["radius_px": radius]

        // --- guided filter, subsample sweep ---------------------------------
        var guided: [String: Any] = [:]
        for s in [1, 2, 4, 8] {
            let options = GuidedFilter.Options(
                radius: radius, epsilon: 4e-3, subsample: s, amount: 1)
            let allocStart = DispatchTime.now().uptimeNanoseconds
            let resources = try filter.makeResources(
                width: width, height: height, options: options)
            let allocMs = Double(DispatchTime.now().uptimeNanoseconds - allocStart) / 1e6
            guard resources.byteCount <= memoryBudgetBytes else {
                guided["s=\(s)"] = [
                    "skipped": "intermediates would be \(resources.byteCount) bytes",
                    "intermediate_bytes": resources.byteCount,
                ]
                continue
            }
            let times = Harness.time(queue, iterations: iterations) { cb in
                filter.encode(
                    into: cb, source: source, destination: destination,
                    resources: resources, options: options)
            }
            var entry = Harness.stats(times.wall, times.gpu)
            entry["intermediate_bytes"] = resources.byteCount
            entry["allocate_resources_ms"] = allocMs
            entry["subsampled_radius"] = options.subsampledRadius
            entry["sub_size"] = [resources.subWidth, resources.subHeight]
            guided["s=\(s)"] = entry
        }
        result["guided_filter"] = guided

        // --- MLS mesh warp, grid sweep --------------------------------------
        var mls: [String: Any] = [:]
        let imageSize = CGSize(width: width, height: height)
        for grid in [17, 33, 65, 129, 257] {
            let options = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: grid, gridHeight: grid)
            let resources = try warp.makeResources(imageSize: imageSize, options: options)
            let solve = Harness.time(queue, iterations: iterations) { cb in
                try? warp.encodeGridSolve(
                    into: cb, resources: resources, control: control, options: options,
                    imageSize: imageSize)
            }
            // The solve has to have happened before the draw is timed, or the
            // draw reads an empty vertex buffer and rasterises a degenerate mesh
            // — which is fast, and wrong.
            let draw = Harness.time(queue, iterations: iterations) { cb in
                warp.encodeDraw(
                    into: cb, source: source, destination: scratch, resources: resources)
            }
            let both = Harness.time(queue, iterations: iterations) { cb in
                try? warp.encode(
                    into: cb, source: source, destination: scratch, resources: resources,
                    control: control, options: options)
            }
            mls["grid=\(grid)"] = [
                "solve": Harness.stats(solve.wall, solve.gpu),
                "draw": Harness.stats(draw.wall, draw.gpu),
                "solve_plus_draw": Harness.stats(both.wall, both.gpu),
                "vertices": grid * grid,
                "triangles": (grid - 1) * (grid - 1) * 2,
            ]
        }

        // Control: evaluate the MLS at every pixel. This is not a usable warp on
        // its own (a forward map cannot be scattered), but it is what a per-pixel
        // implementation would have to cost, so it prices the mesh.
        let perPixelBytes = width * height * MemoryLayout<SIMD2<Float>>.stride
        if perPixelBytes <= memoryBudgetBytes,
            let output = device.makeBuffer(length: perPixelBytes, options: .storageModeShared)
        {
            let options = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: 17, gridHeight: 17)
            let resources = try warp.makeResources(imageSize: imageSize, options: options)
            let times = Harness.time(queue, iterations: max(3, iterations / 8), warmup: 1) { cb in
                try? warp.encodeGridSolve(
                    into: cb, output: output, resources: resources, control: control,
                    options: options, imageSize: imageSize, gridWidth: width, gridHeight: height)
            }
            var entry = Harness.stats(times.wall, times.gpu)
            entry["note"] = "control: MLS evaluated per pixel instead of on a mesh"
            mls["per_pixel_solve"] = entry
        }
        result["mls_mesh_warp"] = mls

        // --- the two chained, which is what a frame really is -----------------
        let gfOptions = GuidedFilter.Options(
            radius: radius, epsilon: 4e-3, subsample: 4, amount: 0.7)
        let gfResources = try filter.makeResources(
            width: width, height: height, options: gfOptions)
        var chained: [String: Any] = [:]
        for grid in [65, 129] {
            let warpOptions = MLSDeformation.Options(
                variant: .similarity, alpha: 2.0, gridWidth: grid, gridHeight: grid)
            let warpResources = try warp.makeResources(
                imageSize: imageSize, options: warpOptions)
            let times = Harness.time(queue, iterations: iterations) { cb in
                filter.encode(
                    into: cb, source: source, destination: scratch,
                    resources: gfResources, options: gfOptions)
                try? warp.encode(
                    into: cb, source: scratch, destination: destination,
                    resources: warpResources, control: control, options: warpOptions)
            }
            var entry = Harness.stats(times.wall, times.gpu)
            entry["fps_from_wall_median"] = 1000.0 / max(1e-9, Harness.median(times.wall))
            chained["guided_s4_plus_mls_grid\(grid)"] = entry
        }
        result["chained"] = chained
        result["long_edge_px"] = longEdge
        return result
    }
}
