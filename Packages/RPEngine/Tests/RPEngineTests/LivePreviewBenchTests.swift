import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — files the **interactive** numbers for the live preview.
///
/// The four slider groups already have their own per-node benches. What none of
/// them measures is the thing this item ships: the cost of *one redraw of the
/// canvas* — the whole graph over a real 2048 px preview, plus the present pass
/// into a drawable-sized texture — and the cost of the per-shot work that must
/// **not** happen on that path (decode, upload, face analysis).
///
/// One `RPBENCH-P2LIVE ` line, scraped by `Scripts/bench-live-preview.sh` into
/// `Research/bench/p2-live-preview-*.json`.
///
/// **This is a Mac / iOS-Simulator number.** docs/PLAN.md §3's bar (≥ 30 fps at
/// a 2048 px preview) is stated for an iPhone and no device is attached — the
/// same limitation S1, S2, S3, `FaceAnalyzer` and all four slider groups record.
/// `is_real_device` in the JSON says which it is. In the Simulator read
/// `wall_*_ms` and ignore `gpu_median_ms`, which the Simulator does not report
/// meaningfully.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 live preview bench", .serialized)
struct LivePreviewBenchTests {

    @Test("Files the live preview's ms/redraw and the per-shot costs")
    func measure() throws {
        guard let context = SpikeS3Support.context else {
            print("RPBENCH-P2LIVE-SKIP no Metal device")
            return
        }
        // All four groups on — the shipping app's configuration (docs/ADR-0013).
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableColorRenderGraph()
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableWarpRenderGraph()
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableColorRenderGraph()
                RPEngineFeatureFlags.disableWarpRenderGraph()
                RPEngineFeatureFlags.disableEyesTeethRenderGraph()
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }

        var report: [String: Any] = [
            "suite": "Phase 2 live preview (MTKView interaction path)",
            "build_configuration": SkinBenchTests.buildConfiguration,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "metal_device": context.device.name,
            "shader_compile_ms": context.libraryCompileMilliseconds,
            "shader_source_files": MetalContext.shaderSources.count,
            "quality": RenderQuality.preview.rawValue,
            "preview_long_edge": RenderQuality.preview.preferredLongEdge ?? 0,
            "guided_subsample": RenderQuality.preview.guidedSubsample,
            "mesh_grid": RenderQuality.preview.meshGrid,
            "pixel_space": RenderQuality.preview.pixelSpace.rawValue,
            "output_pixel_format": "rgba16Float",
            "drawable_pixel_format": "bgra8Unorm (sRGB colour space, not _srgb)",
            "plan_bars": ["preview_fps": 30],
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

        if let numbers = try Self.numbers(context: context) {
            for (key, value) in numbers { report[key] = value }
        } else {
            report["skipped"] =
                "Research/spikes/{S1-landmark/a6300,S3-guided-filter-mls/images/full} not present"
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RPBENCH-P2LIVE \(String(decoding: data, as: UTF8.self))")

        // Recorded, not asserted: the plan's fps bar is an iPhone bar and this
        // is not an iPhone. What *is* asserted lives in
        // `LivePreviewRendererTests` (bit-identity with the render graph).
    }

    // MARK: - The measurement

    static func numbers(context: MetalContext) throws -> [String: Any]? {
        // A real a6300 frame with a real 478-point mesh measured on it, so the
        // blur radii and the warp handles are the ones a real edit would use.
        guard let mesh = FaceLandmarkFixtures.a6300.first(where: { $0.image == "DSC05123.jpg" })
                ?? FaceLandmarkFixtures.a6300.first,
            let fullMesh = FaceLandmarkFixtures.inFullFrame(mesh),
            let imageURL = FaceLandmarkFixtures.fullFrameURL(mesh)
        else { return nil }
        let full = try SpikeS3BenchTests.loadUpright(imageURL)

        var out: [String: Any] = [:]
        out["shot"] = [
            "image": mesh.image,
            "full_size": [full.width, full.height],
            "megapixels": Double(full.width * full.height) / 1e6,
        ]

        // ---- per-shot work (must NOT be on the interaction path) ----
        // Decode, exactly as `ImageDecoder` does it for the canvas.
        var decodeMs: [Double] = []
        var decoded: PreviewImage?
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            decoded = try ImageDecoder.decode(contentsOf: imageURL, maxPixelSize: 2048)
            decodeMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        guard let preview = decoded else { return nil }

        let renderer = try LivePreviewRenderer(context: context)
        var prewarmMs: Double = 0
        do {
            let start = DispatchTime.now().uptimeNanoseconds
            try renderer.prewarm()
            prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        var uploadMs: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            try renderer.setSource(preview.cgImage)
            uploadMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let previewWidth = Int(preview.pixelSize.width)
        let previewHeight = Int(preview.pixelSize.height)

        out["per_shot"] = [
            "decode_2048_median_ms": S3BenchStats.median(decodeMs),
            "upload_median_ms": S3BenchStats.median(uploadMs),
            "graph_prewarm_ms": prewarmMs,
            "note":
                "Decode + upload happen once per shot in LivePreviewController.open(_:); "
                + "prewarm once per process. None of them is on the slider path.",
        ]
        out["preview_size"] = [previewWidth, previewHeight]

        // ---- the face, in preview pixels ----
        let scale = preview.pixelSize.width / CGSize(width: full.width, height: full.height).width
        let scaledMesh = FaceLandmarkFixtures.scaled(fullMesh, by: scale)
        let face = Self.face(mesh: scaledMesh, imageWidth: previewWidth, imageHeight: previewHeight)
        out["face_width_px_preview"] = scaledMesh.faceWidth

        // ---- one redraw ----
        func redraw(_ label: String, _ state: EditState, iterations: Int = 30) throws
            -> [String: Any]
        {
            let request = RenderRequest(editState: state, faces: [face], quality: .preview)
            for _ in 0..<3 { _ = try renderer.render(request) }
            var wall: [Double] = []
            var gpu: [Double] = []
            var nodes: [String] = []
            for _ in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                let report = try renderer.render(request)
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                gpu.append(report.gpuMilliseconds)
                nodes = report.nodes
            }
            let median = S3BenchStats.median(wall)
            return [
                "label": label,
                "nodes": nodes,
                "wall_median_ms": median,
                "wall_p95_ms": S3BenchStats.percentile(wall, 0.95),
                "gpu_median_ms": S3BenchStats.median(gpu),
                "fps_from_wall_median": median > 0 ? 1000 / median : 0,
            ]
        }

        var cases: [[String: Any]] = []
        cases.append(try redraw("empty EditState (passthrough)", EditState()))
        cases.append(try redraw("color only", Self.state { ColorRenderNodeTests.allSliders.write(into: &$0) }))
        cases.append(
            try redraw("skin only", Self.state { SkinRenderNodeTests.allSliders.write(into: &$0) }))
        cases.append(try redraw("face reshape only", Self.state { Self.allFace.write(into: &$0) }))
        cases.append(
            try redraw("eyes/teeth only", Self.state { Self.allEyesTeeth.write(into: &$0) }))
        cases.append(try redraw("all four groups", Self.allGroupsState))
        out["redraw"] = cases

        // ---- present into a drawable-sized texture ----
        let drawableWidth = 2048
        let drawableHeight = 1400
        let drawable = try SpikeTextureIO.makeTexture(
            width: drawableWidth, height: drawableHeight, device: context.device,
            pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite, .renderTarget])
        let placement = PreviewPlacement(
            destinationSize: CGSize(width: drawableWidth, height: drawableHeight),
            imageRect: CGRect(
                x: 120, y: 40, width: Double(previewWidth) * 0.7,
                height: Double(previewHeight) * 0.7))
        for _ in 0..<3 { try renderer.present(into: drawable, placement: placement) }
        var presentMs: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            try renderer.present(into: drawable, placement: placement)
            presentMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        out["present"] = [
            "drawable_size": [drawableWidth, drawableHeight],
            "wall_median_ms": S3BenchStats.median(presentMs),
            "wall_p95_ms": S3BenchStats.percentile(presentMs, 0.95),
            "note":
                "Placement-only. A pan or a zoom runs this and no node — the graph "
                + "output texture is kept between frames.",
        ]

        // ---- a real slider drag: 60 different values, back to back ----
        var dragFrames: [Double] = []
        let dragStart = DispatchTime.now().uptimeNanoseconds
        for step in 0..<60 {
            var state = Self.allGroupsState
            state.setSlider(
                SkinSliders.Key.smooth, in: EditState.SectionKey.skin,
                to: Double(step) * 100.0 / 59.0)
            let request = RenderRequest(editState: state, faces: [face], quality: .preview)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try renderer.render(request)
            try renderer.present(into: drawable, placement: placement)
            dragFrames.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let dragTotal = Double(DispatchTime.now().uptimeNanoseconds - dragStart) / 1e6
        out["drag_60_frames"] = [
            "total_ms": dragTotal,
            "frame_median_ms": S3BenchStats.median(dragFrames),
            "frame_p95_ms": S3BenchStats.percentile(dragFrames, 0.95),
            "fps_from_median": 1000 / max(S3BenchStats.median(dragFrames), 1e-6),
            "decodes": 0,
            "uploads": 0,
            "face_analyses": 0,
            "note":
                "Every frame is render + present with a different slider value, on the "
                + "texture uploaded once above. Nothing decodes, uploads or re-analyses; "
                + "RPUITests/LivePreviewWiringTests pins the analysis count from the UI side.",
        ]
        return out
    }

    // MARK: - Fixtures

    static func state(_ build: (inout EditState) -> Void) -> EditState {
        var state = EditState()
        build(&state)
        return state
    }

    /// Every group at a mid-to-high value, i.e. the most expensive thing a user
    /// can ask the canvas for.
    static var allGroupsState: EditState {
        var state = EditState()
        ColorRenderNodeTests.allSliders.write(into: &state)
        SkinRenderNodeTests.allSliders.write(into: &state)
        allFace.write(into: &state)
        allEyesTeeth.write(into: &state)
        return state
    }

    static let allFace = FaceSliders(
        slim: 40, cheekbone: 30, jaw: 30, chin: 25, forehead: 20, temple: 20,
        noseShrink: 30, noseBridge: 25, noseTip: 25, eyeSize: 35, eyeSpacing: 20,
        eyeTilt: 25, mouthSize: 20, mouthSmile: 25, lipFullness: 30)

    static let allEyesTeeth = EyesTeethSliders(
        eyeBrighten: 50, scleraWhiten: 60, eyeDefinition: 40, teethWhiten: 55)

    /// A face with a real mesh plus the three masks the enabled nodes read,
    /// framed like a real parsing crop (1.87 × face width) around the mesh.
    ///
    /// The mask *content* does not change what a node costs — every pass is
    /// full-resolution and unconditional — but the face width does, because
    /// every radius in the graph is a fraction of it.
    static func face(
        mesh: FaceLandmarkFixtures.Mesh, imageWidth: Int, imageHeight: Int
    ) -> FaceRenderInput {
        let maskSide = 512
        var centre = CGPoint(x: Double(imageWidth) / 2, y: Double(imageHeight) * 0.45)
        if !mesh.landmarks.isEmpty {
            let sum = mesh.landmarks.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
            }
            centre = CGPoint(
                x: sum.x / CGFloat(mesh.landmarks.count),
                y: sum.y / CGFloat(mesh.landmarks.count))
        }
        let side = mesh.faceWidth * 1.87
        let region = CGAffineTransform.identity
            .translatedBy(x: centre.x, y: centre.y)
            .scaledBy(x: side / CGFloat(maskSide), y: side / CGFloat(maskSide))
            .translatedBy(x: -CGFloat(maskSide) / 2, y: -CGFloat(maskSide) / 2)
        let ellipse = SkinReference.ellipseMask(width: maskSide, height: maskSide)
        let mask = RenderMask(
            width: maskSide, height: maskSide, values: ellipse, maskToImage: region)
        return FaceRenderInput(
            landmarks: mesh.landmarks,
            faceWidth: mesh.faceWidth,
            masks: [.skin: mask, .eyes: mask, .mouth: mask])
    }
}
