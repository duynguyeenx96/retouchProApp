import CoreGraphics
import Foundation
import Metal
import RPEngine

/// `s3harness mlsgpu <root>` — how far the float32 Metal grid solve is from the
/// `Double` CPU reference **on the real face-reshape handles**.
///
/// The handles are the 84 control points `s3harness controlpoints` derives from
/// S1's 478-point mesh on each a6300 frame (68 face-oval + eye-ring handles plus
/// 16 border anchors), not a synthetic configuration. Both implementations are
/// asked for the same lattice; the metric is the distance between the two
/// answers, in image pixels and as a fraction of face width.
///
/// Measured at both operating points ADR-0007 fixes: a 2048 px preview with grid
/// 65 and the full 24 MP frame with grid 129, plus grid 33 at each so the trend
/// with lattice density is visible. Result: `results/mls_gpu_vs_cpu.json`.
///
/// Why this is not folded into `accuracy`: that command answers "how much does
/// the *approximation* cost" (mesh density, subsampling, colour space) and needs
/// the 190 MB of decoded frames. This one only needs `control/*.json` and
/// answers "are the two transcriptions of the formula the same function".
enum MLSGPUAccuracyCommand {
    /// Grid sizes measured at each resolution. 65 / 129 are ADR-0007's preview /
    /// export defaults; 33 is carried so the table shows the trend.
    static let grids = [33, 65, 129]

    static func run(_ arguments: [String]) throws {
        let paths = Harness.paths(arguments)
        guard let context = MetalContext.shared else { throw Harness.Failure.noMetal }
        RPEngineFeatureFlags.mlsMeshWarp = true
        defer { RPEngineFeatureFlags.mlsMeshWarp = false }
        let warp = try MLSMeshWarp(context: context, pixelFormat: .rgba32Float)

        let controlURLs = try FileManager.default
            .contentsOfDirectory(at: paths.control, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !controlURLs.isEmpty else {
            throw Harness.Failure.missing(
                "control/*.json in \(paths.control.path) — run `s3harness controlpoints` first")
        }

        var rows: [[String: Any]] = []
        var handleCounts: Set<Int> = []
        for url in controlURLs {
            let file = try JSONDecoder().decode(ControlPointFile.self, from: Data(contentsOf: url))
            handleCounts.insert(file.source.count)

            var row: [String: Any] = [
                "image": file.image,
                "full_size": [file.imageWidth, file.imageHeight],
                "megapixels": Double(file.imageWidth * file.imageHeight) / 1e6,
                "control_points": file.source.count,
                "face_width_px": file.faceWidth,
                "max_handle_displacement_px": file.maxDisplacementPx,
            ]

            let longEdge = Double(max(file.imageWidth, file.imageHeight))
            let previewScale = 2048.0 / longEdge
            let resolutions: [(String, Double)] = [
                ("preview_2048px", previewScale), ("full_24mp", 1.0),
            ]
            for (label, scale) in resolutions {
                let control = file.scaled(by: scale)
                let imageSize = CGSize(
                    width: (Double(file.imageWidth) * scale).rounded(),
                    height: (Double(file.imageHeight) * scale).rounded())
                var perResolution: [String: Any] = [
                    "image_size": [Int(imageSize.width), Int(imageSize.height)],
                ]
                for grid in grids {
                    for variant in MLSDeformation.Variant.allCases {
                        let options = MLSDeformation.Options(
                            variant: variant, alpha: 2.0, gridWidth: grid, gridHeight: grid)
                        let error = try compare(
                            context: context, warp: warp, control: control, options: options,
                            imageSize: imageSize)
                        perResolution["grid=\(grid) \(variant.rawValue)"] = [
                            "max_error_px": error.max,
                            "mean_error_px": error.mean,
                            "max_error_over_face_width": error.max / (file.faceWidth * scale),
                            "max_error_over_long_edge": error.max
                                / max(Double(imageSize.width), Double(imageSize.height)),
                        ]
                    }
                }
                row[label] = perResolution
            }
            rows.append(row)
            print("mlsgpu \(file.image) handles=\(file.source.count)")
        }

        // One number per configuration, worst over the frames — the average is
        // not the number to quote when the question is "do the two agree".
        var summary: [String: Any] = [:]
        for resolution in ["preview_2048px", "full_24mp"] {
            var perResolution: [String: Any] = [:]
            for grid in grids {
                for variant in MLSDeformation.Variant.allCases {
                    let key = "grid=\(grid) \(variant.rawValue)"
                    let maxima = rows.compactMap {
                        (($0[resolution] as? [String: Any])?[key] as? [String: Any])?["max_error_px"]
                            as? Double
                    }
                    let means = rows.compactMap {
                        (($0[resolution] as? [String: Any])?[key] as? [String: Any])?[
                            "mean_error_px"] as? Double
                    }
                    let relative = rows.compactMap {
                        (($0[resolution] as? [String: Any])?[key] as? [String: Any])?[
                            "max_error_over_face_width"] as? Double
                    }
                    let worstAbsolute: Double = maxima.max() ?? 0
                    let worstRelative: Double = relative.max() ?? 0
                    perResolution[key] = [
                        "max_error_px_worst_frame": worstAbsolute,
                        "max_error_px_mean_over_frames": Harness.mean(maxima),
                        "mean_error_px_mean_over_frames": Harness.mean(means),
                        "max_error_over_face_width_worst_frame": worstRelative,
                        "frames": maxima.count,
                    ]
                }
            }
            summary[resolution] = perResolution
        }

        // The headline: the worst disagreement anywhere in the measurement, and
        // the worst at the two configurations Phase 2 is actually told to use.
        func worst(_ resolution: String, _ keys: [String]) -> Double {
            let table = summary[resolution] as? [String: Any] ?? [:]
            return keys.compactMap {
                (table[$0] as? [String: Any])?["max_error_px_worst_frame"] as? Double
            }.max() ?? 0
        }
        let previewKeys = MLSDeformation.Variant.allCases.map { "grid=65 \($0.rawValue)" }
        let exportKeys = MLSDeformation.Variant.allCases.map { "grid=129 \($0.rawValue)" }
        let everyKey = grids.flatMap { g in
            MLSDeformation.Variant.allCases.map { "grid=\(g) \($0.rawValue)" }
        }

        try Harness.write(
            [
                "what":
                    "Max |GPU − CPU| for f(v) evaluated on the warp lattice: the float32 Metal "
                    + "kernel rp_mls_grid against MLSDeformation.grid in Double, same handles, "
                    + "same lattice, same alpha. Two independent transcriptions of the same "
                    + "closed form, so this is a correctness check, not an approximation cost.",
                "handles":
                    "The real face-reshape control points from `s3harness controlpoints` "
                    + "(RPVision/S1 478-point mesh on the full-resolution a6300 frame): "
                    + "face-oval slim + two eye rings + 16 border anchors.",
                "control_point_counts": handleCounts.sorted(),
                "alpha": 2.0,
                "environment": Harness.environment,
                "headline": [
                    "worst_max_error_px_any_configuration": max(
                        worst("preview_2048px", everyKey), worst("full_24mp", everyKey)),
                    "worst_max_error_px_preview_grid65": worst("preview_2048px", previewKeys),
                    "worst_max_error_px_export_grid129": worst("full_24mp", exportKeys),
                ],
                "summary": summary,
                "images": rows,
            ] as [String: Any],
            to: paths.results.appendingPathComponent("mls_gpu_vs_cpu.json"))
    }

    /// Runs the GPU solve and the `Double` solve for one configuration and
    /// returns the distance between the two lattices.
    static func compare(
        context: MetalContext, warp: MLSMeshWarp, control: MLSDeformation.ControlPoints,
        options: MLSDeformation.Options, imageSize: CGSize
    ) throws -> (max: Double, mean: Double) {
        let resources = try warp.makeResources(imageSize: imageSize, options: options)
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw Harness.Failure.noMetal
        }
        try warp.encodeGridSolve(
            into: commandBuffer, resources: resources, control: control, options: options,
            imageSize: imageSize)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let gpu = warp.readDeformedGrid(resources)
        let cpu = MLSDeformation.grid(control: control, options: options, imageSize: imageSize)
        var worst = 0.0
        var total = 0.0
        for i in 0..<min(gpu.count, cpu.count) {
            let d = hypot(gpu[i].x - cpu[i].x, gpu[i].y - cpu[i].y)
            worst = max(worst, d)
            total += d
        }
        return (worst, total / Double(max(1, cpu.count)))
    }
}
