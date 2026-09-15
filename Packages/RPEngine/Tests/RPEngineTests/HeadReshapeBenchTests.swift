import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 — files the "Đầu" (head reshape) group's numbers.
///
/// One `RPBENCH-P6HEAD ` line of JSON, scraped by `Scripts/bench-head-reshape.sh`
/// into `Research/bench/p6-head-reshape-*.json`. Same arrangement as every other
/// group's bench: the number filed under `Research/` is always the number a test
/// measured (docs/PLAN.md §5, "measure before ship").
///
/// docs/PLAN.md §6.2 says this group *"cần vòng đo mới kiểu ADR-0010 (chưa có
/// ground-truth viền tóc trên ảnh a6300 thật)"* — a new measurement round,
/// because no hairline ground truth exists. There still is none: nobody has
/// drawn a hairline by hand on these frames, so **no number here claims the
/// parser's hair mask is correct**. What is claimed, and measured, is everything
/// between that mask and the picture:
///
/// * `reference.*` — the Swift trace against an **independent** NumPy
///   implementation (`Research/bench/hair-boundary-reference.py`, largest
///   4-connected component by label propagation, boundary as per-row/column
///   extremes). Says the trace is the outline of the component it claims.
/// * `alignment.*` — the hair mask against the 478-point mesh, as the IoU of the
///   face-oval polygon with the parser's own facial classes, for both signs of
///   the spike's derotation. Says the fixture's affine is right, which is the one
///   free parameter in putting a real mask and a real mesh in the same frame.
/// * `trace.*` — cost and shape of the trace on the 11 real hair masks.
/// * `handles.*` — how many control points the group produces, by role, and how
///   many are dropped for being clipped by the parsing crop or for crowding a
///   mesh handle. This is where the group's honest weakness shows: see
///   `limitations`.
/// * `accuracy.*` / `golden.*` — the lattice round-trip and a PSNR against the
///   `Double` CPU rasteriser on a real frame. Bar: the plan's 45 dB.
/// * `speed.*` — ms/frame at a 2048 px preview and at 24 MP with the head group
///   **off and on**, so its marginal cost over the "Mặt" group is visible rather
///   than buried in it, plus the CPU cost of the trace and the handle build.
///
/// None of it says the result is *pretty*. Every magnitude in ``HeadReshape`` is
/// untuned, and the JSON says so in `constants_are_tuned: false` — the same
/// disclosure ADR-0010 … ADR-0021 make for their groups.
///
/// **Mac / iOS-Simulator numbers only**; `is_real_device` says which machine
/// produced it.
@Suite("Phase 6.2 head reshape bench", .serialized)
struct HeadReshapeBenchTests {

    /// All three sliders at 100 — the group's worst case, which is what a bench
    /// should be measuring.
    static let allHead = HeadSliders(size: 100, width: 100, volume: 100)

    @Test("Files the Đầu group's trace, handle, accuracy and ms/frame numbers")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P6HEAD-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        var report: [String: Any] = [
            "suite": "Phase 6.2 Đầu (head reshape) slider group",
            "build_configuration": WarpBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "applies_in_node": "WarpRenderNode (rp_mls_grid + rp_warp_vertex/fragment), one solve with the Mặt group",
            "new_kernels": 0,
            "new_core_ml_models": 0,
            "new_mask_sources": 1,
            "mask_source": "FaceParsingGroup.hair (BiSeNet, ADR-0006) — already produced, newly consumed",
            "feature_flag": "RPEngineFeatureFlags.headSliders (default off)",
            "slider_keys": HeadSliders.Key.all,
            "slider_range": [0, 100],
            "section": EditState.SectionKey.face,
            "constants_are_tuned": false,
            "ground_truth_hairline": false,
            "geometry": [
                "size_gain": Double(HeadReshape.sizeGain),
                "width_gain": Double(HeadReshape.widthGain),
                "volume_fraction_of_face_width": Double(HeadReshape.volumeFraction),
                "pivot_t": Double(HeadReshape.pivotT),
                "crown_centre_t": Double(HeadReshape.crownCentreT),
                "ring_fraction": Double(HeadReshape.ringFraction),
                "max_ring_span_face_widths": Double(HeadReshape.maxRingSpanFraction),
                "min_separation_face_widths": Double(HeadReshape.minSeparationFraction),
                "boundary_sample_count": HairBoundary.sampleCount,
                "coverage_threshold": Int(HairBoundary.coverageThreshold),
            ],
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

        let frames = HairMaskFixtures.a6300
        if frames.isEmpty {
            report["real_frames_skipped"] = "a6300 parsing/mesh fixtures absent under Research/"
        } else {
            report["reference"] = Self.referenceNumbers(frames)
            report["alignment"] = Self.alignmentNumbers(frames)
            report["trace"] = Self.traceNumbers(frames)
            let handles = Self.handleNumbers(frames)
            report["handles"] = handles.summary
            report["limitations"] = handles.limitations
            report["accuracy"] = try Self.accuracyNumbers(context: context, frames: frames)
        }

        if let golden = try Self.goldenNumbers(context: context) {
            report["golden"] = golden
        } else {
            report["golden_skipped"] = "a6300 image fixture absent under Research/"
        }
        if let speed = try Self.speedNumbers(context: context, frames: frames) {
            report["speed"] = speed
        } else {
            report["speed_skipped"] = "a6300 image fixtures absent under Research/"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6HEAD \(String(decoding: data, as: UTF8.self))")

        // The bars that are the plan's are asserted. The speed figures are for an
        // iPhone and are recorded only.
        if let golden = report["golden"] as? [String: Any] {
            let psnr = try #require(golden["psnr_db"] as? Double)
            #expect(psnr >= 45, "head warp PSNR \(psnr) dB")
        }
        if let reference = report["reference"] as? [String: Any] {
            let worst = try #require(reference["max_extreme_deviation_px"] as? Int)
            #expect(worst == 0, "the trace differs from the NumPy reference by \(worst) px")
        }
        if let alignment = report["alignment"] as? [String: Any] {
            let wins = try #require(alignment["frames_where_chosen_sign_wins"] as? Int)
            #expect(wins == frames.count)
        }
        if let accuracy = report["accuracy"] as? [String: Any] {
            // The export bound is the "Mặt" group's (`WarpRenderNodeTests
            // .landmarksLandWhereTheSliderAsked`): 1 % of face width is ~6 px on
            // a 600 px face, the point at which a handle visibly misses.
            let export = try #require(accuracy["export"] as? [String: Any])
            let exportWorst = try #require(export["max_round_trip_over_face_width"] as? Double)
            #expect(exportWorst < 0.01, "export round trip \(exportWorst) × face width")

            // **The preview bound is deliberately looser, and that is a measured
            // finding rather than a concession.** This group's displacements are
            // an order of magnitude larger than the "Mặt" group's (0.17 × face
            // width at the crown against ~0.02), and MLS round-trip error on a
            // fixed lattice is proportional to the displacement over the cell —
            // so the same 65-vertex preview grid that gives the reshape sliders
            // 0.3 % gives these ~2 %. The export grid (129) lands back under 1 %.
            // Recorded in docs/ADR-0022 as the reason the preview and the export
            // of a head edit are not the same shape to the last pixel.
            let preview = try #require(accuracy["preview"] as? [String: Any])
            let previewWorst = try #require(
                preview["max_round_trip_over_face_width"] as? Double)
            #expect(previewWorst < 0.03, "preview round trip \(previewWorst) × face width")
        }
    }

    // MARK: - Against the independent reference

    static func referenceNumbers(_ frames: [HairMaskFixtures.Frame]) -> [String: Any] {
        guard let document = HairlineReference.document else {
            return ["skipped": "Research/bench/p6-head-hairline-reference.json absent"]
        }
        var checked = 0
        var worst = 0
        var componentMismatch = 0
        for frame in frames {
            let name = (frame.image as NSString).deletingPathExtension + ".png"
            guard let entry = document.real.first(where: { $0.image == name }) else { continue }
            let raw = RenderMask(
                width: frame.mask.width, height: frame.mask.height, values: frame.mask.values,
                maskToImage: .identity)
            guard let outline = HairBoundary.trace(raw) else { continue }
            if outline.componentPixelCount != entry.component_pixels { componentMismatch += 1 }
            let extremes = RingExtremes.of(outline.contour)
            for row in entry.rows ?? [] {
                guard let traced = extremes.rows[row[0]] else {
                    worst = Int.max
                    continue
                }
                worst = max(worst, abs(traced.0 - row[1]), abs(traced.1 - row[2]))
            }
            for col in entry.cols ?? [] {
                guard let traced = extremes.cols[col[0]] else {
                    worst = Int.max
                    continue
                }
                worst = max(worst, abs(traced.0 - col[1]), abs(traced.1 - col[2]))
            }
            checked += 1
        }
        return [
            "implementation": "Research/bench/hair-boundary-reference.py (NumPy label propagation + per-row/column extremes)",
            "real_frames_compared": checked,
            "synthetic_shapes_available": document.synthetic.count,
            "max_extreme_deviation_px": worst,
            "component_pixel_mismatches": componentMismatch,
        ]
    }

    static func alignmentNumbers(_ frames: [HairMaskFixtures.Frame]) -> [String: Any] {
        var chosen = 0.0
        var flipped = 0.0
        var wins = 0
        for frame in frames {
            let a = HeadAlignment.faceIoU(frame, flipRoll: false)
            let b = HeadAlignment.faceIoU(frame, flipRoll: true)
            chosen += a
            flipped += b
            if a > b { wins += 1 }
        }
        let n = Double(max(1, frames.count))
        return [
            "what": "IoU of the face-oval polygon with the parser's facial classes, per derotation sign",
            "mean_iou_chosen_sign": chosen / n,
            "mean_iou_flipped_sign": flipped / n,
            "frames_where_chosen_sign_wins": wins,
            "frames": frames.count,
        ]
    }

    // MARK: - The trace

    static func traceNumbers(_ frames: [HairMaskFixtures.Frame]) -> [String: Any] {
        var milliseconds: [Double] = []
        var contourPoints: [Double] = []
        var clippedFraction: [Double] = []
        var componentFraction: [Double] = []
        var maskFraction: [Double] = []
        var topClipped = 0
        var anyClipped = 0

        for frame in frames {
            var outline: HairBoundary.Outline?
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                outline = HairBoundary.trace(frame.mask)
                milliseconds.append(
                    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            guard let outline else { continue }
            contourPoints.append(Double(outline.contour.count))
            clippedFraction.append(
                Double(outline.clippedCount) / Double(max(1, outline.contour.count)))
            componentFraction.append(
                Double(outline.componentPixelCount) / Double(max(1, outline.maskPixelCount)))
            maskFraction.append(
                Double(outline.maskPixelCount)
                    / Double(outline.maskSize.width * outline.maskSize.height))
            if outline.clippedCount > 0 { anyClipped += 1 }
            // "Top" in mask space: the trace marks the pixel, so this asks
            // whether any clipped point is on the mask's first row.
            let raw = RenderMask(
                width: frame.mask.width, height: frame.mask.height, values: frame.mask.values,
                maskToImage: .identity)
            if let plain = HairBoundary.trace(raw),
                plain.contour.contains(where: { $0.isClipped && $0.location.y < 1 })
            {
                topClipped += 1
            }
        }

        return [
            "frames": frames.count,
            "mask_size": [frames.first?.mask.width ?? 0, frames.first?.mask.height ?? 0],
            "trace_ms_median": S3BenchStats.median(milliseconds),
            "trace_ms_p95": S3BenchStats.percentile(milliseconds, 0.95),
            "contour_points_median": S3BenchStats.median(contourPoints),
            "contour_points_max": contourPoints.max() ?? 0,
            "resampled_to": HairBoundary.sampleCount,
            "largest_component_fraction_min": componentFraction.min() ?? 0,
            "hair_fraction_of_crop_median": S3BenchStats.median(maskFraction),
            "clipped_sample_fraction_median": S3BenchStats.median(clippedFraction),
            "clipped_sample_fraction_max": clippedFraction.max() ?? 0,
            "frames_with_any_clipped_boundary": anyClipped,
            "frames_with_the_crown_clipped": topClipped,
        ]
    }

    // MARK: - The handles

    static func handleNumbers(_ frames: [HairMaskFixtures.Frame])
        -> (summary: [String: Any], limitations: [String: Any])
    {
        var mesh: [Double] = []
        var ring: [Double] = []
        var hair: [Double] = []
        var crowded: [Double] = []
        var clipped: [Double] = []
        var displacement: [Double] = []
        var noSilhouette = 0
        var noRing = 0
        var perFrame: [[String: Any]] = []

        for frame in frames {
            let input = HairMaskFixtures.renderInput(frame)
            let size = frame.mesh.imageSize
            guard
                let built = HeadReshape.controlPoints(
                    faces: [input], face: FaceSliders(), head: allHead, imageSize: size)
            else {
                noSilhouette += 1
                continue
            }
            mesh.append(Double(built.faceMeshHandleCount))
            ring.append(Double(built.ringHandleCount))
            hair.append(Double(built.hairHandleCount))
            crowded.append(Double(built.crowdedPointCount))
            clipped.append(Double(built.clippedPointCount))
            let relative = Double(built.maxDisplacement / input.faceWidth)
            displacement.append(relative)
            if built.ringHandleCount == 0 { noRing += 1 }
            perFrame.append([
                "image": frame.image,
                "ring": built.ringHandleCount,
                "hair": built.hairHandleCount,
                "clipped_dropped": built.clippedPointCount,
                "crowded_dropped": built.crowdedPointCount,
                "max_displacement_over_face_width": relative,
            ])
        }

        let summary: [String: Any] = [
            "sliders": "all three at 100",
            "face_mesh_handles": S3BenchStats.median(mesh),
            "ring_handles_median": S3BenchStats.median(ring),
            "ring_handles_min": ring.min() ?? 0,
            "hair_handles_median": S3BenchStats.median(hair),
            "hair_handles_min": hair.min() ?? 0,
            "clipped_dropped_median": S3BenchStats.median(clipped),
            "crowded_dropped_median": S3BenchStats.median(crowded),
            "max_displacement_over_face_width_median": S3BenchStats.median(displacement),
            "max_displacement_over_face_width_max": displacement.max() ?? 0,
            "per_frame": perFrame,
        ]
        let limitations: [String: Any] = [
            "frames_with_no_usable_silhouette": noSilhouette,
            "frames_with_no_expanded_ring": noRing,
            "note": "A frame with no hair mask (a hat: BiSeNet class 18 is not folded into hair; a bald subject; a parsing failure) produces no head handles at all and the sliders do nothing. A frame whose parsing crop cut the hairline loses those boundary points, so the silhouette is anchored only where it was seen.",
        ]
        return (summary, limitations)
    }

    // MARK: - Accuracy

    static func accuracyNumbers(context: MetalContext, frames: [HairMaskFixtures.Frame])
        throws -> [String: Any]
    {
        let node = try WarpRenderNode(context: context)
        try node.prewarm()
        var out: [String: Any] = [:]

        for quality in RenderQuality.allCases {
            var worstGrid = 0.0
            var worstRoundTrip = 0.0
            var worstRelative = 0.0
            var worstImage = ""
            var handles = 0

            for frame in frames {
                // A preview renders at 2048 px long edge (docs/PLAN.md §1.4); an
                // export renders the crop as it is.
                let scale: CGFloat =
                    quality == .preview
                    ? 2048 / max(frame.mesh.imageSize.width, frame.mesh.imageSize.height) : 1
                let input = HairMaskFixtures.renderInput(frame, scale: scale)
                let width = Int((frame.mesh.imageSize.width * scale).rounded())
                let height = Int((frame.mesh.imageSize.height * scale).rounded())
                let imageSize = CGSize(width: width, height: height)
                var state = EditState()
                allHead.write(into: &state)
                let request = RenderRequest(
                    editState: state, faces: [input], quality: quality)

                let source = try SpikeTextureIO.makeTexture(
                    width: width, height: height, device: context.device,
                    pixelFormat: .rgba16Float, usage: [.shaderRead])
                let destination = try SpikeTextureIO.makeTexture(
                    width: width, height: height, device: context.device,
                    pixelFormat: .rgba16Float, usage: [.shaderRead, .renderTarget])
                guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                    throw MetalContext.Failure.noCommandQueue
                }
                try node.encode(
                    into: commandBuffer, source: source, destination: destination,
                    request: request)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                guard let solved = node.debugDeformedGrid(),
                    let built = node.headControlPoints(for: request, imageSize: imageSize)
                else { continue }
                handles = max(handles, built.handles.count)

                let cpu = MLSDeformation.grid(
                    control: built.control, options: FaceReshape.options(for: quality),
                    imageSize: imageSize)
                for i in 0..<min(cpu.count, solved.points.count) {
                    worstGrid = max(
                        worstGrid,
                        Double(
                            hypot(
                                solved.points[i].x - cpu[i].x, solved.points[i].y - cpu[i].y)))
                }
                for handle in built.handles where handle.displacement > 0 {
                    let landed = MLSDeformation.interpolate(
                        grid: solved.points, gridWidth: solved.grid, gridHeight: solved.grid,
                        at: handle.source, imageSize: imageSize)
                    let error = Double(
                        hypot(
                            landed.x - handle.destination.x, landed.y - handle.destination.y))
                    if error > worstRoundTrip {
                        worstRoundTrip = error
                        worstImage = frame.image
                    }
                    worstRelative = max(worstRelative, error / Double(input.faceWidth))
                }
            }
            out[quality.rawValue] = [
                "grid": quality.meshGrid,
                "handles": handles,
                "max_grid_error_px": worstGrid,
                "max_round_trip_px": worstRoundTrip,
                "max_round_trip_over_face_width": worstRelative,
                "worst_frame": worstImage,
            ]
        }
        node.releaseIntermediates()
        return out
    }

    // MARK: - Golden

    static func goldenNumbers(context: MetalContext) throws -> [String: Any]? {
        guard let fixture = try HeadImageFixture.load(side: 640) else { return nil }
        let graph = try RenderGraph.standard(context: context)
        var state = EditState()
        allHead.write(into: &state)
        let request = RenderRequest(editState: state, faces: [fixture.face])
        let (output, _) = try graph.renderPixels(
            fixture.pixels, width: fixture.width, height: fixture.height, request: request)
        guard
            let built = HeadReshape.controlPoints(
                faces: [fixture.face], face: FaceSliders(), head: allHead,
                imageSize: CGSize(width: fixture.width, height: fixture.height))
        else { return nil }
        let reference = WarpReference.render(
            source: fixture.pixels, width: fixture.width, height: fixture.height,
            control: built.control, options: FaceReshape.options(for: .preview))
        return [
            "image": fixture.image,
            "size": [fixture.width, fixture.height],
            "handles_including_border": built.control.count,
            "psnr_db": SpikeTextureIO.psnr(reference, output),
            "max_abs_difference": SpikeTextureIO.maxAbsoluteDifference(reference, output),
            "change_against_the_source": SpikeTextureIO.maxAbsoluteDifference(
                fixture.pixels, output),
        ]
    }

    // MARK: - Speed

    static func speedNumbers(context: MetalContext, frames: [HairMaskFixtures.Frame])
        throws -> [String: Any]?
    {
        let name = ProcessInfo.processInfo.environment["RP_S3_IMAGE"] ?? "DSC05123"
        guard
            let frame = frames.first(where: { $0.image.hasPrefix(name) }) ?? frames.first,
            let cropURL = FaceLandmarkFixtures.cropImageURL(frame.mesh)
        else { return nil }

        var out: [String: Any] = ["image": frame.image]

        let cropImage = try SpikeS3BenchTests.loadUpright(cropURL)
        let previewScale =
            2048 / max(frame.mesh.imageSize.width, frame.mesh.imageSize.height)
        let width = Int((frame.mesh.imageSize.width * previewScale).rounded())
        let height = Int((frame.mesh.imageSize.height * previewScale).rounded())
        let (pixels, _, _) = try SpikeTextureIO.floatPixels(
            of: cropImage, space: .sRGBEncoded, width: width, height: height)
        out["preview"] = try measureOne(
            context: context, pixels: pixels, width: width, height: height,
            face: HairMaskFixtures.renderInput(frame, scale: previewScale),
            quality: .preview, iterations: 20)
        out["preview_size"] = [width, height]

        if ProcessInfo.processInfo.environment["RP_SKIP_FULL_RES"] == nil,
            let full = HairMaskFixtures.inFullFrame(frame),
            let fullURL = FaceLandmarkFixtures.fullFrameURL(frame.mesh)
        {
            let fullImage = try SpikeS3BenchTests.loadUpright(fullURL)
            if fullImage.width == Int(full.size.width),
                fullImage.height == Int(full.size.height)
            {
                let (fullPixels, _, _) = try SpikeTextureIO.floatPixels(
                    of: fullImage, space: .sRGBEncoded)
                out["full"] = try measureOne(
                    context: context, pixels: fullPixels, width: fullImage.width,
                    height: fullImage.height, face: full.input, quality: .export,
                    iterations: 5)
                out["full_size"] = [fullImage.width, fullImage.height]
                out["megapixels"] = Double(fullImage.width * fullImage.height) / 1e6
            } else {
                out["full_skipped"] =
                    "manifest upright_size \(full.size) != decoded "
                    + "\(fullImage.width)x\(fullImage.height)"
            }
        }
        return out
    }

    /// Times the node with the head group **off** and **on** at the same size, so
    /// the difference is the group's marginal cost and not the warp's.
    static func measureOne(
        context: MetalContext, pixels: [Float], width: Int, height: Int,
        face: FaceRenderInput, quality: RenderQuality, iterations: Int
    ) throws -> [String: Any] {
        let node = try WarpRenderNode(context: context)
        try node.prewarm()
        let graph = RenderGraph(context: context, nodes: [node])

        var headState = EditState()
        allHead.write(into: &headState)
        var faceState = EditState()
        FaceReshapeTests.allSliders.write(into: &faceState)
        var bothState = faceState
        allHead.write(into: &bothState)

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

        // The CPU half on its own: trace + component + resample + ring + handles,
        // which is the part that is new in this group and the part that runs on
        // the interaction thread before anything is encoded. Measured **cold**
        // (every call re-traces) and **warm** (through a `SilhouetteCache`, which
        // is what the node actually uses), because the difference between those
        // two is the whole reason the cache exists.
        var build: [Double] = []
        var cached: [Double] = []
        let imageSize = CGSize(width: width, height: height)
        let silhouettes = HeadReshape.SilhouetteCache()
        for _ in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = HeadReshape.controlPoints(
                faces: [face], face: FaceSliders(), head: allHead, imageSize: imageSize)
            build.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        for i in 0..<10 {
            // A drag changes the slider and nothing else, so the mask and the
            // mesh are identical every time — exactly the cache's hit case.
            let sliders = HeadSliders(size: Double(60 + i), width: 50, volume: 40)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = HeadReshape.controlPoints(
                faces: [face], face: FaceSliders(), head: sliders, imageSize: imageSize,
                cache: silhouettes)
            cached.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        let headOnly = try time(headState)
        let faceOnly = try time(faceState)
        let both = try time(bothState)

        var control = 0
        if let built = HeadReshape.controlPoints(
            faces: [face], face: FaceReshapeTests.allSliders, head: allHead,
            imageSize: imageSize)
        {
            control = built.control.count
        }
        var faceControl = 0
        if let built = FaceReshape.controlPoints(
            faces: [face], sliders: FaceReshapeTests.allSliders, imageSize: imageSize)
        {
            faceControl = built.control.count
        }

        var result: [String: Any] = [
            "grid": quality.meshGrid,
            "iterations": iterations,
            "control_points_face_only": faceControl,
            "control_points_face_and_head": control,
            "handle_build_ms_median_cold": S3BenchStats.median(build),
            "handle_build_ms_median_cached": S3BenchStats.median(cached),
            "silhouette_traces_during_the_cached_run": silhouettes.traceCount,
            "head_only": headOnly,
            "face_only": faceOnly,
            "face_and_head": both,
            "node_bytes": node.allocatedBytes,
        ]
        result["head_only_fps"] = 1000.0 / max(1e-9, headOnly["wall_median_ms"] ?? 1)
        result["face_and_head_fps"] = 1000.0 / max(1e-9, both["wall_median_ms"] ?? 1)
        result["marginal_gpu_ms"] =
            (both["gpu_median_ms"] ?? 0) - (faceOnly["gpu_median_ms"] ?? 0)
        node.releaseIntermediates()
        graph.releaseIntermediates()
        return result
    }
}
