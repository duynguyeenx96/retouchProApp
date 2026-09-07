import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import RPVision

enum BenchStats {
    static let iterations = 60
    static let warmup = 10

    static func median(_ xs: [Double]) -> Double { percentile(xs, 0.5) }

    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        let sorted = xs.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * q)))
        return sorted[index]
    }
}

/// Speed measurement for spike S1.
///
/// It lives in `FaceLandmark478ModelTests`, which is `.serialized`, because
/// `RPVisionFeatureFlags` is process-global: a sibling suite flipping the flag back
/// to its default mid-run would break this test.
///
/// Prints one `RPBENCH ` line that `Scripts/bench-s1.sh` scrapes into
/// `Research/bench/`, and drops the same JSON in the process temporary directory.
///
/// The plan's bar is < 40 ms/face on a real iPad A-series. The iOS Simulator has no
/// Neural Engine and executes on the host Mac, so its number is a *floor*, not the
/// device number — see Research/spikes/S1-landmark/S1-landmark.md.
extension FaceLandmark478ModelTests {
    @Test("Measures ms/face for crop + inference")
    func benchmark() throws {
        let modelURL = try #require(SpikeResources.model, "spike model resource missing")
        let cropURL = try #require(SpikeResources.faceCrop)
        let cropImage = try #require(SpikeResources.image(at: cropURL))
        RPVisionFeatureFlags.faceLandmarks478 = true
        defer { RPVisionFeatureFlags.faceLandmarks478 = false }

        var byUnits: [String: [String: Double]] = [:]
        let configurations: [(String, MLComputeUnits)] = [
            ("all", .all), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly),
        ]
        let crop = FaceCrop(center: CGPoint(x: 128, y: 128), side: 256, rotation: 0)

        for (label, units) in configurations {
            let model = try FaceLandmark478Model(url: modelURL, computeUnits: units)
            let renderer = FaceCropRenderer()
            let buffer = try renderer.render(cropImage, crop: crop)
            for _ in 0..<BenchStats.warmup { _ = try model.predict(crop: buffer) }

            var inference: [Double] = []
            for _ in 0..<BenchStats.iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try model.predict(crop: buffer)
                inference.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            var full: [Double] = []
            for _ in 0..<BenchStats.iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try model.predict(crop: try renderer.render(cropImage, crop: crop))
                full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            byUnits[label] = [
                "inference_median_ms": BenchStats.median(inference),
                "inference_mean_ms": inference.reduce(0, +) / Double(inference.count),
                "inference_p95_ms": BenchStats.percentile(inference, 0.95),
                "crop_plus_inference_median_ms": BenchStats.median(full),
                "crop_plus_inference_p95_ms": BenchStats.percentile(full, 0.95),
            ]
        }

        var report: [String: Any] = [
            "suite": "S1 landmark 478",
            "iterations": BenchStats.iterations,
            "compute_units": byUnits,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        #if targetEnvironment(simulator)
            report["environment"] = "iOS Simulator (no Neural Engine, executes on the host Mac)"
            report["is_real_device"] = false
        #elseif os(iOS)
            report["environment"] = "iOS/iPadOS device"
            report["is_real_device"] = true
        #else
            report["environment"] = "macOS host"
            report["is_real_device"] = true
        #endif

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH \(String(decoding: data, as: UTF8.self))")
        try? data.write(
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent("s1-landmark-bench.json"))

        // Not a pass/fail gate: the plan's 40 ms bar is for real iPad A-series
        // hardware, which this environment may not have. Recorded, not asserted.
        let best = byUnits.values.map { $0["crop_plus_inference_median_ms"] ?? .infinity }.min() ?? 0
        #expect(best > 0)
    }
}
