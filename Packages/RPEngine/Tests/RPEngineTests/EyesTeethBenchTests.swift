import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — files the "Mắt / Răng" group's numbers.
///
/// One `RPBENCH-P2EYESTEETH ` line containing the golden accuracy figures, the
/// **selectivity** figures and the speed figures, scraped by
/// `Scripts/bench-eyes-teeth.sh` into `Research/bench/p2-eyes-teeth-*.json`. Same
/// arrangement as `Scripts/bench-skin.sh` and `Scripts/bench-warp.sh`: the number
/// filed under `Research/` is always the number a test measured, and nothing is
/// concluded from a screenshot (docs/PLAN.md §5).
///
/// The accuracy and selectivity halves run on the synthetic portrait and need
/// nothing from disk. The speed half wants the real Sony a6300 frame spike S3
/// already uses (`Research/spikes/S3-guided-filter-mls/images/full/`, gitignored,
/// 190 MB); it is skipped, not faked, when that is absent.
///
/// **This is a Mac / iOS-Simulator number.** docs/PLAN.md §3's bars (≥ 30 fps at
/// a 2048 px preview, < 8 s for a 24 MP export) are stated for an iPhone, and no
/// device is attached — the same limitation S1, S2, S3, `FaceAnalyzer`, the Da
/// group and the Mặt group all record. `is_real_device` in the JSON says which
/// it is.
///
/// In the Simulator, read `wall_*_ms` and ignore `gpu_median_ms`: the Simulator
/// reports `MTLCommandBuffer.gpuStartTime/gpuEndTime` as ~0.08 ms for a 24 MP
/// render, which is not a GPU time. Both are recorded so the discrepancy is
/// visible in the file rather than hidden by picking one.
@Suite("Phase 2 eyes/teeth bench", .serialized)
struct EyesTeethBenchTests {
    static var spikeRoot: URL? { SkinBenchTests.spikeRoot }

    @Test("Files the Mắt/Răng group's golden PSNR, selectivity and ms/frame")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P2EYESTEETH-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var report: [String: Any] = [
            "suite": "Phase 2 Mắt/Răng (eyes/teeth) slider group",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "shader_source_files": MetalContext.shaderSources.count,
            "guided_subsample": RenderQuality.preview.guidedSubsample,
            "local_mean_radius_fraction": EyesTeethRenderNode.localMeanRadiusFraction,
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
        report["selectivity"] = try Self.selectivityNumbers(context: context)

        if let speed = try Self.speedNumbers(context: context) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] =
                "Research/spikes/S3-guided-filter-mls/{images/full,control} not present"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P2EYESTEETH \(String(decoding: data, as: UTF8.self))")

        // The golden bar is the plan's and is asserted; the speed bars are for an
        // iPhone and are recorded only.
        let golden = try #require(report["golden"] as? [String: Any])
        let endToEnd = try #require(golden["end_to_end_psnr_db"] as? Double)
        #expect(endToEnd >= 45, "end-to-end PSNR \(endToEnd) dB")
    }

    // MARK: - Accuracy

    static func goldenNumbers(context: MetalContext) throws -> [String: Any] {
        let width = EyesTeethRenderNodeTests.width
        let height = EyesTeethRenderNodeTests.height
        let source = EyesTeethRenderNodeTests.source
        let face = EyesTeethRenderNodeTests.face
        let sliders = EyesTeethRenderNodeTests.allSliders

        let node = try EyesTeethRenderNode(context: context)
        let output = try EyesTeethRenderNodeTests.runNode(
            node, context: context, request: EyesTeethRenderNodeTests.request(sliders))
        let compositeReference = try EyesTeethRenderNodeTests.compositeReference(
            node: node, context: context, sliders: sliders)
        let endToEndReference = EyesTeethReference.renderNode(
            source: source, width: width, height: height, faces: [face], sliders: sliders,
            subsample: RenderQuality.preview.guidedSubsample)

        var maskWorst: [String: Double] = [:]
        if let layers = node.debugLayers() {
            for (kind, texture) in [(RenderMaskKind.eyes, layers.eyes), (.mouth, layers.mouth)] {
                guard let texture else { continue }
                let measured = try SkinRenderNodeTests.readR8(
                    texture, queue: context.commandQueue)
                let reference = EyesTeethReference.rasterisedMask(
                    faces: [face], kind: kind, width: width, height: height)
                var worst = 0.0
                for i in 0..<reference.count {
                    worst = max(worst, abs(reference[i] - measured[i]))
                }
                maskWorst[kind.rawValue] = worst
            }
        }

        var perSlider: [String: Double] = [:]
        for (name, single) in Self.singleSliderCases {
            let one = try EyesTeethRenderNodeTests.runNode(
                node, context: context, request: EyesTeethRenderNodeTests.request(single))
            let reference = try EyesTeethRenderNodeTests.compositeReference(
                node: node, context: context, sliders: single)
            perSlider[name] = SpikeTextureIO.psnr(reference, one)
        }

        return [
            "fixture":
                "synthetic portrait \(width)x\(height): skin + 2 eyes (sclera/iris/pupil) + open mouth (teeth/gums), one 64px feathered parsing crop",
            "reference": "EyesTeethReference (Double CPU, written from the spec)",
            "mask_max_abs_diff": maskWorst,
            "composite_psnr_db": SpikeTextureIO.psnr(compositeReference, output),
            "end_to_end_psnr_db": SpikeTextureIO.psnr(endToEndReference, output),
            "end_to_end_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(
                endToEndReference, output),
            "per_slider_psnr_db": perSlider,
        ]
    }

    static let singleSliderCases: [(String, EyesTeethSliders)] = [
        ("eyeBrighten", EyesTeethSliders(eyeBrighten: 100)),
        ("scleraWhiten", EyesTeethSliders(scleraWhiten: 100)),
        ("eyeDefinition", EyesTeethSliders(eyeDefinition: 100)),
        ("teethWhiten", EyesTeethSliders(teethWhiten: 100)),
    ]

    // MARK: - Selectivity

    /// Mean |Δ| per region, per slider. **This is the claim the PSNR cannot
    /// make**: the PSNR says the GPU computed the documented formula, and these
    /// numbers say the formula lands on teeth rather than gums and on sclera
    /// rather than iris. Neither of them says the result is pretty — nobody has
    /// looked at a render yet (see `EyesTeethRenderNode`'s known limitations).
    static func selectivityNumbers(context: MetalContext) throws -> [String: Any] {
        let portrait = EyesTeethRenderNodeTests.portrait
        let node = try EyesTeethRenderNode(context: context)
        var out: [String: Any] = [
            "definition":
                "mean absolute RGB change per known region of the synthetic portrait, slider at 100",
            "region_pixel_counts": Dictionary(
                uniqueKeysWithValues: Self.regions.map { region in
                    (String(describing: region), portrait.regions.count { $0 == region })
                }),
        ]
        for (name, sliders) in Self.singleSliderCases {
            let output = try EyesTeethRenderNodeTests.runNode(
                node, context: context, request: EyesTeethRenderNodeTests.request(sliders))
            var per: [String: Double] = [:]
            for region in Self.regions {
                per[String(describing: region)] = EyesTeethReference.meanChange(
                    portrait.pixels, output, regions: portrait.regions, region)
            }
            out[name] = per
        }
        return out
    }

    static let regions: [EyesTeethReference.Portrait.Region] = [
        .skin, .sclera, .iris, .pupil, .teeth, .gums,
    ]

    // MARK: - Speed

    static func speedNumbers(context: MetalContext) throws -> [String: Any]? {
        guard let root = spikeRoot else { return nil }
        let imageName = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        let imageURL = root.appendingPathComponent("images/full/\(imageName).jpg")
        let controlURL = root.appendingPathComponent("control/\(imageName).json")
        guard FileManager.default.fileExists(atPath: imageURL.path),
            FileManager.default.fileExists(atPath: controlURL.path)
        else { return nil }

        let control = try JSONDecoder().decode(
            SkinBenchTests.ControlPoints.self, from: Data(contentsOf: controlURL))
        let image = try SpikeS3BenchTests.loadUpright(imageURL)

        var out: [String: Any] = [
            "image": imageName,
            "full_size": [image.width, image.height],
            "megapixels": Double(image.width * image.height) / 1e6,
            "face_width_px_full": control.faceWidth,
        ]

        // Preview, 2048 px long edge.
        let scale = 2048.0 / Double(max(image.width, image.height))
        let previewWidth = Int((Double(image.width) * scale).rounded())
        let previewHeight = Int((Double(image.height) * scale).rounded())
        let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: previewWidth, height: previewHeight)
        out["preview"] = try measureOne(
            context: context, pixels: previewPixels, width: previewWidth, height: previewHeight,
            faceWidth: CGFloat(control.faceWidth * scale), quality: .preview, iterations: 20)
        out["preview_size"] = [previewWidth, previewHeight]

        // Full resolution.
        if ProcessInfo.processInfo.environment["RP_SKIP_FULL_RES"] == nil {
            let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
            out["full"] = try measureOne(
                context: context, pixels: fullPixels, width: image.width, height: image.height,
                faceWidth: CGFloat(control.faceWidth), quality: .export, iterations: 5)
        }
        return out
    }

    static func measureOne(
        context: MetalContext, pixels: [Float], width: Int, height: Int,
        faceWidth: CGFloat, quality: RenderQuality, iterations: Int
    ) throws -> [String: Any] {
        let node = try EyesTeethRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        // Masks framed like a real parsing crop (1.87 x face width, the
        // CelebAMask-HQ framing `ParsedFace.region` carries) around the centre of
        // the frame, at the 512 px crop size the real model emits. The mask
        // *content* does not change what the node costs — every pass is
        // full-resolution and unconditional — but the face width does, because
        // the local-mean radius is a fraction of it.
        let maskSide = 512
        let side = faceWidth * 1.87
        let region = CGAffineTransform.identity
            .translatedBy(x: CGFloat(width) * 0.5, y: CGFloat(height) * 0.45)
            .rotated(by: 0.1)
            .scaledBy(x: side / CGFloat(maskSide), y: side / CGFloat(maskSide))
            .translatedBy(x: -CGFloat(maskSide) / 2, y: -CGFloat(maskSide) / 2)
        let face = FaceRenderInput(
            faceWidth: faceWidth,
            masks: [
                .eyes: RenderMask(
                    width: maskSide, height: maskSide,
                    values: EyesTeethReference.eyeCoverage(side: maskSide),
                    maskToImage: region),
                .mouth: RenderMask(
                    width: maskSide, height: maskSide,
                    values: EyesTeethReference.mouthCoverage(side: maskSide),
                    maskToImage: region),
            ])

        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

        func request(_ sliders: EyesTeethSliders) -> RenderRequest {
            var state = EditState()
            sliders.write(into: &state)
            return RenderRequest(editState: state, faces: [face], quality: quality)
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

        let all = try time(request(EyesTeethRenderNodeTests.allSliders))
        let allBytes = node.allocatedBytes
        let zero = try time(request(EyesTeethSliders()))
        node.releaseIntermediates()
        // "Sáng mắt" alone is the cheap path: no local-mean layer, no guided
        // filter intermediates, just the two mask rasterisations and one pass.
        let brightenOnly = try time(request(EyesTeethSliders(eyeBrighten: 70)))
        let brightenBytes = node.allocatedBytes

        var result: [String: Any] = [
            "local_mean_radius_px": EyesTeethRenderNode.localMeanRadius(faceWidth: faceWidth),
            "iterations": iterations,
            "all_sliders": all,
            "brighten_only": brightenOnly,
            "all_sliders_at_zero": zero,
            "node_bytes_all_sliders": allBytes,
            "node_bytes_brighten_only": brightenBytes,
        ]
        result["all_sliders_fps"] = 1000.0 / max(1e-9, all["wall_median_ms"] ?? 1)
        result["brighten_only_fps"] = 1000.0 / max(1e-9, brightenOnly["wall_median_ms"] ?? 1)
        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }
}
