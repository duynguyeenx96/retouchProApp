import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 — files the "Sửa da" (đồng bộ da toàn thân) numbers.
///
/// One `RPBENCH-P6SKINSYNC ` line of JSON, scraped by
/// `Scripts/bench-skin-sync.sh` into `Research/bench/p6-skin-sync-*.json`. Same
/// arrangement as every earlier group: the number filed under `Research/` is the
/// number a test measured (docs/PLAN.md §5).
///
/// ## Read this before reading the numbers
///
/// docs/PLAN.md §6.2 asks to *"đo IoU trên bộ ảnh test nhiều tông da khác nhau
/// trước khi ship"*. **That measurement does not exist and this file does not
/// pretend it does.** The only labelled data the project has access to is
/// `panelpts/research/data`, and it has no `_gt.bmp` in it: running
/// `node panelpts/research/eval.js` today prints *"4 ảnh, 0 có ground truth …
/// CHƯA CÓ GROUND TRUTH — các số trên chỉ là độ phủ, KHÔNG phải độ đúng"*. Human
/// ground truth has to be painted before a real IoU can be quoted, which is why
/// `RPEngineFeatureFlags.bodySkinSync` is **default off** and why
/// `human_ground_truth_available` is `false` in the JSON.
///
/// What *is* measured here, and is real:
///
/// * `port.*` — ``SkinCore`` against the shipped `skincore.js`, byte for byte on
///   the generated fixture. This is the strongest claim available: whatever
///   `eval.js` ever measured about the JS transfers to the Swift unchanged,
///   because they are the same function. Max abs diff must be **0**.
/// * `accuracy.*` — IoU / precision / recall against a **constructed** ground
///   truth: a synthetic frame whose skin region is known because it was drawn,
///   swept across six skin tones. Synthetic is weaker than photographic, but it
///   is not nothing: it is a control that catches a tone the classifier cannot
///   see at all, and it found one (see `accuracy.tones` — the two deepest tones
///   score ~0, because skincore.js's Kovac gate rejects `R <= 95` outright).
/// * `leak.*` — mean coverage over the non-skin distractors in the same frame
///   (rattan/wood, a beige wall, cool background). `eval.js`'s "leak" metric.
/// * `coverage_real.*` — the fraction of a real a6300 frame the mask claims, the
///   same *coverage, not accuracy* number `eval.js` prints for its four photos.
/// * `union.*` — how much area the whole-frame mask adds to the per-face BiSeNet
///   coverage in ``SkinRenderNode``, and the two invariants: the union never
///   weakens the face mask, and a §6.1 gate still narrows the result.
/// * `speed.*` — the classifier is **CPU, once per image, not per frame**; the
///   union is one extra GPU dispatch per frame. Both are reported separately,
///   because they are charged at different rates.
///
/// **Mac / iOS-Simulator numbers** (`is_real_device` says which), as for every
/// earlier bench.
@Suite("Phase 6.2 skin-sync bench", .serialized)
struct SkinSyncBenchTests {
    static var spikeRoot: URL? { SkinBenchTests.spikeRoot }

    @Test("Files the whole-body skin sync's port exactness, IoU, coverage and ms")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P6SKINSYNC-SKIP no Metal device")
            return
        }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }

        var report: [String: Any] = [
            "suite": "Phase 6.2 Sửa da (đồng bộ da toàn thân)",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "applies_in_node": "SkinRenderNode — same 8 sliders, same rp_skin_composite (79.0 dB, ADR-0009); only the bound mask changes",
            "new_kernels": 1,
            "new_kernel_names": ["rp_body_skin_union"],
            "new_core_ml_models": 0,
            "new_slider_keys": 0,
            "feature_flag": "RPEngineFeatureFlags.bodySkinSync (default off)",
            "mask_source": "SkinCore — port of panelpts/RetouchProUXP/skincore.js (classical CbCr/Kovac colour classification), no deep learning",
            "working_grid_width": BodySkinMask.Options.default.workingWidth,
            "composition": "union(face, body) FIRST, then the §6.1 RenderGateMask narrowing — widen before narrow; the body mask is NOT a RenderGateMask because gates multiply and can only subtract area",
            "human_ground_truth_available": false,
            "human_ground_truth_note":
                "panelpts/research/data has no _gt.bmp; eval.js prints 'CHƯA CÓ GROUND TRUTH'. "
                + "accuracy.* below is against a CONSTRUCTED synthetic truth, not a labelled photo set. "
                + "docs/PLAN.md §6.2's 'đo IoU trên bộ ảnh test nhiều tông da' is NOT satisfied by this file.",
            "plan_bars": ["preview_2048_fps": 30, "export_24mp_seconds": 8],
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

        report["port"] = Self.portNumbers()
        let accuracy = Self.accuracyNumbers()
        report["accuracy"] = accuracy
        report["union"] = try Self.unionNumbers(context: context)
        report["speed"] = try Self.speedNumbers(context: context)
        if let real = try Self.realFrameCoverage() {
            report["coverage_real"] = real
        } else {
            report["coverage_real_skipped"] =
                "Research/spikes/S3-guided-filter-mls/images/full absent (gitignored)"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P6SKINSYNC \(String(decoding: data, as: UTF8.self))")

        // What is asserted is only what this file can honestly assert.
        let port = try #require(report["port"] as? [String: Any])
        #expect(try #require(port["coverage_max_abs_diff"] as? Int) == 0)
        #expect(try #require(port["probe_mismatches"] as? Int) == 0)

        let union = try #require(report["union"] as? [String: Any])
        #expect(try #require(union["face_mask_worst_loss"] as? Double) <= 1.0 / 255)
        #expect(try #require(union["gated_bottom_half_px"] as? Int) == 0)
        #expect(try #require(union["flag_off_max_abs_diff"] as? Double) == 0)

        // The classifier must at least *detect* the light-to-medium tones it was
        // tuned on, on a frame with nothing skin-coloured to confuse it. The
        // deep-tone and wood failures are recorded, not asserted away — they are
        // why the flag is off.
        let tones = try #require(accuracy["tones"] as? [[String: Any]])
        let cleanIoUs = tones.compactMap { ($0["clean"] as? [String: Any])?["iou"] as? Double }
        let best = cleanIoUs.max() ?? 0
        #expect(best > 0.8, "best clean-frame IoU across the tone ladder is only \(best)")
    }

    // MARK: - port: SkinCore == skincore.js

    static func portNumbers() -> [String: Any] {
        let image = [UInt8](Data(base64Encoded: SkinCoreJSFixture.imageBase64)!)
        let expected = [UInt8](Data(base64Encoded: SkinCoreJSFixture.maskBase64)!)
        let result = SkinCore.classify(
            rgb: image, componentsPerPixel: 3,
            width: SkinCoreJSFixture.width, height: SkinCoreJSFixture.height)
        var worst = 0
        for i in 0..<expected.count {
            worst = max(worst, abs(Int(result.coverage[i]) - Int(expected[i])))
        }
        var probeMismatches = 0
        for (probe, js) in zip(SkinCoreJSFixture.probes, SkinCoreJSFixture.probeScores)
        where SkinCore.skinScore(probe.0, probe.1, probe.2) != js {
            probeMismatches += 1
        }
        return [
            "reference": "panelpts/RetouchProUXP/skincore.js, executed under Node by Scripts/skincore-js-fixture.js",
            "fixture": "synthetic 64x48 frame built to hit every branch (back-projection, 2 % component floor, luminance knees, yellowness knee)",
            "coverage_pixels": expected.count,
            "coverage_max_abs_diff": worst,
            "probe_count": SkinCoreJSFixture.probes.count,
            "probe_mismatches": probeMismatches,
            "median_cb_matches_js": result.stats.medianCb == SkinCoreJSFixture.learnedCb,
            "median_cr_matches_js": result.stats.medianCr == SkinCoreJSFixture.learnedCr,
            "storage_width_note":
                "Cb/Cr are held as Float (skincore.js uses Float32Array); holding them as Double agreed on this fixture but moved the reported medians in the 6th decimal",
            "components_kept": result.stats.componentsKept,
            "components_total": result.stats.componentsTotal,
        ]
    }

    // MARK: - accuracy: constructed ground truth, six skin tones

    /// The classic six-step skin swatch ladder, light to deep, in sRGB.
    static let toneLadder: [(String, (Int, Int, Int))] = [
        ("I_very_light", (255, 219, 172)),
        ("II_light", (241, 194, 125)),
        ("III_medium", (224, 172, 105)),
        ("IV_olive", (198, 134, 66)),
        ("V_brown", (141, 85, 36)),
        ("VI_deep", (91, 60, 17)),
    ]

    /// Two frames per tone, because `eval.js` reports two different things and
    /// conflating them hides which one failed:
    ///
    /// * **clean** — skin against a cool, obviously-not-skin background. Answers
    ///   *"can the classifier find this tone at all"*. A low IoU here is a
    ///   detection failure.
    /// * **cluttered** — the same, plus a rattan/wood block and a beige wall.
    ///   Answers *"does it reject skin-coloured materials"*. A low IoU here with
    ///   a high one in `clean` is a **rejection** failure, and `leak_wood_mean`
    ///   says so directly.
    static func accuracyNumbers() -> [String: Any] {
        var tones: [[String: Any]] = []
        for (name, rgb) in toneLadder {
            var entry: [String: Any] = ["tone": name, "rgb": [rgb.0, rgb.1, rgb.2]]
            for clutter in [false, true] {
                let frame = SyntheticSkinFrame(skin: rgb, clutter: clutter)
                let result = BodySkinMask.make(
                    rgb: frame.rgb, componentsPerPixel: 3, width: frame.width,
                    height: frame.height)
                let scored = frame.score(result.mask.values)
                var block: [String: Any] = [
                    "iou": scored.iou,
                    "precision": scored.precision,
                    "recall": scored.recall,
                    "leak_background_mean": scored.leakBackground,
                    "learned": result.stats.learned,
                    "coverage_fraction": result.coverageFraction,
                ]
                if clutter {
                    block["leak_wood_mean"] = scored.leakWood
                    block["leak_wall_mean"] = scored.leakWall
                }
                entry[clutter ? "cluttered" : "clean"] = block
            }
            tones.append(entry)
        }
        return [
            "definition":
                "IoU / precision / recall of the coverage thresholded at 127 (eval.js's threshold) against a CONSTRUCTED skin region; leak_* are mean coverage 0..1 over each non-skin material",
            "ground_truth": "constructed, not human-labelled — see human_ground_truth_note",
            "frame": "320x240 (the shipped working grid): a head ellipse + a neck/shoulder band of one skin tone; 'cluttered' adds a rattan/wood block and a beige wall, 'clean' does not. Deterministic +-5 per-channel noise either way.",
            "threshold": 127,
            "tones": tones,
            "known_limit_deep_tones":
                "skincore.js's Kovac gate rejects R <= 95 outright, so tone VI (91,60,17) scores ~0 even on the clean frame. That is the shipped panel's behaviour transcribed, not a port bug — and it is the single biggest reason this feature is default-off.",
            "known_limit_wood":
                "A rattan/wood block sits inside the CbCr skin ellipse and can score HIGHER than a mid/deep skin tone, so on the cluttered frame the per-image back-projection learns the wood instead of the skin and the 2 % component floor then keeps the wood and drops the model. docs/PLAN.md §6.2's optional v2 — intersecting with VNGeneratePersonSegmentationRequest ('Khoá nền', §6.1) — is aimed at exactly this, and these numbers are the argument for doing it before the toggle ships.",
        ]
    }

    // MARK: - union: what it does inside SkinRenderNode

    static func unionNumbers(context: MetalContext) throws -> [String: Any] {
        let width = SkinRenderNodeTests.width
        let height = SkinRenderNodeTests.height
        let node = try SkinRenderNode(context: context)
        let sliders = SkinRenderNodeTests.allSliders
        let body = BodySkinUnionTests.fullFrameMask()

        let faceOnly = try SkinRenderNodeTests.runNode(
            node, context: context, request: SkinRenderNodeTests.request(sliders))
        let faceCoverage = try SkinRenderNodeTests.readR8(
            #require(node.debugFaceMask), queue: context.commandQueue)

        var request = SkinRenderNodeTests.request(sliders)
        request.bodySkinMask = body
        let merged = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        let unionCoverage = try SkinRenderNodeTests.readR8(
            #require(node.debugUnionMask), queue: context.commandQueue)

        var worstLoss = 0.0
        var faceSum = 0.0
        var unionSum = 0.0
        for i in 0..<unionCoverage.count {
            worstLoss = max(worstLoss, faceCoverage[i] - unionCoverage[i])
            faceSum += faceCoverage[i]
            unionSum += unionCoverage[i]
        }

        // The §6.1 gate, applied after the union.
        var gated = SkinRenderNodeTests.request(sliders)
        gated.bodySkinMask = body
        gated.gateMasks = [try BodySkinUnionTests.topHalfGate(context: context)]
        let gatedOut = try SkinRenderNodeTests.runNode(node, context: context, request: gated)
        let bottomGated = BodySkinUnionTests.touched(gatedOut)
            .filter { $0 / width >= height / 2 }.count
        let bottomUngated = BodySkinUnionTests.touched(merged)
            .filter { $0 / width >= height / 2 }.count

        // And the flag-off control, on the same node.
        RPEngineFeatureFlags.bodySkinSync = false
        let flagOff = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        RPEngineFeatureFlags.bodySkinSync = true

        return [
            "fixture": "SkinRenderNodeTests' 320x240 frame, one 120 px face, a saturated whole-frame body mask",
            "frame_size": [width, height],
            "face_mask_mean_coverage": faceSum / Double(faceCoverage.count),
            "union_mean_coverage": unionSum / Double(unionCoverage.count),
            "face_mask_worst_loss": worstLoss,
            "touched_face_only_px": BodySkinUnionTests.touched(faceOnly).count,
            "touched_merged_px": BodySkinUnionTests.touched(merged).count,
            "ungated_bottom_half_px": bottomUngated,
            "gated_bottom_half_px": bottomGated,
            "gate_note":
                "gated_bottom_half_px must be 0: the gate is applied AFTER the union, so a painted mask still protects an area the whole-frame mask claims. Gate-then-union would leave it at ungated_bottom_half_px.",
            "flag_off_max_abs_diff": Double(
                SpikeTextureIO.maxAbsoluteDifference(flagOff, faceOnly)),
        ]
    }

    // MARK: - speed

    static func speedNumbers(context: MetalContext) throws -> [String: Any] {
        var out: [String: Any] = [
            "classifier_note":
                "BodySkinMask runs on the CPU once per IMAGE (the mask lives in the RenderRequest), not once per frame; the union is one r8 GPU dispatch per frame",
        ]

        // CPU: the classifier, at the two sizes that matter.
        for (label, width, height) in [
            ("preview_2048", 2048, 1365), ("full_24mp", 6000, 4000),
        ] {
            let frame = SyntheticSkinFrame(skin: (224, 172, 105), width: width, height: height)
            var samples: [Double] = []
            let iterations = width > 3000 ? 2 : 4
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = BodySkinMask.make(
                    rgb: frame.rgb, componentsPerPixel: 3, width: width, height: height)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            out["classifier_\(label)_ms"] = samples.sorted()[samples.count / 2]
            out["classifier_\(label)_size"] = [width, height]
        }

        // GPU: the marginal cost of the union dispatch inside the node.
        let width = 2048, height = 1365
        let node = try SkinRenderNode(context: context)
        try node.prewarm()
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 77)
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        let face = SkinReference.face(imageWidth: width, imageHeight: height, faceWidth: 512)
        var state = EditState()
        SkinRenderNodeTests.allSliders.write(into: &state)
        let base = RenderRequest(editState: state, faces: [face], quality: .preview)
        var withBody = base
        withBody.bodySkinMask = RenderMask(
            width: 320, height: 213, values: [UInt8](repeating: 200, count: 320 * 213),
            maskToImage: CGAffineTransform(
                scaleX: CGFloat(width) / 320, y: CGFloat(height) / 213))

        func measure(_ request: RenderRequest, iterations: Int = 12) throws -> Double {
            var samples: [Double] = []
            for _ in 0..<iterations {
                guard let buffer = context.commandQueue.makeCommandBuffer() else { break }
                let start = DispatchTime.now().uptimeNanoseconds
                try node.encode(
                    into: buffer, source: source, destination: destination, request: request)
                buffer.commit()
                buffer.waitUntilCompleted()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return samples.sorted()[samples.count / 2]
        }

        RPEngineFeatureFlags.bodySkinSync = false
        let without = try measure(base)
        RPEngineFeatureFlags.bodySkinSync = true
        let with = try measure(withBody)
        out["node_preview_2048_without_union_ms"] = without
        out["node_preview_2048_with_union_ms"] = with
        out["union_marginal_ms"] = with - without
        out["node_preview_2048_size"] = [width, height]
        out["node_bytes"] = node.allocatedBytes
        return out
    }

    // MARK: - coverage on a real frame (coverage, NOT accuracy)

    static func realFrameCoverage() throws -> [String: Any]? {
        guard let root = spikeRoot else { return nil }
        let directory = root.appendingPathComponent("images/full")
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter({ $0.hasSuffix(".jpg") }).sorted(), !names.isEmpty
        else { return nil }

        var frames: [[String: Any]] = []
        for name in names.prefix(4) {
            let image = try SpikeS3BenchTests.loadUpright(
                directory.appendingPathComponent(name))
            let scale = 1280.0 / Double(max(image.width, image.height))
            let w = Int((Double(image.width) * scale).rounded())
            let h = Int((Double(image.height) * scale).rounded())
            let (pixels, _, _) = try SpikeTextureIO.floatPixels(
                of: image, space: .sRGBEncoded, width: w, height: h)
            let result = BodySkinMask.make(floatRGBA: pixels, width: w, height: h)
            frames.append([
                "image": name,
                "analysed_size": [w, h],
                "coverage_fraction": result.coverageFraction,
                "raw_percent": result.stats.rawPercent,
                "final_percent": result.stats.finalPercent,
                "learned": result.stats.learned,
                "median_cb": result.stats.medianCb,
                "median_cr": result.stats.medianCr,
                "components_kept": result.stats.componentsKept,
                "components_total": result.stats.componentsTotal,
            ])
        }
        return [
            "definition":
                "fraction of the frame the mask claims on real a6300 photos — the same COVERAGE number eval.js prints for panelpts/research/data, and like it, NOT a correctness measure",
            "frames": frames,
        ]
    }
}

/// A frame whose skin region is known because it was drawn: the constructed
/// ground truth `SkinSyncBenchTests.accuracyNumbers()` scores against.
///
/// Four materials, chosen for what each one tests:
/// * **skin** — a head ellipse plus a neck/shoulder band, the thing the mask must
///   find. Two regions rather than one so `keepBigComponents` has a shape with a
///   waist in it.
/// * **rattan / wood** — the classic false positive, yellower than skin. It is
///   what `skincore.js`'s G−B knee exists for, so leaking here means that knee
///   stopped working.
/// * **beige wall** — a near-grey the saturation rule (`max − min > 15`) must
///   reject.
/// * **cool background** — trivially rejected; present so the frame's statistics
///   are not dominated by skin.
///
/// Noise is a deterministic LCG, so the frame is byte-identical on every machine
/// and a box-blur off-by-one cannot hide behind flat colour.
struct SyntheticSkinFrame {
    let width: Int
    let height: Int
    var rgb: [UInt8]
    /// `true` where the frame was drawn as skin.
    var truth: [Bool]
    private var wood: [Bool]
    private var wall: [Bool]

    /// - Parameter clutter: adds the two skin-coloured distractors. `false`
    ///   leaves only skin against a cool background, which is the *detection*
    ///   question rather than the *rejection* one.
    init(skin: (Int, Int, Int), clutter: Bool = true, width: Int = 320, height: Int = 240) {
        self.width = width
        self.height = height
        rgb = [UInt8](repeating: 0, count: width * height * 3)
        truth = [Bool](repeating: false, count: width * height)
        wood = truth
        wall = truth

        var seed: UInt32 = 20_260_915
        func noise() -> Int {
            seed = seed &* 1_103_515_245 &+ 12345
            return Int((seed >> 16) % 11) - 5
        }
        func ellipse(_ x: Int, _ y: Int, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double)
            -> Bool
        {
            let dx = (Double(x) - cx) / rx, dy = (Double(y) - cy) / ry
            return dx * dx + dy * dy <= 1
        }

        let w = Double(width), h = Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var colour: (Int, Int, Int)
                if ellipse(x, y, w * 0.34, h * 0.36, w * 0.14, h * 0.24) {
                    colour = skin  // head
                    truth[i] = true
                } else if ellipse(x, y, w * 0.34, h * 0.95, w * 0.26, h * 0.30) {
                    colour = skin  // neck and shoulders, running out of frame
                    truth[i] = true
                } else if clutter && x > Int(w * 0.70) && y < Int(h * 0.55) {
                    colour = (196, 150, 96)  // rattan / wood
                    wood[i] = true
                } else if clutter && x > Int(w * 0.70) {
                    colour = (205, 190, 172)  // beige wall, near-grey
                    wall[i] = true
                } else {
                    colour = (62, 78, 96)  // cool background
                }
                rgb[i * 3] = UInt8(clamping: colour.0 + noise())
                rgb[i * 3 + 1] = UInt8(clamping: colour.1 + noise())
                rgb[i * 3 + 2] = UInt8(clamping: colour.2 + noise())
            }
        }
    }

    struct Score {
        var iou: Double
        var precision: Double
        var recall: Double
        var leakWood: Double
        var leakWall: Double
        var leakBackground: Double
    }

    /// `coverage` must be at this frame's own resolution.
    func score(_ coverage: [UInt8], threshold: UInt8 = 127) -> Score {
        var intersection = 0, union = 0, predicted = 0, actual = 0
        var woodSum = 0.0, woodCount = 0.0
        var wallSum = 0.0, wallCount = 0.0
        var backgroundSum = 0.0, backgroundCount = 0.0
        for i in 0..<min(coverage.count, truth.count) {
            let hit = coverage[i] >= threshold
            if hit { predicted += 1 }
            if truth[i] { actual += 1 }
            if hit && truth[i] { intersection += 1 }
            if hit || truth[i] { union += 1 }
            let v = Double(coverage[i]) / 255
            if wood[i] {
                woodSum += v
                woodCount += 1
            } else if wall[i] {
                wallSum += v
                wallCount += 1
            } else if !truth[i] {
                backgroundSum += v
                backgroundCount += 1
            }
        }
        return Score(
            iou: union > 0 ? Double(intersection) / Double(union) : 0,
            precision: predicted > 0 ? Double(intersection) / Double(predicted) : 0,
            recall: actual > 0 ? Double(intersection) / Double(actual) : 0,
            leakWood: woodCount > 0 ? woodSum / woodCount : 0,
            leakWall: wallCount > 0 ? wallSum / wallCount : 0,
            leakBackground: backgroundCount > 0 ? backgroundSum / backgroundCount : 0)
    }
}
