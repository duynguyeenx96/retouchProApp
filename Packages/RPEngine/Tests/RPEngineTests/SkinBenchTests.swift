import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — files the "Da" group's numbers.
///
/// One `RPBENCH-P2SKIN ` line containing **both** the golden accuracy figures and
/// the speed figures, scraped by `Scripts/bench-skin.sh` into
/// `Research/bench/p2-skin-*.json`. Same arrangement as `Scripts/bench-s3.sh`:
/// the number filed under `Research/` is always the number a test measured, and
/// nothing is concluded from a screenshot (docs/PLAN.md §5).
///
/// The accuracy half runs on the synthetic fixture and needs nothing from disk.
/// The speed half wants the real Sony a6300 frame spike S3 already uses
/// (`Research/spikes/S3-guided-filter-mls/images/full/`, gitignored, 190 MB); it
/// is skipped, not faked, when that is absent.
///
/// **This is a Mac / iOS-Simulator number.** docs/PLAN.md §3's bars (≥ 30 fps at
/// a 2048 px preview, < 8 s for a 24 MP export) are stated for an iPhone, and no
/// device is attached — the same limitation S1, S2, S3 and `FaceAnalyzer` all
/// record. `is_real_device` in the JSON says which it is.
///
/// In the Simulator, read `wall_*_ms` and ignore `gpu_median_ms`: the Simulator
/// reports `MTLCommandBuffer.gpuStartTime/gpuEndTime` as ~0.08 ms for a 24 MP
/// render, which is not a GPU time. Both are recorded so the discrepancy is
/// visible in the file rather than hidden by picking one.
@Suite("Phase 2 skin bench", .serialized)
struct SkinBenchTests {
    static var spikeRoot: URL? {
        if let override = ProcessInfo.processInfo.environment["RP_S3_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let root = url.appendingPathComponent("Research/spikes/S3-guided-filter-mls")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// The face width spike S3's harness measured on the same frame, so the blur
    /// radii the bench prices are the radii a real edit would use.
    struct ControlPoints: Decodable {
        var image: String
        var imageWidth: Int
        var imageHeight: Int
        var faceWidth: Double
    }

    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    @Test("Files the Da group's golden PSNR and ms/frame")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P2SKIN-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }

        var report: [String: Any] = [
            "suite": "Phase 2 Da (skin) slider group",
            "build_configuration": Self.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "guided_subsample": RenderQuality.preview.guidedSubsample,
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

        if let speed = try Self.speedNumbers(context: context) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] =
                "Research/spikes/S3-guided-filter-mls/{images/full,control} not present"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P2SKIN \(String(decoding: data, as: UTF8.self))")

        // The golden bar is the plan's and is asserted; the speed bars are for an
        // iPhone and are recorded only.
        let golden = try #require(report["golden"] as? [String: Any])
        let endToEnd = try #require(golden["end_to_end_psnr_db"] as? Double)
        #expect(endToEnd >= 45, "end-to-end PSNR \(endToEnd) dB")
    }

    // MARK: - Accuracy

    static func goldenNumbers(context: MetalContext) throws -> [String: Any] {
        let width = SkinRenderNodeTests.width
        let height = SkinRenderNodeTests.height
        let source = SkinRenderNodeTests.source
        let face = SkinRenderNodeTests.face
        let sliders = SkinRenderNodeTests.allSliders

        let node = try SkinRenderNode(context: context)
        let output = try SkinRenderNodeTests.runNode(
            node, context: context, request: SkinRenderNodeTests.request(sliders))
        guard let layers = node.debugLayers() else { return [:] }
        let base = try SkinRenderNodeTests.layerPixels(layers.base, context: context)
        let low = try SkinRenderNodeTests.layerPixels(layers.low, context: context)
        let mask = try SkinRenderNodeTests.readR8(layers.mask, queue: context.commandQueue)

        let compositeReference = SkinReference.composite(
            source: source, base: base, low: low, mask: mask,
            amounts: SkinReference.Amounts(sliders))
        let endToEndReference = SkinReference.renderNode(
            source: source, width: width, height: height, faces: [face], sliders: sliders,
            subsample: RenderQuality.preview.guidedSubsample)
        let maskReference = SkinReference.rasterisedMask(
            faces: [face], width: width, height: height)
        var maskWorst = 0.0
        for i in 0..<maskReference.count {
            maskWorst = max(maskWorst, abs(maskReference[i] - mask[i]))
        }

        var perSlider: [String: Double] = [:]
        for (name, single) in Self.singleSliderCases {
            let one = try SkinRenderNodeTests.runNode(
                node, context: context, request: SkinRenderNodeTests.request(single))
            guard let l = node.debugLayers() else { continue }
            let b = try SkinRenderNodeTests.layerPixels(l.base, context: context)
            let lo = try SkinRenderNodeTests.layerPixels(l.low, context: context)
            let m = try SkinRenderNodeTests.readR8(l.mask, queue: context.commandQueue)
            let reference = SkinReference.composite(
                source: source, base: b, low: lo, mask: m,
                amounts: SkinReference.Amounts(single))
            perSlider[name] = SpikeTextureIO.psnr(reference, one)
        }

        return [
            "fixture": "synthetic ramp + step + noise, \(width)x\(height), one 64px elliptical skin mask",
            "reference": "SkinReference (Double CPU, written from the spec)",
            "mask_max_abs_diff": maskWorst,
            "composite_psnr_db": SpikeTextureIO.psnr(compositeReference, output),
            "end_to_end_psnr_db": SpikeTextureIO.psnr(endToEndReference, output),
            "end_to_end_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(
                endToEndReference, output),
            "per_slider_psnr_db": perSlider,
        ]
    }

    static let singleSliderCases: [(String, SkinSliders)] = [
        ("smooth", SkinSliders(smooth: 100)),
        ("keepTexture", SkinSliders(smooth: 100, keepTexture: 60)),
        ("evenTone", SkinSliders(evenTone: 100)),
        ("redness", SkinSliders(redness: 100)),
        ("shine", SkinSliders(shine: 100)),
        ("brighten", SkinSliders(brighten: 100)),
        ("darkCircle", SkinSliders(darkCircle: 100)),
        ("wrinkle", SkinSliders(wrinkle: 100)),
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
            ControlPoints.self, from: Data(contentsOf: controlURL))
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
            let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded)
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
        let node = try SkinRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        // A mask framed like a real parsing crop (1.87 x face width) around the
        // centre of the frame. The mask *content* does not change what the node
        // costs — every pass is full-resolution and unconditional — but the face
        // width does, because both blur radii are fractions of it.
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
                .skin: RenderMask(
                    width: maskSide, height: maskSide,
                    values: SkinReference.ellipseMask(width: maskSide, height: maskSide),
                    maskToImage: region)
            ])

        var state = EditState()
        SkinRenderNodeTests.allSliders.write(into: &state)
        let request = RenderRequest(editState: state, faces: [face], quality: quality)
        let zeroRequest = RenderRequest(editState: EditState(), faces: [face], quality: quality)

        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

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

        let all = try time(request)
        let zero = try time(zeroRequest)
        let smoothOnly = try time({
            var s = EditState()
            SkinSliders(smooth: 70, keepTexture: 30).write(into: &s)
            return RenderRequest(editState: s, faces: [face], quality: quality)
        }())

        var result: [String: Any] = [
            "smooth_radius_px": SkinRenderNode.smoothRadius(faceWidth: faceWidth),
            "low_radius_px": SkinRenderNode.lowRadius(faceWidth: faceWidth),
            "iterations": iterations,
            "all_sliders": all,
            "smooth_only": smoothOnly,
            "all_sliders_at_zero": zero,
            "node_bytes": node.allocatedBytes,
        ]
        result["all_sliders_fps"] = 1000.0 / max(1e-9, all["wall_median_ms"] ?? 1)
        result["smooth_only_fps"] = 1000.0 / max(1e-9, smoothOnly["wall_median_ms"] ?? 1)
        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }
}
