import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import RPVision

/// Speed measurement for spike S2.
///
/// Prints one `RPBENCH-S2 ` line that `Scripts/bench-s2.sh` scrapes into
/// `Research/bench/`, so the number filed there is always the number the test
/// measured. It lives in `FaceParsingModelTests`, which is `.serialized`, because
/// `RPVisionFeatureFlags` is process-global.
///
/// The plan's bar is < 150 ms/image on a real iPhone. The iOS Simulator has no
/// Neural Engine and runs on the host Mac, so its figure is a plausibility check,
/// not the verdict — see Research/spikes/S2-face-parsing/S2-face-parsing.md §6.
extension FaceParsingModelTests {
    /// A Debug test bundle makes the label-decode loop ~30x slower than the shipping
    /// build, so the configuration has to travel with the number.
    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    @Test("Measures ms/image for resize + inference")
    func benchmark() throws {
        let modelURL = try #require(SpikeS2Resources.model, "spike S2 model missing")
        let faceURL = try #require(SpikeS2Resources.face)
        let faceImage = try #require(SpikeS2Resources.image(at: faceURL))
        RPVisionFeatureFlags.faceParsing19 = true
        defer { RPVisionFeatureFlags.faceParsing19 = false }

        // Fewer iterations than S1: this model is ~10x the work per run.
        let warmup = 5
        let iterations = 25

        var byUnits: [String: [String: Double]] = [:]
        let configurations: [(String, MLComputeUnits)] = [
            ("all", .all), ("cpuAndNeuralEngine", .cpuAndNeuralEngine), ("cpuOnly", .cpuOnly),
        ]

        for (label, units) in configurations {
            let model = try FaceParsingModel(url: modelURL, computeUnits: units)
            let renderer = FaceParsingRenderer()
            let buffer = try renderer.render(faceImage)
            for _ in 0..<warmup { _ = try model.predict(image: buffer) }

            var inference: [Double] = []
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try model.predict(image: buffer)
                inference.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            var full: [Double] = []
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try model.predict(image: try renderer.render(faceImage))
                full.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            byUnits[label] = [
                "inference_median_ms": BenchStats.median(inference),
                "inference_mean_ms": inference.reduce(0, +) / Double(inference.count),
                "inference_p95_ms": BenchStats.percentile(inference, 0.95),
                "resize_plus_inference_median_ms": BenchStats.median(full),
                "resize_plus_inference_p95_ms": BenchStats.percentile(full, 0.95),
            ]
        }

        // How much of the above is reading the 262 144-element output rather than
        // running the network. It is a plain Swift loop, so it is ~30x slower in a
        // Debug build than in Release and would otherwise be mistaken for model
        // time (measured on this Mac: the whole predict is 5.8 ms in a release
        // binary and 42 ms in a Debug test bundle).
        let side = FaceParsingModel.inputSide
        let sample = try MLMultiArray(shape: [1, side as NSNumber, side as NSNumber],
                                      dataType: .int32)
        for i in 0..<(side * side) { sample[i] = NSNumber(value: Int32(i % 19)) }
        for _ in 0..<warmup { _ = try FaceParsingModel.decode(labels: sample) }
        var decode: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try FaceParsingModel.decode(labels: sample)
            decode.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        var report: [String: Any] = [
            "suite": "S2 face parsing 19 (BiSeNet 512)",
            "iterations": iterations,
            "input_side": side,
            "compute_units": byUnits,
            "label_decode_median_ms": BenchStats.median(decode),
            "build_configuration": Self.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "plan_bar_ms": 150,
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
        print("RPBENCH-S2 \(String(decoding: data, as: UTF8.self))")
        try? data.write(
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent("s2-face-parsing-bench.json"))

        // Recorded, not asserted: the 150 ms bar is for real iPhone hardware, which
        // this environment does not have.
        let best = byUnits.values.map { $0["resize_plus_inference_median_ms"] ?? .infinity }.min()
        #expect((best ?? 0) > 0)
    }
}
