import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — files the "Mặt" (warp) group's numbers.
///
/// One `RPBENCH-P2WARP ` line containing the geometry checks, the three accuracy
/// levels and the speed figures, scraped by `Scripts/bench-warp.sh` into
/// `Research/bench/p2-warp-*.json`. Same arrangement as `Scripts/bench-skin.sh`:
/// the number filed under `Research/` is always the number a test measured, and
/// nothing is concluded from a screenshot (docs/PLAN.md §5).
///
/// Unlike the Da group's bench, **every** number here needs a fixture: a reshape
/// slider has nothing to measure without a face. The three it uses are
///
/// * `Research/phase2/face-analyzer/results/a6300/twostage.json` — 11 real
///   478-point meshes (docs/ADR-0008);
/// * `Research/spikes/S1-landmark/a6300/images/raw/*.jpg` — the 2691² frames
///   those meshes were measured on;
/// * `Research/spikes/S3-guided-filter-mls/images/full/*.jpg` +
///   `Research/spikes/S1-landmark/a6300/manifest.json` — the 24 MP originals and
///   the crop offset that maps a mesh into them. The crop was cut at native
///   resolution with no resampling, so the 24 MP handles are the **real** ones
///   and not an invented rescale.
///
/// Each half is skipped, not faked, when its fixture is absent.
///
/// **This is a Mac / iOS-Simulator number.** docs/PLAN.md §3's bars are stated
/// for an iPhone and no device is attached — the same limitation S1, S2, S3,
/// `FaceAnalyzer` and the Da group all record. `is_real_device` says which.
///
/// In the Simulator, read `wall_*_ms` and ignore `gpu_median_ms` (ADR-0009).
@Suite("Phase 2 warp bench", .serialized)
struct WarpBenchTests {
    static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    @Test("Files the Mặt group's geometry, accuracy and ms/frame")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P2WARP-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        var report: [String: Any] = [
            "suite": "Phase 2 Mặt (face reshape) slider group",
            "build_configuration": Self.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "mesh_grid": [
                "preview": RenderQuality.preview.meshGrid,
                "export": RenderQuality.export.meshGrid,
            ],
            "mls": [
                "variant": FaceReshape.variant.rawValue,
                "alpha": FaceReshape.alpha,
                "border_anchors_per_edge": FaceReshape.borderAnchorsPerEdge,
            ],
            "sliders": FaceSliders.Key.all,
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

        let meshes = FaceLandmarkFixtures.a6300
        report["meshes"] = meshes.count
        if meshes.isEmpty {
            report["skipped"] = "Research/phase2/face-analyzer/results/a6300/twostage.json absent"
        } else {
            report["geometry"] = Self.geometryNumbers(meshes)
            report["handles"] = Self.handleNumbers(meshes)
            report["accuracy"] = try Self.accuracyNumbers(context: context, meshes: meshes)
        }
        if let rendered = try Self.renderedGolden(context: context) {
            report["rendered_golden"] = rendered
        } else {
            report["rendered_golden_skipped"] =
                "Research/spikes/S1-landmark/a6300/images/raw absent"
        }
        if let speed = try Self.speedNumbers(context: context, meshes: meshes) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] = "a6300 image fixtures absent"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P2WARP \(String(decoding: data, as: UTF8.self))")

        // The golden bar is the plan's and is asserted; the speed bars are for an
        // iPhone and are recorded only.
        if let rendered = report["rendered_golden"] as? [String: Any],
            let psnr = rendered["psnr_db"] as? Double
        {
            #expect(psnr >= 45, "rendered PSNR \(psnr) dB")
        }
    }

    // MARK: - Geometry

    static func geometryNumbers(_ meshes: [FaceLandmarkFixtures.Mesh]) -> [String: Any] {
        var ovalEnclosure: [Double] = []
        var eyeSeparation: [Double] = []
        var noseWidth: [Double] = []
        var noseTLow = Double.infinity
        var noseTHigh = -Double.infinity
        var noseMidline = 0.0
        var allStraddle = true
        var innerLipInside = true
        var irisInside = true
        for mesh in meshes {
            guard
                let report = FaceMeshGeometry.measure(
                    landmarks: mesh.landmarks, faceWidth: mesh.faceWidth)
            else { continue }
            ovalEnclosure.append(report.ovalEnclosedFraction)
            eyeSeparation.append(report.eyeSeparationOverWidth)
            noseWidth.append(report.noseWidthOverFaceWidth)
            noseTLow = min(noseTLow, report.noseTRange.lowerBound)
            noseTHigh = max(noseTHigh, report.noseTRange.upperBound)
            noseMidline = max(noseMidline, report.noseMidlineMaxOffset)
            allStraddle = allStraddle && report.alaeStraddleTheMidline
                && report.eyesStraddleTheMidline
            innerLipInside = innerLipInside
                && report.innerLipPointsInsideOuter == FaceMesh.lipsInner.count
            irisInside = irisInside
                && report.irisPointsInsideTheirEye == FaceMesh.irisPoints.count
        }
        return [
            "oval_encloses_fraction_min": ovalEnclosure.min() ?? 0,
            "eye_separation_over_face_width": [
                eyeSeparation.min() ?? 0, eyeSeparation.max() ?? 0,
            ],
            "nose_width_over_face_width": [noseWidth.min() ?? 0, noseWidth.max() ?? 0],
            "nose_t_range": [noseTLow, noseTHigh],
            "nose_midline_max_offset_over_face_width": noseMidline,
            "alae_and_eyes_straddle_the_midline": allStraddle,
            "inner_lip_ring_inside_outer_on_every_frame": innerLipInside,
            "iris_points_inside_their_eye_on_every_frame": irisInside,
            "regions_disjoint": Set(FaceMesh.allHandleIndices).count
                == FaceMesh.allHandleIndices.count,
        ]
    }

    // MARK: - Handles

    /// How far each slider actually moves the face at 100, as a fraction of face
    /// width, measured on the real meshes. This is the magnitude table
    /// `FaceReshape`'s constants declare, verified rather than restated.
    static func handleNumbers(_ meshes: [FaceLandmarkFixtures.Mesh]) -> [String: Any] {
        var perSlider: [String: Any] = [:]
        for key in FaceSliders.Key.all {
            var state = EditState()
            state.setSlider(key, in: EditState.SectionKey.face, to: 100)
            let sliders = FaceSliders(state)
            var worst = 0.0
            var handleCount = 0
            var movedCount = 0
            for mesh in meshes {
                let handles = FaceReshape.handles(
                    landmarks: mesh.landmarks, faceWidth: mesh.faceWidth, sliders: sliders)
                handleCount = max(handleCount, handles.count)
                movedCount = max(movedCount, handles.filter { $0.displacement > 0 }.count)
                for handle in handles {
                    worst = max(worst, Double(handle.displacement / mesh.faceWidth))
                }
            }
            perSlider[key] = [
                "handles": handleCount, "moved": movedCount,
                "max_displacement_over_face_width": worst,
            ]
        }
        var all = 0.0
        var allHandles = 0
        for mesh in meshes {
            let handles = FaceReshape.handles(
                landmarks: mesh.landmarks, faceWidth: mesh.faceWidth,
                sliders: FaceReshapeTests.allSliders)
            allHandles = max(allHandles, handles.count)
            for handle in handles { all = max(all, Double(handle.displacement / mesh.faceWidth)) }
        }
        return [
            "per_slider_at_100": perSlider,
            "all_sliders_mid_handles": allHandles,
            "all_sliders_mid_max_displacement_over_face_width": all,
        ]
    }

    // MARK: - Accuracy levels 1 and 2

    static func accuracyNumbers(context: MetalContext, meshes: [FaceLandmarkFixtures.Mesh])
        throws -> [String: Any]
    {
        let node = try WarpRenderNode(context: context)
        var out: [String: Any] = [
            "reference": "MLSDeformation (Double CPU) grid + bilinear lattice interpolation",
            "sliders": "all fifteen at the mid values FaceReshapeTests.allSliders uses",
        ]
        for quality in RenderQuality.allCases {
            var gridError = 0.0
            var roundTripMax = 0.0
            var roundTripMaxFraction = 0.0
            var roundTripMeanSum = 0.0
            var worstImage = ""
            for mesh in meshes {
                let result = try WarpAccuracy.measure(
                    node: node, context: context, mesh: mesh, quality: quality,
                    sliders: FaceReshapeTests.allSliders)
                gridError = max(gridError, result.maxGridErrorPx)
                if result.maxRoundTripPx > roundTripMax {
                    roundTripMax = result.maxRoundTripPx
                    worstImage = result.image
                }
                roundTripMaxFraction = max(
                    roundTripMaxFraction, result.maxRoundTripOverFaceWidth)
                roundTripMeanSum += result.meanRoundTripPx
            }
            out[quality.rawValue] = [
                "grid": quality.meshGrid,
                "gpu_vs_cpu_grid_max_px": gridError,
                "landmark_round_trip_max_px": roundTripMax,
                "landmark_round_trip_max_over_face_width": roundTripMaxFraction,
                "landmark_round_trip_mean_px": roundTripMeanSum / Double(meshes.count),
                "worst_image": worstImage,
            ]
        }
        node.releaseIntermediates()
        return out
    }

    // MARK: - Accuracy level 3

    static func renderedGolden(context: MetalContext) throws -> [String: Any]? {
        guard let fixture = try WarpImageFixture.load(side: 640) else { return nil }
        let graph = try RenderGraph.standard(context: context)
        var state = EditState()
        FaceReshapeTests.allSliders.write(into: &state)
        let request = RenderRequest(
            editState: state, faces: [fixture.face], quality: .preview)
        let (output, _) = try graph.renderPixels(
            fixture.pixels, width: fixture.width, height: fixture.height, request: request)
        guard
            let built = FaceReshape.controlPoints(
                faces: [fixture.face], sliders: FaceReshapeTests.allSliders,
                imageSize: CGSize(width: fixture.width, height: fixture.height))
        else { return nil }
        let reference = WarpReference.render(
            source: fixture.pixels, width: fixture.width, height: fixture.height,
            control: built.control, options: FaceReshape.options(for: .preview))
        return [
            "image": fixture.image,
            "size": [fixture.width, fixture.height],
            "reference": "WarpReference (Double CPU: MLSDeformation grid + scanline mesh raster)",
            "handles": built.handles.count,
            "moved_handles": built.movedHandleCount,
            "max_displacement_px": Double(built.maxDisplacement),
            "psnr_db": SpikeTextureIO.psnr(reference, output),
            "max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(reference, output),
            "change_vs_source_max_abs": SpikeTextureIO.maxAbsoluteDifference(
                fixture.pixels, output),
        ]
    }

    // MARK: - Speed

    static func speedNumbers(context: MetalContext, meshes: [FaceLandmarkFixtures.Mesh])
        throws -> [String: Any]?
    {
        let name = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        guard let mesh = meshes.first(where: { $0.image.hasPrefix(name) }) ?? meshes.first,
            let cropURL = FaceLandmarkFixtures.cropImageURL(mesh)
        else { return nil }

        var out: [String: Any] = ["image": mesh.image]

        // Preview: the crop at 2048 px long edge, which is the operating point
        // docs/PLAN.md §1.4 fixes for the canvas.
        let cropImage = try SpikeS3BenchTests.loadUpright(cropURL)
        let previewScale = 2048 / max(mesh.imageSize.width, mesh.imageSize.height)
        let previewMesh = FaceLandmarkFixtures.scaled(mesh, by: previewScale)
        let previewWidth = Int(previewMesh.imageSize.width)
        let previewHeight = Int(previewMesh.imageSize.height)
        let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
            of: cropImage, space: .sRGBEncoded, width: previewWidth, height: previewHeight)
        out["preview"] = try measureOne(
            context: context, pixels: previewPixels,
            width: previewWidth, height: previewHeight,
            face: FaceLandmarkFixtures.renderInput(previewMesh),
            quality: .preview, iterations: 20)
        out["preview_size"] = [previewWidth, previewHeight]
        out["preview_face_width_px"] = Double(previewMesh.faceWidth)

        // Export: the real 24 MP frame, with the mesh moved into it by the
        // manifest's crop offset (native-resolution crop, no resampling).
        if ProcessInfo.processInfo.environment["RP_SKIP_FULL_RES"] == nil,
            let full = FaceLandmarkFixtures.inFullFrame(mesh),
            let fullURL = FaceLandmarkFixtures.fullFrameURL(mesh)
        {
            let fullImage = try SpikeS3BenchTests.loadUpright(fullURL)
            if fullImage.width == Int(full.imageSize.width),
                fullImage.height == Int(full.imageSize.height)
            {
                let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(
                    of: fullImage, space: .sRGBEncoded)
                out["full"] = try measureOne(
                    context: context, pixels: fullPixels,
                    width: fullImage.width, height: fullImage.height,
                    face: FaceLandmarkFixtures.renderInput(full),
                    quality: .export, iterations: 5)
                out["full_size"] = [fullImage.width, fullImage.height]
                out["megapixels"] = Double(fullImage.width * fullImage.height) / 1e6
                out["full_face_width_px"] = Double(full.faceWidth)
            } else {
                out["full_skipped"] =
                    "manifest upright_size \(full.imageSize) != decoded "
                    + "\(fullImage.width)x\(fullImage.height)"
            }
        }
        return out
    }

    static func measureOne(
        context: MetalContext, pixels: [Float], width: Int, height: Int,
        face: FaceRenderInput, quality: RenderQuality, iterations: Int
    ) throws -> [String: Any] {
        let node = try WarpRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        var allState = EditState()
        FaceReshapeTests.allSliders.write(into: &allState)
        var oneState = EditState()
        FaceSliders(slim: 60).write(into: &oneState)

        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

        func time(_ state: EditState) throws -> [String: Double] {
            let request = RenderRequest(editState: state, faces: [face], quality: quality)
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

        let all = try time(allState)
        let one = try time(oneState)
        let zero = try time(EditState())

        var handles = 0
        if let built = FaceReshape.controlPoints(
            faces: [face], sliders: FaceReshapeTests.allSliders,
            imageSize: CGSize(width: width, height: height))
        {
            handles = built.control.count
        }

        var result: [String: Any] = [
            "grid": quality.meshGrid,
            "control_points_including_border": handles,
            "iterations": iterations,
            "all_sliders": all,
            "slim_only": one,
            "all_sliders_at_zero": zero,
            "node_bytes": node.allocatedBytes,
        ]
        result["all_sliders_fps"] = 1000.0 / max(1e-9, all["wall_median_ms"] ?? 1)
        result["slim_only_fps"] = 1000.0 / max(1e-9, one["wall_median_ms"] ?? 1)
        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }
}
