import CoreGraphics
import Foundation
import Testing

@testable import RPVision

/// Phase 6 §6.1 — files what the "Khoá nền" subject mask costs, per quality level.
///
/// One `RPBENCH-P6BGLOCK ` line that `Scripts/bench-background-lock.sh` scrapes
/// into `Research/bench/p6-background-lock-*.json`, the same arrangement as every
/// other bench in this repo: the number filed under `Research/` is always the
/// number a test measured (docs/PLAN.md §5).
///
/// It measures two things at once, because the timing on its own would not be
/// enough to choose a quality level:
///
/// * **ms/request** at a 2048 px preview and on the full 24 MP frame, for
///   `.fast` / `.balanced` / `.accurate`. The plan quotes Apple's advice
///   (`.fast` for interactive, `.accurate` "has a noticeable latency") and then
///   refuses to take it on faith.
/// * **where the mask lands**: mean coverage inside a face rectangle found by a
///   *separate* Vision request, against mean coverage in the frame's corners.
///   A cheaper quality level that is 3x faster but no longer covers the subject
///   is not a cheaper quality level.
///
/// **This is a Mac number, and only a Mac number.** No iPhone figure exists,
/// exactly as for S1, S2, S3, `FaceAnalyzer` and all four Phase 2 slider groups
/// (docs/ADR-0007 … ADR-0016) — and unlike those, there is no Simulator figure
/// either: performing this request on the iOS Simulator fails outright with
/// `com.apple.Vision 9 "Could not create inference context"`, so the Simulator run
/// files `supported: false` and the reason instead of a millisecond figure. See
/// ``PersonSegmenter/unsupportedReason()``.
///
/// `.serialized` because `RPVisionFeatureFlags` is process-global.
@Suite("Phase 6 background lock bench", .serialized)
struct PersonSegmentationBenchTests {
    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    static let previewLongEdge = 2048
    static let previewImages = 3
    static let previewWarmup = 2
    static let previewIterations = 8
    static let fullImages = 1
    static let fullWarmup = 1
    static let fullIterations = 3

    @Test("Files ms/request and subject coverage for each quality level")
    func measure() throws {
        // The flag goes through `RPVisionTestFlags` rather than being set inline:
        // `PersonSegmenterTests.flagGatesConstruction` turns the same process-global
        // flag off, `.serialized` does not order two suites against each other, and
        // this bench then fails halfway through with "feature is disabled" — which
        // is how the full macOS suite failed while each suite passed alone.
        try RPVisionTestFlags.withPersonSegmentation { try Self.measureBody() }
    }

    private static func measureBody() throws {
        var report: [String: Any] = [
            "suite": "Phase 6 §6.1 Khoá nền (background lock) — VNGeneratePersonSegmentationRequest",
            "build_configuration": Self.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "request_revision": PersonSegmenter.requestRevision,
            "preview_long_edge": Self.previewLongEdge,
            "plan_bars": ["preview_2048_fps": 30, "export_24mp_seconds": 8],
            "note":
                "Mask is produced once per shot and cached, not per frame; the fps bar "
                + "applies to the render, not to this request.",
        ]
        #if targetEnvironment(simulator)
            report["environment"] = "iOS Simulator (no Neural Engine, executes on the host Mac)"
            report["is_real_device"] = false
        #elseif os(iOS)
            report["environment"] = "iOS device"
            report["is_real_device"] = true
        #else
            report["environment"] = "macOS host"
            report["is_real_device"] = true
        #endif

        // A platform that cannot perform the request at all is a *result*, not a
        // skip: it is the answer to "can the iOS Simulator stand in for the iPhone
        // number this node still lacks", and it belongs in Research/bench/ where
        // the next person will look. Filed as `supported: false` with the exact
        // Vision error, and the run stays green — the Simulator failing to load a
        // model Apple did not ship for it is not a regression in this code.
        if let reason = PersonSegmenter.unsupportedReason() {
            report["supported"] = false
            report["unsupported_reason"] = reason
            report["quality"] = [String: Any]()
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("RPBENCH-P6BGLOCK \(String(decoding: data, as: UTF8.self))")
            return
        }
        report["supported"] = true

        let previewURLs = BackgroundLockFixtures.imageURLs(limit: Self.previewImages)
        guard !previewURLs.isEmpty else {
            print(
                "RPBENCH-P6BGLOCK-SKIP Research/spikes/S3-guided-filter-mls/images/full not present"
            )
            return
        }
        report["images"] = previewURLs.map { $0.lastPathComponent }

        // Decode + resize once. The decode is ~0.4 s per 24 MP JPEG and is not part
        // of what is being measured.
        var previews: [(name: String, image: CGImage)] = []
        for url in previewURLs {
            guard let full = BackgroundLockFixtures.image(at: url),
                let preview = BackgroundLockFixtures.resized(
                    full, longEdge: Self.previewLongEdge)
            else { continue }
            previews.append((url.lastPathComponent, preview))
        }
        guard let firstPreview = previews.first else {
            print("RPBENCH-P6BGLOCK-SKIP fixtures present but none decoded")
            return
        }
        report["preview_size"] = [firstPreview.image.width, firstPreview.image.height]

        // Face boxes come from a separate Vision request, so the coverage figure is
        // not the mask grading its own homework.
        var faceBoxes: [String: CGRect] = [:]
        for preview in previews {
            if let box = try BackgroundLockFixtures.largestFaceBox(in: preview.image) {
                faceBoxes[preview.name] = box
            }
        }
        report["frames_with_a_detected_face"] = faceBoxes.count

        var byQuality: [String: [String: Any]] = [:]
        for quality in PersonSegmentationQuality.allCases {
            let segmenter = try PersonSegmenter(quality: quality)
            var entry: [String: Any] = [:]

            // --- preview 2048 px
            var previewTimes: [Double] = []
            var maskSize: [Int] = []
            var faceCoverage: [Double] = []
            var cornerCoverage: [Double] = []
            var frameCoverage: [Double] = []
            for preview in previews {
                for _ in 0..<Self.previewWarmup { _ = try segmenter.mask(for: preview.image) }
                for _ in 0..<Self.previewIterations {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try segmenter.mask(for: preview.image)
                    previewTimes.append(
                        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
                guard let mask = try segmenter.mask(for: preview.image) else { continue }
                maskSize = [mask.width, mask.height]
                let frame = CGRect(
                    x: 0, y: 0, width: CGFloat(preview.image.width),
                    height: CGFloat(preview.image.height))
                frameCoverage.append(mask.meanCoverage(inImageRect: frame))
                if let box = faceBoxes[preview.name] {
                    faceCoverage.append(mask.meanCoverage(inImageRect: box))
                }
                let corners = BackgroundLockFixtures.cornerRects(
                    width: preview.image.width, height: preview.image.height)
                cornerCoverage.append(
                    corners.map { mask.meanCoverage(inImageRect: $0) }.reduce(0, +)
                        / Double(corners.count))
            }
            // The `Double` locals are not decoration: inside a `[String: Any]`
            // literal, `xs.min() ?? 0` types the `0` as `Int` and the whole
            // expression as `Any`, which files a JSON number whose type depends on
            // whether the array was empty.
            let previewMin: Double = previewTimes.min() ?? 0
            entry["preview_2048"] = [
                "median_ms": BenchStats.median(previewTimes),
                "p95_ms": BenchStats.percentile(previewTimes, 0.95),
                "min_ms": previewMin,
                "samples": previewTimes.count,
                "images": previews.count,
                "mask_size": maskSize,
            ]
            let faceMin: Double = faceCoverage.min() ?? 0
            let cornerMax: Double = cornerCoverage.max() ?? 0
            entry["subject_coverage_2048"] = [
                "face_box_mean": Self.mean(faceCoverage),
                "face_box_min": faceMin,
                "corners_mean": Self.mean(cornerCoverage),
                "corners_max": cornerMax,
                "frame_mean": Self.mean(frameCoverage),
                "frames": faceCoverage.count,
            ]

            // --- full 24 MP
            if ProcessInfo.processInfo.environment["RP_SKIP_FULL_RES"] == nil,
                let url = BackgroundLockFixtures.imageURLs(limit: Self.fullImages).first,
                let full = BackgroundLockFixtures.image(at: url)
            {
                for _ in 0..<Self.fullWarmup { _ = try segmenter.mask(for: full) }
                var fullTimes: [Double] = []
                var fullMaskSize: [Int] = []
                for _ in 0..<Self.fullIterations {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let mask = try segmenter.mask(for: full)
                    fullTimes.append(
                        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    if let mask { fullMaskSize = [mask.width, mask.height] }
                }
                entry["full_frame"] = [
                    "median_ms": BenchStats.median(fullTimes),
                    "p95_ms": BenchStats.percentile(fullTimes, 0.95),
                    "samples": fullTimes.count,
                    "image": url.lastPathComponent,
                    "image_size": [full.width, full.height],
                    "mask_size": fullMaskSize,
                ]
            } else {
                entry["full_frame_skipped"] = "RP_SKIP_FULL_RES set or fixture missing"
            }

            byQuality[quality.rawValue] = entry
        }
        report["quality"] = byQuality

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6BGLOCK \(String(decoding: data, as: UTF8.self))")

        // Recorded, not asserted: the ms figures are Mac numbers and the plan's
        // bars are for an iPhone — and they move with host load (two runs of this
        // bench on the same Mac gave 5.5/17.2/54.5 and 9.7/21.0/58.8 ms at 2048 px),
        // so asserting on them would be asserting on how busy the machine was.
        // What *is* asserted is the part that does
        // not depend on the hardware — that each quality level produced a mask
        // which actually covers the detected face. A quality level that is fast
        // because it returns nothing would otherwise look like the best one here.
        //
        // The bars differ per quality on purpose, and they are the first
        // measurement's finding rather than a target: `.fast` returns a 256x192
        // mask for a 2048 px preview and covered 0.90 of the face box on average
        // (0.71 on the worst frame), while `.balanced` and `.accurate` are both
        // above 0.99. Holding `.fast` to the same bar would either fail on a
        // machine that is behaving correctly or quietly pretend the three levels
        // are interchangeable.
        let bars: [PersonSegmentationQuality: Double] = [
            .fast: 0.60, .balanced: 0.95, .accurate: 0.95,
        ]
        for quality in PersonSegmentationQuality.allCases {
            let entry = try #require(byQuality[quality.rawValue])
            let coverage = try #require(entry["subject_coverage_2048"] as? [String: Any])
            if let frames = coverage["frames"] as? Int, frames > 0 {
                let faceMean = try #require(coverage["face_box_mean"] as? Double)
                let bar = bars[quality] ?? 0.6
                #expect(
                    faceMean > bar,
                    "\(quality.rawValue) face-box coverage \(faceMean) below \(bar)")
            }
        }
    }

    static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
}
