import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import RPEngine

/// `s3harness mps <root>` — the control run for "should this have been
/// `MPSImageGuidedFilter` instead of a hand-written kernel?".
///
/// MPS ships a guided filter, so not using it needs a measurement rather than an
/// opinion. Two configurations are timed and compared against RPEngine's
/// `GuidedFilter`:
///
/// * **full-res regression** — the closest MPS gets to the exact filter;
/// * **1/4-res regression, full-res reconstruction** — MPS's intended use, and
///   the analogue of the fast guided filter with `s = 4`.
///
/// MPS's per-channel regression has no second box pass over `a`/`b` (its
/// smoothing is meant to come from upsampling low-res coefficients), so the
/// output is expected to differ; the point of this file is to say by how much,
/// and whether it is faster.
enum MPSControlCommand {
    static func run(_ arguments: [String]) throws {
        let paths = Harness.paths(arguments)
        guard let context = MetalContext.shared else { throw Harness.Failure.noMetal }
        guard MPSSupportsMTLDevice(context.device) else {
            try Harness.write(
                ["supported": false, "environment": Harness.environment] as [String: Any],
                to: paths.results.appendingPathComponent("mps_control.json"))
            return
        }
        RPEngineFeatureFlags.guidedFilter = true
        defer { RPEngineFeatureFlags.guidedFilter = false }
        let filter = try GuidedFilter(context: context)

        let limit = Int(ProcessInfo.processInfo.environment["S3_BENCH_IMAGES"] ?? "3") ?? 3
        let urls = Array(try Harness.imageURLs(paths).prefix(limit))
        let radius = 16
        let diameter = 2 * radius + 1
        let epsilon: Float = 4e-3

        var rows: [[String: Any]] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let image = try Harness.loadUpright(url)
            let preview = Harness.previewSize(of: image, maxPixel: 2048)
            let (pixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded, width: preview.width, height: preview.height)

            let source = try SpikeTextureIO.makeTexture(
                fromFloatPixels: pixels, width: preview.width, height: preview.height,
                device: context.device, usage: [.shaderRead, .shaderWrite])
            let destination = try SpikeTextureIO.makeTexture(
                width: preview.width, height: preview.height, device: context.device,
                pixelFormat: .rgba32Float, usage: [.shaderRead, .shaderWrite])

            // RPEngine, exact and fast, as the reference and the speed baseline.
            let exact = try AccuracyCommand.runFilter(
                context: context, filter: filter, pixels: pixels,
                width: preview.width, height: preview.height,
                options: GuidedFilter.Options(
                    radius: radius, epsilon: epsilon, subsample: 1, amount: 1))
            let fast = try AccuracyCommand.runFilter(
                context: context, filter: filter, pixels: pixels,
                width: preview.width, height: preview.height,
                options: GuidedFilter.Options(
                    radius: radius, epsilon: epsilon, subsample: 4, amount: 1))

            var row: [String: Any] = [
                "image": name,
                "size": [preview.width, preview.height],
                "radius_px": radius,
                "epsilon": epsilon,
            ]

            for coefficientDivisor in [1, 4] {
                let label = coefficientDivisor == 1
                    ? "mps_full_res_regression" : "mps_quarter_res_regression"
                do {
                    let coefficientWidth = (preview.width + coefficientDivisor - 1)
                        / coefficientDivisor
                    let coefficientHeight = (preview.height + coefficientDivisor - 1)
                        / coefficientDivisor
                    let a = try SpikeTextureIO.makeTexture(
                        width: coefficientWidth, height: coefficientHeight,
                        device: context.device, pixelFormat: .rgba32Float,
                        usage: [.shaderRead, .shaderWrite])
                    let b = try SpikeTextureIO.makeTexture(
                        width: coefficientWidth, height: coefficientHeight,
                        device: context.device, pixelFormat: .rgba32Float,
                        usage: [.shaderRead, .shaderWrite])
                    // The regression's source/guidance are read at the coefficient
                    // resolution, so a divisor > 1 needs its own downsampled copy.
                    let regressionInput: any MTLTexture
                    if coefficientDivisor == 1 {
                        regressionInput = source
                    } else {
                        let small = downsample(
                            pixels, width: preview.width, height: preview.height,
                            factor: coefficientDivisor)
                        regressionInput = try SpikeTextureIO.makeTexture(
                            fromFloatPixels: small.pixels, width: small.width,
                            height: small.height, device: context.device,
                            usage: [.shaderRead, .shaderWrite])
                    }
                    // MPS's window is in coefficient-texture pixels, so it has to
                    // shrink with the divisor to cover the same area of the photo.
                    let mps = MPSImageGuidedFilter(
                        device: context.device,
                        kernelDiameter: max(3, (diameter / coefficientDivisor) | 1))
                    mps.epsilon = epsilon

                    let times = Harness.time(context.commandQueue, iterations: 20) { cb in
                        mps.encodeRegression(
                            commandBuffer: cb, source: regressionInput,
                            guidance: regressionInput, weights: nil,
                            destinationCoefficientsA: a, destinationCoefficientsB: b)
                        mps.encodeReconstruction(
                            commandBuffer: cb, guidance: source, coefficientsA: a,
                            coefficientsB: b, destination: destination)
                    }
                    let output = try AccuracyCommand.readFloat32(
                        destination, queue: context.commandQueue)
                    var entry = Harness.stats(times.wall, times.gpu)
                    entry["psnr_vs_rpengine_exact_db"] = SpikeTextureIO.psnr(exact, output)
                    entry["psnr_vs_rpengine_s4_db"] = SpikeTextureIO.psnr(fast, output)
                    entry["psnr_vs_source_db"] = SpikeTextureIO.psnr(pixels, output)
                    entry["kernel_diameter"] = max(3, (diameter / coefficientDivisor) | 1)
                    entry["coefficient_size"] = [coefficientWidth, coefficientHeight]
                    row[label] = entry
                } catch {
                    row[label] = ["failed": "\(error)"]
                }
            }

            // RPEngine's own timings on exactly the same textures.
            for s in [1, 4] {
                let options = GuidedFilter.Options(
                    radius: radius, epsilon: epsilon, subsample: s, amount: 1)
                let resources = try filter.makeResources(
                    width: preview.width, height: preview.height, options: options)
                let times = Harness.time(context.commandQueue, iterations: 20) { cb in
                    filter.encode(
                        into: cb, source: source, destination: destination,
                        resources: resources, options: options)
                }
                row["rpengine_s\(s)"] = Harness.stats(times.wall, times.gpu)
            }
            row["psnr_rpengine_s4_vs_exact_db"] = SpikeTextureIO.psnr(exact, fast)
            rows.append(row)
            print("mps control \(name)")
        }

        try Harness.write(
            [
                "supported": true,
                "environment": Harness.environment,
                "resolution": "2048 px long edge",
                "note":
                    "MPSImageGuidedFilter's per-channel regression fits a per-pixel affine map "
                    + "and does not box-filter the coefficients; the smoothing of a and b is "
                    + "meant to come from upsampling a low-resolution coefficient texture. "
                    + "It is therefore not expected to reproduce the textbook filter, and the "
                    + "PSNR columns say how far apart they are.",
                "images": rows,
            ] as [String: Any],
            to: paths.results.appendingPathComponent("mps_control.json"))
    }

    static func downsample(_ pixels: [Float], width: Int, height: Int, factor: Int)
        -> (pixels: [Float], width: Int, height: Int)
    {
        let w = (width + factor - 1) / factor
        let h = (height + factor - 1) / factor
        var out = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var sum = [Double](repeating: 0, count: 4)
                var n = 0.0
                for sy in (y * factor)..<min((y + 1) * factor, height) {
                    for sx in (x * factor)..<min((x + 1) * factor, width) {
                        for c in 0..<4 { sum[c] += Double(pixels[(sy * width + sx) * 4 + c]) }
                        n += 1
                    }
                }
                for c in 0..<4 { out[(y * w + x) * 4 + c] = Float(sum[c] / max(1, n)) }
            }
        }
        return (out, w, h)
    }
}
