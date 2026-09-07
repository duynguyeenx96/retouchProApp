import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — files the "Color" group's numbers.
///
/// One `RPBENCH-P2COLOR ` line containing the golden accuracy figures, the
/// **behavioural** figures, the speed figures and the **Core Image control**,
/// scraped by `Scripts/bench-color.sh` into `Research/bench/p2-color-*.json`.
/// Same arrangement as the other three groups' bench scripts: the number filed
/// under `Research/` is always the number a test measured, and nothing is
/// concluded from a screenshot (docs/PLAN.md §5).
///
/// The accuracy and behaviour halves run on the synthetic chart and need nothing
/// from disk. The speed half wants the real Sony a6300 frame spike S3 already
/// uses (`Research/spikes/S3-guided-filter-mls/images/full/`, gitignored,
/// 190 MB); it is skipped, not faked, when that is absent.
///
/// **This is a Mac / iOS-Simulator number.** docs/PLAN.md §3's bars (≥ 30 fps at
/// a 2048 px preview, < 8 s for a 24 MP export) are stated for an iPhone, and no
/// device is attached — the same limitation S1, S2, S3, `FaceAnalyzer` and the
/// Da / Mặt / Mắt-Răng groups all record. `is_real_device` in the JSON says which
/// it is.
///
/// In the Simulator, read `wall_*_ms` and ignore `gpu_median_ms`: the Simulator
/// reports `MTLCommandBuffer.gpuStartTime/gpuEndTime` as ~0.08 ms for a 24 MP
/// render, which is not a GPU time.
@Suite("Phase 2 color bench", .serialized)
struct ColorBenchTests {
    static var spikeRoot: URL? { SkinBenchTests.spikeRoot }

    @Test("Files the Color group's golden PSNR, behaviour, ms/frame and the CI control")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P2COLOR-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        var report: [String: Any] = [
            "suite": "Phase 2 Color slider group",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "shader_source_files": MetalContext.shaderSources.count,
            "slider_count": ColorSliders.Key.all.count,
            "analysis_grid_width": ColorRenderNode.analysisWidth,
            "curve_lut_entries": ColorToneCurve.size,
            "pixel_space": RenderQuality.preview.pixelSpace.rawValue,
            "plan_bars": ["golden_psnr_db": 45, "preview_2048_fps": 30, "export_24mp_seconds": 8],
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

        report["golden"] = try Self.goldenNumbers(context: context)
        report["behaviour"] = try Self.behaviourNumbers(context: context)

        if let speed = try Self.speedNumbers(context: context) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] =
                "Research/spikes/S3-guided-filter-mls/{images/full,control} not present"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P2COLOR \(String(decoding: data, as: UTF8.self))")

        // The golden bar is the plan's and is asserted; the speed bars are for an
        // iPhone and are recorded only.
        let golden = try #require(report["golden"] as? [String: Any])
        let endToEnd = try #require(golden["end_to_end_psnr_db"] as? Double)
        #expect(endToEnd >= 45, "end-to-end PSNR \(endToEnd) dB")
    }

    /// `JSONSerialization` refuses a non-finite `Double`, and a per-slider PSNR
    /// legitimately comes out infinite when the GPU and the `Double` reference
    /// round to the same float32 on a fixture whose affected pixels are all one
    /// flat colour. Recorded as the string "inf" rather than clipped to a
    /// made-up number.
    static func jsonPSNR(_ value: Double) -> Any { value.isFinite ? value : "inf" }

    // MARK: - Accuracy

    static func goldenNumbers(context: MetalContext) throws -> [String: Any] {
        let width = ColorRenderNodeTests.width
        let height = ColorRenderNodeTests.height
        let source = ColorRenderNodeTests.source
        let sliders = ColorRenderNodeTests.allSliders

        let node = try ColorRenderNode(context: context)
        let output = try ColorRenderNodeTests.runNode(
            node, context: context, request: ColorRenderNodeTests.request(sliders))
        let compositeReference = try ColorRenderNodeTests.compositeReference(
            node: node, context: context, sliders: sliders)
        let endToEndReference = ColorReference.renderNode(
            source: source, width: width, height: height, sliders: sliders,
            curveTable: node.curveTable)

        var perSlider: [String: Any] = [:]
        for (name, single) in ColorRenderNodeTests.singleSliderCases {
            let one = try ColorRenderNodeTests.runNode(
                node, context: context, request: ColorRenderNodeTests.request(single))
            let reference = try ColorRenderNodeTests.compositeReference(
                node: node, context: context, sliders: single)
            perSlider[name] = jsonPSNR(SpikeTextureIO.psnr(reference, one))
        }

        // The identity claim, measured rather than asserted only in a test name.
        let zero = try ColorRenderNodeTests.runNode(
            node, context: context, request: ColorRenderNodeTests.request(ColorSliders()))

        let table = ColorToneCurve.table()
        var lutWorst = 0.0
        for i in 0...20000 {
            let x = Double(i) / 20000
            for channel in 0..<3 {
                lutWorst = max(
                    lutWorst,
                    abs(
                        ColorToneCurve.value(x, channel: channel)
                            - ColorToneCurve.lookup(table, x, channel: channel)))
            }
        }

        return [
            "fixture":
                "synthetic grading chart \(width)x\(height): luminance ramp + 8 hue patches + skin patch + bright/dark discs",
            "reference": "ColorReference (Double CPU, written from the spec)",
            "composite_psnr_db": jsonPSNR(SpikeTextureIO.psnr(compositeReference, output)),
            "end_to_end_psnr_db": SpikeTextureIO.psnr(endToEndReference, output),
            "end_to_end_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(
                endToEndReference, output),
            "per_slider_psnr_db": perSlider,
            "all_sliders_zero_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(source, zero),
            "curve_lut_max_error": lutWorst,
        ]
    }

    // MARK: - Behaviour

    /// The claims a PSNR cannot make: that each slider moves the part of the
    /// picture its name refers to. The PSNR only says the GPU computed the
    /// documented formula; a Highlights slider that acted on the shadows would
    /// score exactly as well.
    static func behaviourNumbers(context: MetalContext) throws -> [String: Any] {
        let node = try ColorRenderNode(context: context)
        let chart = ColorRenderNodeTests.chart
        let source = ColorRenderNodeTests.source

        func run(_ sliders: ColorSliders) throws -> [Float] {
            try ColorRenderNodeTests.runNode(
                node, context: context, request: ColorRenderNodeTests.request(sliders))
        }

        let highlights = try run(ColorSliders(highlights: 100))
        let shadows = try run(ColorSliders(shadows: 100))
        let dnb = try run(ColorSliders(autoDodgeBurn: 100))
        var red = ColorSliders()
        red[.red] = 100
        let hslRed = try run(red)

        return [
            "definition":
                "mean signed luminance change on the ramp's two ends, and mean |Δ| per labelled region",
            "highlights_100": [
                "bright_end": ColorRenderNodeTests.rampLumaChange(
                    highlights, xFraction: 0.75...0.95),
                "dark_end": ColorRenderNodeTests.rampLumaChange(highlights, xFraction: 0.05...0.25),
            ],
            "shadows_100": [
                "bright_end": ColorRenderNodeTests.rampLumaChange(shadows, xFraction: 0.75...0.95),
                "dark_end": ColorRenderNodeTests.rampLumaChange(shadows, xFraction: 0.05...0.25),
            ],
            "auto_dodge_burn_100": [
                "bright_disc": ColorReference.meanLuminanceChange(
                    source, dnb, regions: chart.regions, .brightDisc),
                "dark_disc": ColorReference.meanLuminanceChange(
                    source, dnb, regions: chart.regions, .darkDisc),
                "flat_ramp": ColorRenderNodeTests.rampLumaChange(dnb, xFraction: 0.35...0.65),
            ],
            "hsl_red_100": [
                "red_patch": ColorReference.meanChange(
                    source, hslRed, regions: chart.regions, .red),
                "green_patch": ColorReference.meanChange(
                    source, hslRed, regions: chart.regions, .green),
                "aqua_patch": ColorReference.meanChange(
                    source, hslRed, regions: chart.regions, .aqua),
                "skin_patch": ColorReference.meanChange(
                    source, hslRed, regions: chart.regions, .skin),
            ],
        ]
    }

    // MARK: - Speed

    static func speedNumbers(context: MetalContext) throws -> [String: Any]? {
        guard let root = spikeRoot else { return nil }
        let imageName = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        let imageURL = root.appendingPathComponent("images/full/\(imageName).jpg")
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
        let image = try SpikeS3BenchTests.loadUpright(imageURL)

        var out: [String: Any] = [
            "image": imageName,
            "full_size": [image.width, image.height],
            "megapixels": Double(image.width * image.height) / 1e6,
        ]

        let scale = 2048.0 / Double(max(image.width, image.height))
        let previewWidth = Int((Double(image.width) * scale).rounded())
        let previewHeight = Int((Double(image.height) * scale).rounded())
        let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: previewWidth, height: previewHeight)
        out["preview"] = try measureOne(
            context: context, pixels: previewPixels, width: previewWidth, height: previewHeight,
            quality: .preview, iterations: 20)
        out["preview_size"] = [previewWidth, previewHeight]

        if ProcessInfo.processInfo.environment["RP_SKIP_FULL_RES"] == nil {
            let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
            out["full"] = try measureOne(
                context: context, pixels: fullPixels, width: image.width, height: image.height,
                quality: .export, iterations: 5)
        }
        return out
    }

    static func measureOne(
        context: MetalContext, pixels: [Float], width: Int, height: Int,
        quality: RenderQuality, iterations: Int
    ) throws -> [String: Any] {
        let node = try ColorRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

        func request(_ sliders: ColorSliders) -> RenderRequest {
            var state = EditState()
            sliders.write(into: &state)
            return RenderRequest(editState: state, faces: [], quality: quality)
        }
        func time(_ request: RenderRequest) throws -> [String: Double] {
            for _ in 0..<2 {
                _ = try graph.render(source: source, destination: destination, request: request)
            }
            var wall: [Double] = []
            var gpu: [Double] = []
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                let report = try graph.render(
                    source: source, destination: destination, request: request)
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                gpu.append(report.gpuMilliseconds)
            }
            return [
                "wall_median_ms": S3BenchStats.median(wall),
                "wall_p95_ms": S3BenchStats.percentile(wall, 0.95),
                "gpu_median_ms": S3BenchStats.median(gpu),
            ]
        }

        let all = try time(request(ColorRenderNodeTests.allSliders))
        let allBytes = node.allocatedBytes
        let zero = try time(request(ColorSliders()))
        node.releaseIntermediates()
        // The cheap path: no Auto D&B, so no analysis pyramid and no extra
        // dispatches — one pass over the frame.
        let toneOnly = try time(request(ColorSliders(exposure: 40, contrast: 30, curves: 50)))
        let toneBytes = node.allocatedBytes

        var result: [String: Any] = [
            "iterations": iterations,
            "analysis_size": {
                let size = ColorRenderNode.analysisSize(width: width, height: height)
                return [size.width, size.height]
            }(),
            "all_sliders": all,
            "tone_only": toneOnly,
            "all_sliders_at_zero": zero,
            "node_bytes_all_sliders": allBytes,
            "node_bytes_tone_only": toneBytes,
        ]
        result["all_sliders_fps"] = 1000.0 / max(1e-9, all["wall_median_ms"] ?? 1)
        result["tone_only_fps"] = 1000.0 / max(1e-9, toneOnly["wall_median_ms"] ?? 1)

        // The control for docs/ADR-0012's "Metal, not a CIFilter chain" decision.
        if let ci = coreImageControl(
            context: context, source: source, destination: destination, iterations: iterations)
        {
            result["core_image_control"] = ci
        }

        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }

    // MARK: - The Core Image control

    /// A Core Image chain doing **9 of this group's 18 sliders** (contrast and
    /// saturation share one `CIColorControls` call; temperature and tint share
    /// one `CITemperatureAndTint` call), timed on the same textures, as the
    /// control for the CIFilter-vs-Metal decision (docs/ADR-0012, docs/PLAN.md
    /// §1.3 "Core Image + kernel").
    ///
    /// It is a **lower bound** on what a CIFilter implementation would cost, and
    /// the JSON says so: there is no `CIFilter` for per-hue-band saturation and
    /// none for the two-scale Auto D&B, so those remaining nine sliders would
    /// need a `CIColorKernel`/`CIKernel` on top of what is timed here.
    ///
    /// Not a shipped code path. Nothing in RPEngine imports Core Image; this
    /// lives in the test target precisely so the measurement exists without the
    /// dependency.
    static func coreImageControl(
        context: MetalContext, source: any MTLTexture, destination: any MTLTexture,
        iterations: Int
    ) -> [String: Any]? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(
            mtlDevice: context.device,
            options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        guard
            let input = CIImage(
                mtlTexture: source, options: [.colorSpace: space])
        else { return nil }

        func chain() -> CIImage {
            var image = input
            // exposure
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.3])
            // white balance, both axes
            image = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5200, y: 12),
                ])
            // highlights + shadows
            image = image.applyingFilter(
                "CIHighlightShadowAdjust",
                parameters: ["inputHighlightAmount": 0.45, "inputShadowAmount": 0.45])
            // contrast + saturation
            image = image.applyingFilter(
                "CIColorControls",
                parameters: ["inputContrast": 1.2, "inputSaturation": 1.2])
            // vibrance
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.5])
            // curves
            image = image.applyingFilter(
                "CIToneCurve",
                parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0.03),
                    "inputPoint1": CIVector(x: 0.25, y: 0.24),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: 0.78),
                    "inputPoint4": CIVector(x: 1, y: 0.98),
                ])
            return image
        }

        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        func render() -> Bool {
            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return false }
            ciContext.render(
                chain(), to: destination, commandBuffer: commandBuffer, bounds: bounds,
                colorSpace: space)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return commandBuffer.error == nil
        }

        // Warm up: the first render compiles CI's own kernels, which is exactly
        // the cost RenderGraph.prewarm() exists to keep off the interaction path
        // and which a CIFilter implementation would reintroduce.
        let coldStart = DispatchTime.now().uptimeNanoseconds
        guard render() else { return ["failed": "CIContext.render produced an error"] }
        let coldMs = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1e6
        _ = render()

        var wall: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            guard render() else { return ["failed": "CIContext.render produced an error"] }
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return [
            "note":
                "CIExposureAdjust + CITemperatureAndTint + CIHighlightShadowAdjust + CIColorControls + CIVibrance + CIToneCurve — 9 of the group's 18 sliders (exposure, wbTemperature, wbTint, highlights, shadows, contrast, saturation, vibrance, curves). No CIFilter exists for per-hue-band HSL or for the two-scale Auto D&B, so the remaining 9 sliders would need a `CIColorKernel`/`CIKernel` on top of this — this timing is a LOWER BOUND on a full CIFilter implementation.",
            "sliders_covered": 9,
            "first_render_ms": coldMs,
            "wall_median_ms": S3BenchStats.median(wall),
            "wall_p95_ms": S3BenchStats.percentile(wall, 0.95),
        ]
    }
}
