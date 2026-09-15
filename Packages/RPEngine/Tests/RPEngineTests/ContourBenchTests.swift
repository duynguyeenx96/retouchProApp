import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 — files the "Tạo khối" (Contour) group's numbers.
///
/// One `RPBENCH-P6CONTOUR ` line of JSON, scraped by `Scripts/bench-contour.sh`
/// into `Research/bench/p6-contour-*.json`. Same arrangement as the Phase 2
/// groups' bench scripts: the number filed under `Research/` is always the number
/// a test measured, and nothing is concluded from a screenshot (docs/PLAN.md §5).
///
/// Four claims, deliberately separate, because contour reuses a *measured* step
/// (the dodge/burn LUT, docs/ADR-0012) and adds only a mask:
///
/// * `golden.*` — PSNR against `ColorReference`, the `Double` CPU control,
///   extended with the one new step. Says the GPU evaluates the documented
///   ellipse. Bar: the plan's 45 dB. Runs anywhere.
/// * `selectivity.*` — mean signed luminance change per contour zone and worst
///   |Δ| per **control** zone. Says the cheekbone slider lands on the cheekbone
///   and moves the forehead centre by *exactly* 0 — the thing a PSNR cannot say,
///   because a mask computing the documented falloff in the wrong place scores
///   just as well. Runs anywhere.
/// * `coverage.*` — the fraction of the frame the mask claims. §6.2's whole
///   requirement is "theo mesh, không toàn khung"; this is that, as a number.
///   Runs anywhere.
/// * `speed.*` — ms/frame at a 2048 px preview and at 24 MP on the real a6300
///   frame, with the contour branch off and on, so the **marginal** cost of the
///   eleven lobes is visible rather than buried in the colour grade's cost.
///   Needs the gitignored `Research/` fixtures; skipped, not faked, without them.
///
/// **This is a Mac / iOS-Simulator number** (`is_real_device` says which), the
/// same limitation every earlier bench records. And none of it says the result is
/// *pretty*: every geometric constant in ``ContourMask`` is untuned.
@Suite("Phase 6.2 contour bench", .serialized)
struct ContourBenchTests {
    @Test("Files the Contour group's golden PSNR, selectivity, coverage and ms/frame")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P6CONTOUR-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        var report: [String: Any] = [
            "suite": "Phase 6.2 Contour (Tạo khối) slider group",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "applies_in_node": "ColorRenderNode (rp_color_composite), the existing dodge/burn LUT step",
            "new_kernels": 0,
            "new_landmarks": 0,
            "new_core_ml_models": 0,
            "feature_flag": "RPEngineFeatureFlags.contourSliders (default off)",
            "slider_keys": ContourSliders.Key.all,
            "slider_range": [0, 100],
            "section": EditState.SectionKey.face,
            "mask": Self.maskNumbers(),
            "pixel_space": RenderQuality.preview.pixelSpace.rawValue,
            "plan_bars": ["golden_psnr_db": 45, "preview_2048_fps": 30, "export_24mp_seconds": 8],
        ]
        #if targetEnvironment(simulator)
            report["environment"] = "iOS Simulator (executes on the host Mac's GPU)"
            report["is_real_device"] = false
        #elseif os(iOS)
            report["environment"] = "iOS device"
            report["is_real_device"] = true
        #else
            report["environment"] = "macOS host"
            report["is_real_device"] = true
        #endif

        report["golden"] = try Self.goldenNumbers(context: context)
        report["selectivity"] = try Self.selectivityNumbers(context: context)
        report["coverage"] = Self.coverageNumbers()

        if let speed = try Self.speedNumbers(context: context) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] = "a6300 image/mesh fixtures absent under Research/"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6CONTOUR \(String(decoding: data, as: UTF8.self))")

        // The golden bar is the plan's and is asserted; so is the selectivity
        // claim, because "exactly 0 outside the zone" is the property that makes
        // this a contour and not a grade. The speed bars are for an iPhone and
        // are recorded only.
        let golden = try #require(report["golden"] as? [String: Any])
        let psnr = try #require(golden["contour_psnr_db"] as? Double)
        #expect(psnr >= 45, "contour PSNR \(psnr) dB")
        let selectivity = try #require(report["selectivity"] as? [String: Any])
        for zone in ["cheek_100", "nose_100", "jaw_100"] {
            let entry = try #require(selectivity[zone] as? [String: Any])
            let forehead = try #require(entry["forehead_centre_max_abs"] as? Double)
            #expect(forehead == 0, "\(zone) moved the forehead centre by \(forehead)")
        }
        let coverage = try #require(report["coverage"] as? [String: Any])
        let touched = try #require(coverage["fraction_of_frame_touched"] as? Double)
        #expect(touched < 0.35, "the mask touches \(touched) of the frame")
    }

    // MARK: - Mask shape

    /// What the mask *is*, read out of the production constants rather than
    /// restated here, so this block cannot drift from the code it describes.
    static func maskNumbers() -> [String: Any] {
        let face = ContourFixture.chart.face
        func count(_ sliders: ContourSliders) -> Int {
            ContourMask.lobes(faces: [face], sliders: sliders).count
        }
        return [
            "lobes_per_face": ContourMask.lobesPerFace,
            "max_lobes_uploaded": ContourMask.maxLobes,
            "lobe_stride_bytes": MemoryLayout<ContourLobe>.stride,
            "buffer_bytes": MemoryLayout<ContourLobe>.stride * ContourMask.maxLobes,
            "lobes_by_slider": [
                "cheek": count(ContourSliders(cheek: 100)),
                "nose": count(ContourSliders(nose: 100)),
                "jaw": count(ContourSliders(jaw: 100)),
            ],
            "falloff": "1 - smoothstep(0, 1, r) on the ellipse's normalised radius; 0 outside r = 1",
            "peak_strength_at_100": [
                "cheek_highlight": ContourMask.cheekHighlightStrength,
                "cheek_shadow": ContourMask.cheekShadowStrength,
                "nose": ContourMask.noseStrength,
                "jaw": ContourMask.jawStrength,
            ],
            "half_extents_over_face_width": [
                "cheek_highlight": [
                    ContourMask.cheekHighlightHalf.along, ContourMask.cheekHighlightHalf.across,
                ],
                "cheek_shadow": [
                    ContourMask.cheekShadowHalf.along, ContourMask.cheekShadowHalf.across,
                ],
                "nose_half_width": ContourMask.noseHalfWidth,
                "jaw_half_width": ContourMask.jawHalfWidth,
            ],
            "anchors": [
                "cheek": "tEyeLine/tCheekLine/tMouthLine + FaceMesh.cheekLeft/cheekRight",
                "nose": "tNasion -> tNoseTip (both already computed by FaceReshape)",
                "jaw": "FaceMesh.faceOval, cheek extreme -> chin, 3 segments per side",
            ],
            "constants_are_tuned": false,
        ]
    }

    // MARK: - Accuracy

    static func goldenNumbers(context: MetalContext) throws -> [String: Any] {
        let node = try ColorRenderNode(context: context)
        let source = ContourFixture.chart.pixels

        func psnr(_ sliders: ContourSliders, color: ColorSliders = ColorSliders()) throws
            -> (Double, Double)
        {
            let request = ContourFixture.request(sliders, color: color)
            let output = try ContourFixture.run(node, context: context, request: request)
            let reference = try ContourRenderTests.reference(
                node: node, context: context, request: request)
            return (
                SpikeTextureIO.psnr(reference, output),
                SpikeTextureIO.maxAbsoluteDifference(reference, output)
            )
        }

        let (all, allWorst) = try psnr(ContourRenderTests.allContour)
        let (graded, gradedWorst) = try psnr(
            ContourRenderTests.allContour, color: ColorRenderNodeTests.allSliders)
        var perSlider: [String: Any] = [:]
        for (name, sliders) in [
            ("cheek", ContourSliders(cheek: 100)), ("nose", ContourSliders(nose: 100)),
            ("jaw", ContourSliders(jaw: 100)),
        ] {
            perSlider[name] = ColorBenchTests.jsonPSNR(try psnr(sliders).0)
        }

        // The three default-off claims, as numbers rather than as prose.
        let zeroOutput = try ContourFixture.run(
            node, context: context, request: ContourFixture.request(ContourSliders()))
        var facelessState = EditState()
        ContourRenderTests.allContour.write(into: &facelessState)
        let facelessOutput = try ContourFixture.run(
            node, context: context,
            request: RenderRequest(editState: facelessState, faces: [], quality: .preview))
        RPEngineFeatureFlags.contourSliders = false
        let flagOffOutput = try ContourFixture.run(
            node, context: context,
            request: ContourFixture.request(ContourRenderTests.allContour))
        RPEngineFeatureFlags.contourSliders = true

        return [
            "reference": "ColorReference (Double CPU, written from the spec) + ContourMask.value",
            "fixture":
                "synthetic 384x448 skin-tone field + SyntheticFaceMesh, faceWidth 200 px",
            "contour_psnr_db": all,
            "contour_max_abs_diff": allWorst,
            "contour_plus_full_grade_psnr_db": graded,
            "contour_plus_full_grade_max_abs_diff": gradedWorst,
            "per_slider_psnr_db": perSlider,
            "sliders_at_zero_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(
                source, zeroOutput),
            "no_face_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(source, facelessOutput),
            "flag_off_max_abs_diff": SpikeTextureIO.maxAbsoluteDifference(source, flagOffOutput),
        ]
    }

    // MARK: - Selectivity

    /// ADR-0011's "changes region X, changes region Y by exactly 0", restated for
    /// the three contour zones. The two control zones are the forehead centre
    /// (inside the face, in the middle of the frame, claimed by no zone) and a
    /// corner of the frame.
    static func selectivityNumbers(context: MetalContext) throws -> [String: Any] {
        let node = try ColorRenderNode(context: context)
        let source = ContourFixture.chart.pixels

        func zone(_ sliders: ContourSliders) throws -> [String: Any] {
            let output = try ContourFixture.run(
                node, context: context, request: ContourFixture.request(sliders))
            func luma(_ region: ContourFixture.Region) -> Double {
                ContourFixture.meanLuminanceChange(source, output, region)
            }
            func worst(_ region: ContourFixture.Region) -> Double {
                ContourFixture.maxChange(source, output, region)
            }
            return [
                "cheek_highlight_mean_luma": luma(.cheekHighlight),
                "cheek_hollow_mean_luma": luma(.cheekShadow),
                "nose_bridge_mean_luma": luma(.noseBridge),
                "jaw_mean_luma": luma(.jaw),
                "cheek_highlight_max_abs": worst(.cheekHighlight),
                "nose_bridge_max_abs": worst(.noseBridge),
                "jaw_max_abs": worst(.jaw),
                "forehead_centre_max_abs": worst(.foreheadCentre),
                "outside_face_max_abs": worst(.outsideFace),
            ]
        }

        return [
            "definition":
                "mean signed luminance change per contour zone, and worst |Δ| per zone; the two "
                + "control zones (forehead centre, frame corner) must be exactly 0",
            "probe_radius_over_face_width": 0.035,
            "cheek_100": try zone(ContourSliders(cheek: 100)),
            "nose_100": try zone(ContourSliders(nose: 100)),
            "jaw_100": try zone(ContourSliders(jaw: 100)),
            "all_100": try zone(ContourRenderTests.allContour),
        ]
    }

    // MARK: - Coverage

    static func coverageNumbers() -> [String: Any] {
        let lobes = ContourFixture.chart.allLobes
        return [
            "definition":
                "fraction of the frame where |mask| exceeds a threshold, one face at all three "
                + "sliders = 100 in a 384x448 head-and-shoulders crop",
            "frame_size": [ContourFixture.width, ContourFixture.height],
            "face_width_px": Double(ContourFixture.faceWidth),
            "fraction_of_frame_touched": ContourFixture.coverage(lobes, threshold: 0),
            "fraction_above_0_10": ContourFixture.coverage(lobes, threshold: 0.10),
            "fraction_above_0_25": ContourFixture.coverage(lobes, threshold: 0.25),
            "fraction_above_0_50": ContourFixture.coverage(lobes, threshold: 0.50),
        ]
    }

    // MARK: - Speed

    /// The marginal cost of the contour branch on the real a6300 frame: the same
    /// node, the same colour sliders, with the eleven lobes off and on.
    static func speedNumbers(context: MetalContext) throws -> [String: Any]? {
        let meshes = FaceLandmarkFixtures.a6300
        let name = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        guard let mesh = meshes.first(where: { $0.image.hasPrefix(name) }) ?? meshes.first,
            let cropURL = FaceLandmarkFixtures.cropImageURL(mesh)
        else { return nil }

        var out: [String: Any] = ["image": mesh.image]

        let cropImage = try SpikeS3BenchTests.loadUpright(cropURL)
        let previewScale = 2048 / max(mesh.imageSize.width, mesh.imageSize.height)
        let previewMesh = FaceLandmarkFixtures.scaled(mesh, by: previewScale)
        let previewWidth = Int(previewMesh.imageSize.width)
        let previewHeight = Int(previewMesh.imageSize.height)
        let (previewPixels, _, _) = try SpikeTextureIO.floatPixels(
            of: cropImage, space: .sRGBEncoded, width: previewWidth, height: previewHeight)
        out["preview"] = try measureOne(
            context: context, pixels: previewPixels, width: previewWidth, height: previewHeight,
            face: FaceLandmarkFixtures.renderInput(previewMesh), quality: .preview, iterations: 20)
        out["preview_size"] = [previewWidth, previewHeight]
        out["preview_face_width_px"] = Double(previewMesh.faceWidth)

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
                    context: context, pixels: fullPixels, width: fullImage.width,
                    height: fullImage.height, face: FaceLandmarkFixtures.renderInput(full),
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
        let node = try ColorRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        func state(_ contour: ContourSliders, _ color: ColorSliders) -> EditState {
            var out = EditState()
            contour.write(into: &out)
            color.write(into: &out)
            return out
        }
        let contourOnly = state(ContourRenderTests.allContour, ColorSliders())
        let gradeOnly = state(ContourSliders(), ColorRenderNodeTests.allSliders)
        let both = state(ContourRenderTests.allContour, ColorRenderNodeTests.allSliders)

        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])

        func time(_ editState: EditState) throws -> [String: Double] {
            let request = RenderRequest(editState: editState, faces: [face], quality: quality)
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

        let contour = try time(contourOnly)
        let grade = try time(gradeOnly)
        let together = try time(both)
        let zero = try time(EditState())

        var result: [String: Any] = [
            "iterations": iterations,
            "contour_only": contour,
            "colour_grade_only": grade,
            "contour_plus_colour_grade": together,
            "everything_at_zero": zero,
            "node_bytes": node.allocatedBytes,
            "lobes_uploaded": ContourMask.lobes(
                faces: [face], sliders: ContourRenderTests.allContour
            ).count,
        ]
        let marginal = (together["wall_median_ms"] ?? 0) - (grade["wall_median_ms"] ?? 0)
        result["contour_marginal_wall_ms"] = marginal
        result["contour_only_fps"] = 1000.0 / max(1e-9, contour["wall_median_ms"] ?? 1)
        result["contour_plus_colour_grade_fps"] = 1000.0
            / max(1e-9, together["wall_median_ms"] ?? 1)
        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }
}
