import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// 2026-09-23 — the numbers behind "the brush is stored as strokes"
/// (docs/ADR-0019 addendum 2026-09-23, docs/ADR-0025). One `RPBENCH-P6STROKES `
/// JSON line, filed as `Research/bench/p6-manual-mask-strokes-macos.json`.
///
/// * `open_replay` — what reopening a painted shot now costs: the whole stroke
///   list replayed onto the 2048 px preview (`ManualMaskSession.replaceStrokes`).
///   ADR-0019 §7 measured the same 19-stroke replay at ~405–427 ms with
///   whole-mask dispatch; the bounding-box dispatch that landed with this change
///   is what this number checks.
/// * `export_raster` — rasterising the same list at 6000×4000, the export path.
/// * `edge_fidelity` — the brush edge in the exported file when rasterised at
///   export size, against the previous approach (a 2048 px mask upsampled
///   bilinearly, as `rp_manual_mask_modulate` samples it): 10–90 % rise distance
///   across the stroke edge, in export pixels, for a hard and the default brush.
@Suite("Phase 6.1 brush strokes bench", .serialized)
struct ManualMaskStrokeBenchTests {
    static let preview = (width: 2048, height: 1365)
    static let export = (width: 6000, height: 4000)

    @Test("Files the stroke replay, export raster and edge-fidelity numbers")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P6STROKES-SKIP no Metal device")
            return
        }
        var report: [String: Any] = [
            "suite": "Phase 6.1 brush stored as strokes (2026-09-23)",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "preview_pixels": [Self.preview.width, Self.preview.height],
            "export_pixels": [Self.export.width, Self.export.height],
            "adr": "docs/ADR-0019-manual-mask-brush.md (addendum 2026-09-23), docs/ADR-0025",
        ]
        try ManualMaskTests.withManualMask {
            let size = CGSize(width: Self.preview.width, height: Self.preview.height)
            // ADR-0019 §7's deep case, exactly: 20 diagonal strokes, radius 48.
            let deep = Self.deepHistory().map { $0.normalized(imageSize: size) }
            // A heavier, realistic one: 20 long curved strokes with the shipping
            // default brush (64 px, hardness 0.5) — ManualMaskBenchTests' drag.
            let long = (0..<20).map { index -> ManualMaskStroke in
                var stroke = BrushStroke(radius: 64, hardness: 0.5, flow: 1, mode: .add)
                stroke.points = ManualMaskBenchTests.dragPath().map {
                    BrushPoint(
                        location: CGPoint(
                            x: $0.location.x, y: $0.location.y + Double(index * 20) - 200),
                        pressure: $0.pressure)
                }
                return stroke.normalized(imageSize: size)
            }

            report["open_replay"] = try [
                "adr0019_deep_19_strokes_ms": Self.replayMilliseconds(
                    Array(deep.prefix(19)), context: context),
                "adr0019_deep_19_strokes_before_ms": 405.29,
                "adr0019_deep_19_strokes_before_source":
                    "ManualMaskBenchTests undo.replay_ms on this Mac, Release, before the "
                    + "bounding-box change (Research/bench/p6-manual-mask-macos.json filed 426.9)",
                "long_20_strokes_ms": Self.replayMilliseconds(long, context: context),
                "long_20_strokes_stamps": long.reduce(0) {
                    $0 + BrushStroke($1, imageSize: size).stamps.count
                },
            ]
            report["export_raster"] = try [
                "long_20_strokes_6000x4000_ms": Self.rasterMilliseconds(long, context: context),
                "deep_19_strokes_6000x4000_ms": Self.rasterMilliseconds(
                    Array(deep.prefix(19)), context: context),
                "gpu_bytes": Self.export.width * Self.export.height * 2,
            ]
            report["edge_fidelity"] = try [
                "hard_brush_h1": Self.edgeFidelity(hardness: 1, context: context),
                "default_brush_h05": Self.edgeFidelity(hardness: 0.5, context: context),
                "metric":
                    "10-90% rise distance across the stroke's lower edge, in export pixels, "
                    + "down one column; 'upsampled' = the 2048 px raster sampled bilinearly at "
                    + "export pixel centres (what rp_manual_mask_modulate did with the old PNG)",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6STROKES \(String(decoding: data, as: UTF8.self))")
    }

    static func deepHistory() -> [BrushStroke] {
        (0..<20).map { index in
            let offset = Double(index) * 12
            return BrushStroke(
                radius: 48, hardness: 0.5, flow: 1, mode: .add,
                points: [
                    BrushPoint(location: CGPoint(x: 200 + offset, y: 200 + offset)),
                    BrushPoint(location: CGPoint(x: 1600 + offset, y: 1000 + offset)),
                ])
        }
    }

    /// Median of 5 `replaceStrokes` on one 2048 px session (one warm-up).
    static func replayMilliseconds(_ strokes: [ManualMaskStroke], context: MetalContext) throws
        -> Double
    {
        let session = try ManualMaskSession(
            context: context, width: preview.width, height: preview.height)
        let size = CGSize(width: preview.width, height: preview.height)
        let brush = strokes.map { BrushStroke($0, imageSize: size) }
        try session.replaceStrokes(brush)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            try session.replaceStrokes(brush)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return samples.sorted()[samples.count / 2]
    }

    /// One export-size rasterisation, including the texture allocation — what
    /// `ExportMaskResolver` pays per exported photo.
    static func rasterMilliseconds(_ strokes: [ManualMaskStroke], context: MetalContext) throws
        -> Double
    {
        _ = try ManualMaskSession.rasterize(strokes, width: 64, height: 64, context: context)
        let start = CFAbsoluteTimeGetCurrent()
        _ = try ManualMaskSession.rasterize(
            strokes, width: export.width, height: export.height, context: context)
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// One horizontal stroke; compares its lower edge in the export raster
    /// against the preview raster upsampled.
    static func edgeFidelity(hardness: Double, context: MetalContext) throws -> [String: Any] {
        let stroke = ManualMaskStroke(
            radius: 64.0 / 2048, hardness: hardness, flow: 1, mode: .add,
            points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)])
        let small = try ManualMaskSession.rasterize(
            [stroke], width: preview.width, height: preview.height, context: context
        ).readValues()
        let big = try ManualMaskSession.rasterize(
            [stroke], width: export.width, height: export.height, context: context
        ).readValues()

        let column = export.width / 2
        let sx = Double(preview.width) / Double(export.width)
        let sy = Double(preview.height) / Double(export.height)
        func previewSample(_ x: Int, _ y: Int) -> Double {
            // GPU bilinear with texel centres at i + 0.5, clamp to edge.
            let u = (Double(x) + 0.5) * sx - 0.5
            let v = (Double(y) + 0.5) * sy - 0.5
            let x0 = Int(u.rounded(.down))
            let y0 = Int(v.rounded(.down))
            let fx = u - Double(x0)
            let fy = v - Double(y0)
            func at(_ i: Int, _ j: Int) -> Double {
                let ci = min(max(i, 0), preview.width - 1)
                let cj = min(max(j, 0), preview.height - 1)
                return Double(small[cj * preview.width + ci]) / 255
            }
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
        // Scan down from the stroke centre to where it falls to 0.
        let centreY = export.height / 2
        let radiusExport = stroke.radius * Double(max(export.width, export.height))
        let endY = min(export.height - 1, centreY + Int(radiusExport * 1.5))
        var native: [Double] = []
        var upsampled: [Double] = []
        for y in centreY...endY {
            native.append(Double(big[y * export.width + column]) / 255)
            upsampled.append(previewSample(column, y))
        }
        func rise(_ profile: [Double]) -> Double {
            // Falling edge: first index below 90 % and first below 10 %,
            // interpolated to sub-pixel.
            func crossing(_ level: Double) -> Double {
                for i in 1..<profile.count where profile[i] < level && profile[i - 1] >= level {
                    let t = (profile[i - 1] - level) / (profile[i - 1] - profile[i])
                    return Double(i - 1) + t
                }
                return .nan
            }
            return crossing(0.1) - crossing(0.9)
        }
        var bandDiff = 0.0
        var bandCount = 0
        var worst = 0.0
        for i in native.indices where native[i] > 0.01 && native[i] < 0.99 || upsampled[i] > 0.01 && upsampled[i] < 0.99 {
            let d = abs(native[i] - upsampled[i])
            bandDiff += d
            bandCount += 1
            worst = max(worst, d)
        }
        return [
            "hardness": hardness,
            "radius_export_px": radiusExport,
            "rise_10_90_export_px_native": rise(native),
            "rise_10_90_export_px_upsampled_from_2048": rise(upsampled),
            "edge_band_mean_abs_diff": bandCount > 0 ? bandDiff / Double(bandCount) : 0,
            "edge_band_worst_abs_diff": worst,
            "edge_band_pixels": bandCount,
        ]
    }
}
