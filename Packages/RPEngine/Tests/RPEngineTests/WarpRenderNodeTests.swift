import CoreGraphics
import Foundation
import ImageIO
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 golden tests for the "Mặt" slider group on the GPU.
///
/// ## Why not a single PSNR
/// The Da group is a per-pixel filter, so one PSNR against a `Double` CPU
/// implementation says everything. A warp is a *geometric* operation: an output
/// image can be pixel-perfect against a reference that solved the wrong
/// deformation, and a deformation can be exactly right while the rasteriser puts
/// it on screen upside down. So there are three levels, and a failure says which:
///
/// 1. **Grid solve vs `MLSDeformation.grid`** — the float32 SIMD kernel against
///    the `Double` scalar reference, in **pixels**, on the production handles for
///    real a6300 faces. This is spike S3's `mls_gpu_vs_cpu.json` comparison
///    (ADR-0007: 1.11e-3 px preview / 3.34e-3 px export on 84 synthetic handles)
///    re-run on ~150 handles that a slider actually produces.
/// 2. **Landmark round-trip** — where the *mesh* puts each moved landmark,
///    against where the slider asked for it. MLS interpolates its handles
///    exactly, so every pixel of this error is the 65/129 lattice, which is the
///    quantity ADR-0007 fixed the grid size on. This is the number that says the
///    slider does what it says.
/// 3. **Rendered image vs `WarpReference`** — a `Double` CPU rasterisation of the
///    same triangle mesh. Only this covers the triangulation, the clip-space
///    mapping, the y flip, the uv assignment and the sampler, all of which can be
///    wrong while producing a plausible picture.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 warp node", .serialized)
struct WarpRenderNodeTests {

    /// Every slider at a mid value, so no term of the accumulation is skipped.
    static let allSliders = FaceReshapeTests.allSliders

    static func request(
        _ sliders: FaceSliders, faces: [FaceRenderInput], quality: RenderQuality = .preview
    ) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        return RenderRequest(editState: state, faces: faces, quality: quality)
    }

    // MARK: - Flags

    @Test("Constructing the warp node needs its own flag")
    func warpNodeHasItsOwnFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.warpSliders = false
        }
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) { try WarpRenderNode(context: context) }
    }

    /// The node owns an `MLSMeshWarp`, and that kernel's own gate is not
    /// bypassed — the same arrangement `SkinRenderNode` has with `.guidedFilter`.
    @Test("The warp node still needs the S3 kernel's flag")
    func warpNodeNeedsTheKernelFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.warpSliders = true
            RPEngineFeatureFlags.mlsMeshWarp = false
        }
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) { try WarpRenderNode(context: context) }
    }

    @Test("The graph registers only the groups whose flags are on, in stage order")
    func graphRegistersEnabledGroupsInStageOrder() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableWarpRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableSkinRenderGraph()
                RPEngineFeatureFlags.disableWarpRenderGraph()
            }
        }
        // docs/PLAN.md §2 fixes `skin` before `warp`, and the graph sorts by
        // stage, so registration order cannot change the picture.
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["skin", "warp"])

        RPEngineFeatureFlags.skinSliders = false
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["warp"])
        RPEngineFeatureFlags.skinSliders = true
    }

    // MARK: - The 0 contract

    @Test("All fifteen sliders at 0 leave every pixel bit-exact")
    func zeroSlidersIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let face = SyntheticFaceMesh.renderInput(width: 120, centre: CGPoint(x: 160, y: 120))
        let node = try WarpRenderNode(context: context)
        #expect(!node.isActive(for: Self.request(FaceSliders(), faces: [face])))
        // Straight at the node, bypassing the graph's `isActive` short-circuit,
        // so this tests the node's own 0-handling and not the graph's.
        let (source, output) = try Self.runNode(
            node, context: context, request: Self.request(FaceSliders(), faces: [face]),
            width: 320, height: 240)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) == 0)
    }

    @Test("A face with no mesh leaves every pixel bit-exact, even at slider 100")
    func aFaceWithoutLandmarksIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let node = try WarpRenderNode(context: context)
        // The Da group only needs masks, so a `FaceRenderInput` with no landmarks
        // is legal and reaches this node.
        let maskOnly = FaceRenderInput(faceWidth: 120)
        let request = Self.request(Self.allSliders, faces: [maskOnly])
        #expect(!node.isActive(for: request))
        let (source, output) = try Self.runNode(
            node, context: context, request: request, width: 320, height: 240)
        #expect(SpikeTextureIO.maxAbsoluteDifference(source, output) == 0)

        // …and so is a face whose width could not be measured.
        var degenerate = SyntheticFaceMesh.renderInput(width: 120, centre: CGPoint(x: 160, y: 120))
        degenerate.faceWidth = 0
        let zeroWidth = Self.request(Self.allSliders, faces: [degenerate])
        #expect(!node.isActive(for: zeroWidth))
        let (s2, o2) = try Self.runNode(
            node, context: context, request: zeroWidth, width: 320, height: 240)
        #expect(SpikeTextureIO.maxAbsoluteDifference(s2, o2) == 0)
    }

    @Test("An empty EditState runs no node and blits the source through")
    func emptyEditStateIsPassthrough() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }
        let graph = try RenderGraph.standard(context: context)
        let width = 48, height = 32
        let pixels = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(
                SpikeS3Support.syntheticImage(width: width, height: height, seed: 7)))
        let face = SyntheticFaceMesh.renderInput(width: 20, centre: CGPoint(x: 24, y: 16))
        let (output, report) = try graph.renderPixels(
            pixels, width: width, height: height,
            request: RenderRequest(editState: EditState(), faces: [face]))
        #expect(report.isPassthrough)
        #expect(SpikeTextureIO.maxAbsoluteDifference(pixels, output) == 0)
    }

    // MARK: - Quality

    /// Preview and export genuinely differ here (65 vs 129 vertices per side),
    /// unlike `guidedSubsample`, so a lattice cache that ignored the request's
    /// quality would render an export at preview density — the same class of bug
    /// ADR-0009 records for `SkinRenderNode.cache`, except this one would fire
    /// today rather than the day a constant is split.
    @Test("The lattice follows the request's quality")
    func latticeFollowsTheRequestQuality() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let node = try WarpRenderNode(context: context)
        let face = SyntheticFaceMesh.renderInput(width: 120, centre: CGPoint(x: 160, y: 120))
        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [face], quality: .preview),
            width: 320, height: 240)
        #expect(node.debugGrid == 65)
        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [face], quality: .export),
            width: 320, height: 240)
        #expect(node.debugGrid == 129)
        // …and back, so the cache invalidates in both directions rather than
        // sticking on whichever quality rendered first.
        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [face], quality: .preview),
            width: 320, height: 240)
        #expect(node.debugGrid == 65)
        #expect(node.allocatedBytes > 0)
        node.releaseIntermediates()
        #expect(node.allocatedBytes == 0)
    }

    // MARK: - 1 + 2. Grid solve and landmark round trip, on real faces

    /// The production version of spike S3's `mls_gpu_vs_cpu.json`: the same
    /// comparison, on the handles a slider panel actually produces, at both
    /// mandatory grid sizes.
    @Test("GPU grid solve matches the Double CPU reference on the real a6300 meshes")
    func gridSolveMatchesTheCPUReferenceOnRealFaces() throws {
        guard let context = SpikeS3Support.context else { return }
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else {
            print("P2 warp grid solve: SKIP (a6300 mesh fixture absent)")
            return
        }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let node = try WarpRenderNode(context: context)
        var worst: [RenderQuality: Double] = [:]
        for mesh in meshes {
            for quality in RenderQuality.allCases {
                let result = try WarpAccuracy.measure(
                    node: node, context: context, mesh: mesh, quality: quality,
                    sliders: Self.allSliders)
                worst[quality] = max(worst[quality] ?? 0, result.maxGridErrorPx)
            }
        }
        print(
            "P2 warp grid solve vs Double CPU on \(meshes.count) real meshes: "
                + "preview(grid 65) \(worst[.preview] ?? 0) px, "
                + "export(grid 129) \(worst[.export] ?? 0) px")
        // Bound, not the measurement. S3 measured 3.34e-3 px at 24 MP with 84
        // handles; 0.01 px is the same bound `MLSWarpTests` uses and is far below
        // anything visible after resampling.
        #expect((worst[.preview] ?? 1) < 0.01)
        #expect((worst[.export] ?? 1) < 0.01)
    }

    /// Does the slider land the landmark where it said it would?
    ///
    /// MLS interpolates its handles exactly (`MLSDeformationTests`
    /// `.interpolationProperty`), so this error is entirely the lattice: 65
    /// vertices across a 2048 px preview is a 32 px cell, and the deformation is
    /// smooth over that. Reported as a fraction of face width as well as in
    /// pixels, because that is the unit the sliders are specified in.
    @Test("The mesh lands each moved landmark where the slider asked, to a fraction of a pixel")
    func landmarksLandWhereTheSliderAsked() throws {
        guard let context = SpikeS3Support.context else { return }
        let meshes = FaceLandmarkFixtures.a6300
        guard !meshes.isEmpty else {
            print("P2 warp round trip: SKIP (a6300 mesh fixture absent)")
            return
        }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let node = try WarpRenderNode(context: context)
        for quality in RenderQuality.allCases {
            var worstPx = 0.0
            var worstFraction = 0.0
            var worstImage = ""
            for mesh in meshes {
                let result = try WarpAccuracy.measure(
                    node: node, context: context, mesh: mesh, quality: quality,
                    sliders: Self.allSliders)
                if result.maxRoundTripPx > worstPx {
                    worstPx = result.maxRoundTripPx
                    worstImage = mesh.image
                }
                worstFraction = max(worstFraction, result.maxRoundTripOverFaceWidth)
            }
            print(
                "P2 warp landmark round trip, \(quality.rawValue) (grid \(quality.meshGrid)): "
                    + "worst \(worstPx) px on \(worstImage), "
                    + "\(worstFraction) × face width")
            // 1% of face width is ~6 px on a 600 px face — the point at which a
            // handle visibly misses. The measured value is far below it; this is
            // a regression bound on the grid choice, not the claim.
            #expect(worstFraction < 0.01, "\(quality) round trip \(worstFraction) × face width")
        }
    }

    // MARK: - 3. The rendered image

    /// The whole node against a `Double` CPU rasterisation of the same mesh, on a
    /// real a6300 frame. docs/PLAN.md Phase 2's bar is **45 dB**.
    @Test("The rendered warp matches the Double CPU reference at ≥ 45 dB")
    func renderedWarpMatchesTheCPUReference() throws {
        guard let context = SpikeS3Support.context else { return }
        guard let fixture = try WarpImageFixture.load(side: 640) else {
            print("P2 warp rendered image: SKIP (a6300 image fixture absent)")
            return
        }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let request = Self.request(Self.allSliders, faces: [fixture.face], quality: .preview)
        let (output, report) = try graph.renderPixels(
            fixture.pixels, width: fixture.width, height: fixture.height, request: request)
        #expect(report.nodes == ["warp"])

        let built = try #require(
            FaceReshape.controlPoints(
                faces: [fixture.face], sliders: Self.allSliders,
                imageSize: CGSize(width: fixture.width, height: fixture.height)))
        let reference = WarpReference.render(
            source: fixture.pixels, width: fixture.width, height: fixture.height,
            control: built.control, options: FaceReshape.options(for: .preview))

        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print(
            "P2 warp rendered image vs Double CPU reference (\(fixture.image), "
                + "\(fixture.width)x\(fixture.height), \(built.handles.count) handles, "
                + "max displacement \(built.maxDisplacement) px): PSNR = \(psnr) dB, "
                + "max abs = \(worst)")
        #expect(psnr >= 45, "rendered PSNR \(psnr) dB")

        // …and the warp must actually have moved the picture, or an unwarped
        // output would score infinity against an unwarped reference.
        let change = SpikeTextureIO.maxAbsoluteDifference(fixture.pixels, output)
        #expect(change > 0.05, "the warp changed the picture by only \(change)")
    }

    /// A single slider must move the part of the picture it names and leave the
    /// rest alone. Measured on the image, not on the handles, so it also covers
    /// the case where the deformation is right but the mesh smears it.
    @Test("A local slider changes a local part of the picture")
    func aLocalSliderChangesALocalRegion() throws {
        guard let context = SpikeS3Support.context else { return }
        guard let fixture = try WarpImageFixture.load(side: 640) else {
            print("P2 warp locality: SKIP (a6300 image fixture absent)")
            return
        }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let (output, _) = try graph.renderPixels(
            fixture.pixels, width: fixture.width, height: fixture.height,
            request: Self.request(FaceSliders(lipFullness: 100), faces: [fixture.face]))

        // Locality has to be measured as an **energy ratio**, not as a count of
        // pixels over a threshold. A mesh warp resamples the whole frame, and
        // MLS's far field is only asymptotically the identity, so a hair or an
        // eyelash a long way from the mouth still moves by a hundredth of a
        // pixel and crosses any small absolute threshold. What "local" means is
        // that essentially all of the *change* is at the mouth.
        let mouth = FaceReshape.centroid(of: FaceMesh.lipsOuter, in: fixture.face.landmarks)
        let faceWidth = Double(fixture.face.faceWidth)
        var near = (sum: 0.0, count: 0, peak: 0.0)
        var far = (sum: 0.0, count: 0, peak: 0.0)
        var peakDistance = 0.0
        var peak = 0.0
        var peakPoint = CGPoint.zero
        for y in 0..<fixture.height {
            for x in 0..<fixture.width {
                let base = (y * fixture.width + x) * 4
                var delta = 0.0
                for c in 0..<3 {
                    delta = max(
                        delta, abs(Double(output[base + c]) - Double(fixture.pixels[base + c])))
                }
                let distance = Double(
                    hypot(Double(x) + 0.5 - Double(mouth.x), Double(y) + 0.5 - Double(mouth.y)))
                if delta > peak {
                    peak = delta
                    peakDistance = distance
                    peakPoint = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                }
                if distance < 0.5 * faceWidth {
                    near.sum += delta
                    near.count += 1
                    near.peak = max(near.peak, delta)
                } else if distance > 1.5 * faceWidth {
                    far.sum += delta
                    far.count += 1
                    far.peak = max(far.peak, delta)
                }
            }
        }
        let nearMean = near.sum / Double(max(1, near.count))
        let farMean = far.sum / Double(max(1, far.count))
        print(
            "P2 warp locality, lipFullness=100: mean |Δ| within 0.5×faceWidth of the mouth "
                + "\(nearMean) (peak \(near.peak)), beyond 1.5×faceWidth \(farMean) "
                + "(peak \(far.peak)); overall peak \(peak) at "
                + "\(peakDistance / faceWidth)×faceWidth from the mouth at \(peakPoint) "
                + "in a \(fixture.width)x\(fixture.height) frame, mouth at \(mouth)")
        #expect(near.peak > 0.05, "lipFullness barely changed the mouth: \(near.peak)")
        #expect(nearMean > 20 * farMean, "not local: near \(nearMean) vs far \(farMean)")
        #expect(far.peak < 0.05, "a pixel beyond 1.5×faceWidth changed by \(far.peak)")

        // The pixel *deltas* above are a property of the photograph as much as of
        // the warp — a quarter-pixel move across a lash or a nostril is a large
        // number, and on this frame the single biggest delta lands ~0.7×faceWidth
        // from the mouth for exactly that reason. So locality is also asserted on
        // the **deformation** itself, where image content cannot flatter or
        // damage it: how far does `f(v) − v` reach?
        let built = try #require(
            FaceReshape.controlPoints(
                faces: [fixture.face], sliders: FaceSliders(lipFullness: 100),
                imageSize: CGSize(width: fixture.width, height: fixture.height)))
        let options = FaceReshape.options(for: .preview)
        var atTheLip = 0.0
        for index in FaceMesh.lipsOuter {
            let p = fixture.face.landmarks[index]
            let f = MLSDeformation.evaluate(p, control: built.control, options: options)
            atTheLip = max(atTheLip, Double(hypot(f.x - p.x, f.y - p.y)))
        }
        var farField = 0.0
        var farFieldAt = CGPoint.zero
        for y in stride(from: 2, to: fixture.height, by: 8) {
            for x in stride(from: 2, to: fixture.width, by: 8) {
                let p = CGPoint(x: Double(x), y: Double(y))
                guard hypot(Double(p.x) - Double(mouth.x), Double(p.y) - Double(mouth.y))
                    > 1.5 * faceWidth
                else { continue }
                let f = MLSDeformation.evaluate(p, control: built.control, options: options)
                let d = Double(hypot(f.x - p.x, f.y - p.y))
                if d > farField {
                    farField = d
                    farFieldAt = p
                }
            }
        }
        print(
            "P2 warp locality (deformation): |f(v) − v| = \(atTheLip) px on the outer lip ring, "
                + "\(farField) px worst beyond 1.5×faceWidth (at \(farFieldAt))")
        #expect(atTheLip > 1, "the lip barely moved: \(atTheLip) px")
        #expect(farField < atTheLip / 20, "the far field is \(farField) px")
    }

    @Test("Two faces in one frame are both reshaped")
    func twoFacesAreBothReshaped() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterWarpRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableWarpRenderGraph() } }

        let node = try WarpRenderNode(context: context)
        let a = SyntheticFaceMesh.renderInput(width: 90, centre: CGPoint(x: 110, y: 120))
        let b = SyntheticFaceMesh.renderInput(width: 70, centre: CGPoint(x: 250, y: 118))
        let one = try #require(
            node.controlPoints(
                for: Self.request(Self.allSliders, faces: [a]),
                imageSize: CGSize(width: 360, height: 240)))
        let two = try #require(
            node.controlPoints(
                for: Self.request(Self.allSliders, faces: [a, b]),
                imageSize: CGSize(width: 360, height: 240)))
        #expect(two.handles.count == one.handles.count * 2)
        #expect(two.borderAnchorCount == one.borderAnchorCount)

        // And the render really does change near both faces.
        let (source, output) = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [a, b]), width: 360, height: 240)
        func changed(around centre: CGPoint, radius: Int) -> Int {
            var count = 0
            for y in max(0, Int(centre.y) - radius)...min(239, Int(centre.y) + radius) {
                for x in max(0, Int(centre.x) - radius)...min(359, Int(centre.x) + radius) {
                    let base = (y * 360 + x) * 4
                    if abs(Double(source[base]) - Double(output[base])) > 0.01 { count += 1 }
                }
            }
            return count
        }
        #expect(changed(around: a.landmarks[FaceMesh.chin], radius: 40) > 20)
        #expect(changed(around: b.landmarks[FaceMesh.chin], radius: 40) > 20)
    }

    // MARK: - Helpers

    /// Encodes one node source → destination and reads the result back as
    /// float32, returning the (quantised) source alongside so a bit-exactness
    /// check compares like with like.
    ///
    /// The destination carries `.renderTarget`: this node's second pass is a
    /// **render** pass, not a compute one, which is a constraint on every texture
    /// the graph hands it (`RenderGraph`'s pool and `renderPixels`' destination
    /// both already declare it).
    static func runNode(
        _ node: WarpRenderNode, context: MetalContext, request: RenderRequest,
        width: Int, height: Int
    ) throws -> (source: [Float], output: [Float]) {
        let pixels = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(
                SpikeS3Support.syntheticImage(width: width, height: height, seed: 99)))
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (pixels, try RenderGraph.readFloat32(destination, queue: context.commandQueue))
    }
}

/// One real a6300 frame plus its real mesh, resampled to a size a `Double` CPU
/// rasteriser can be run on inside a unit test.
struct WarpImageFixture {
    var image: String
    var pixels: [Float]
    var width: Int
    var height: Int
    var face: FaceRenderInput

    /// `nil` when the image fixture is absent (it is a research artefact, not a
    /// bundled resource).
    static func load(side: Int, name: String? = nil) throws -> WarpImageFixture? {
        let meshes = FaceLandmarkFixtures.a6300
        guard
            let mesh = name.flatMap({ n in meshes.first { $0.image == n } }) ?? meshes.first,
            let url = FaceLandmarkFixtures.cropImageURL(mesh)
        else { return nil }
        let image = try SpikeS3BenchTests.loadUpright(url)
        let scale = CGFloat(side) / max(mesh.imageSize.width, mesh.imageSize.height)
        let width = Int((mesh.imageSize.width * scale).rounded())
        let height = Int((mesh.imageSize.height * scale).rounded())
        let (pixels, _, _) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded, width: width, height: height)
        // The GPU reads an rgba16Float source, so the reference must start from
        // the same quantised values or it is charged 5e-4 of upload rounding the
        // kernel did not cause.
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))
        let scaled = FaceLandmarkFixtures.scaled(mesh, by: scale)
        return WarpImageFixture(
            image: mesh.image, pixels: quantised, width: width, height: height,
            face: FaceLandmarkFixtures.renderInput(scaled))
    }
}

/// The two geometric accuracy numbers, computed by the same code the tests
/// assert on and the bench files.
enum WarpAccuracy {
    struct Result {
        var image: String
        var quality: RenderQuality
        var renderSize: CGSize
        var handleCount: Int
        var movedHandleCount: Int
        var maxDisplacementPx: Double
        var maxDisplacementOverFaceWidth: Double
        /// Level 1: max `|GPU − CPU|` over the whole lattice, in pixels.
        var maxGridErrorPx: Double
        /// Level 2: max `|mesh(p_i) − q_i|` over the moved handles, in pixels.
        var maxRoundTripPx: Double
        var meanRoundTripPx: Double
        var maxRoundTripOverFaceWidth: Double
    }

    /// Runs the node once on an **uninitialised** texture of the mesh's own size.
    ///
    /// The pixels are irrelevant here — only the solved lattice is read back —
    /// and skipping the upload keeps a 7 MP accuracy pass off the CPU. The draw
    /// still happens, so the render pass is exercised; the image-level check is
    /// `renderedWarpMatchesTheCPUReference`'s job.
    static func measure(
        node: WarpRenderNode, context: MetalContext,
        mesh: FaceLandmarkFixtures.Mesh, quality: RenderQuality, sliders: FaceSliders
    ) throws -> Result {
        // A preview renders at 2048 px long edge (docs/PLAN.md §1.4); an export
        // renders the frame as it is.
        let scaled: FaceLandmarkFixtures.Mesh
        switch quality {
        case .preview:
            let longEdge = max(mesh.imageSize.width, mesh.imageSize.height)
            scaled = FaceLandmarkFixtures.scaled(mesh, by: 2048 / longEdge)
        case .export:
            scaled = mesh
        }
        let width = Int(scaled.imageSize.width)
        let height = Int(scaled.imageSize.height)
        let face = FaceLandmarkFixtures.renderInput(scaled)
        var state = EditState()
        sliders.write(into: &state)
        let request = RenderRequest(editState: state, faces: [face], quality: quality)

        let source = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba16Float,
            usage: [.shaderRead, .renderTarget])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let solved = node.debugDeformedGrid(),
            let built = FaceReshape.controlPoints(
                faces: [face], sliders: sliders,
                imageSize: CGSize(width: width, height: height))
        else { throw MetalContext.Failure.noCommandQueue }

        let options = FaceReshape.options(for: quality)
        let imageSize = CGSize(width: width, height: height)
        let cpu = MLSDeformation.grid(
            control: built.control, options: options, imageSize: imageSize)
        var gridError = 0.0
        for i in 0..<cpu.count {
            gridError = max(
                gridError,
                Double(hypot(solved.points[i].x - cpu[i].x, solved.points[i].y - cpu[i].y)))
        }

        var worstRoundTrip = 0.0
        var sumRoundTrip = 0.0
        var moved = 0
        for handle in built.handles where handle.displacement > 0 {
            let landed = MLSDeformation.interpolate(
                grid: solved.points, gridWidth: solved.grid, gridHeight: solved.grid,
                at: handle.source, imageSize: imageSize)
            let error = Double(
                hypot(landed.x - handle.destination.x, landed.y - handle.destination.y))
            worstRoundTrip = max(worstRoundTrip, error)
            sumRoundTrip += error
            moved += 1
        }

        return Result(
            image: mesh.image, quality: quality, renderSize: imageSize,
            handleCount: built.handles.count, movedHandleCount: built.movedHandleCount,
            maxDisplacementPx: Double(built.maxDisplacement),
            maxDisplacementOverFaceWidth: Double(built.maxDisplacement / face.faceWidth),
            maxGridErrorPx: gridError,
            maxRoundTripPx: worstRoundTrip,
            meanRoundTripPx: moved > 0 ? sumRoundTrip / Double(moved) : 0,
            maxRoundTripOverFaceWidth: Double(CGFloat(worstRoundTrip) / face.faceWidth))
    }
}
