import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 — the graph itself, with no GPU maths in it.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 RenderGraph", .serialized)
struct RenderGraphTests {

    /// The graph itself carries no flag — every measured algorithm is in a node
    /// that does. With all of them off `standard` builds nothing and the picture
    /// still arrives, which is the shipping default.
    @Test("With every group flag off the standard graph is empty, not a throw")
    func noGroupFlagMeansAnEmptyGraph() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.colorSliders = false
            RPEngineFeatureFlags.skinSliders = false
            RPEngineFeatureFlags.warpSliders = false
            RPEngineFeatureFlags.eyesTeethSliders = false
        }
        defer { flags.leave { RPEngineFeatureFlags.disableSkinRenderGraph() } }
        let graph = try RenderGraph.standard(context: context)
        #expect(graph.nodes.isEmpty)

        let width = 24, height = 16
        let pixels = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(
                SpikeS3Support.syntheticImage(width: width, height: height, seed: 11)))
        let (output, report) = try graph.renderPixels(
            pixels, width: width, height: height, request: RenderRequest())
        #expect(report.isPassthrough)
        #expect(SpikeTextureIO.maxAbsoluteDifference(pixels, output) == 0)
    }

    @Test("Constructing the skin node needs its own flag")
    func skinNodeHasItsOwnFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.skinSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.disableSkinRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) { try SkinRenderNode(context: context) }
    }

    /// **Regression, review round 3.** The two slider groups used to share one
    /// stored `renderGraph` flag that both `enable…`/`disable…` pairs wrote, so
    /// this exact ordering — enable both, then turn *one* off — left the other
    /// group's flags on while `RenderGraph.standard()` threw
    /// `RPEngineFeatureDisabled(feature: "renderGraph")`. Nothing exercised the
    /// ordering, so the suite stayed green. The flag is gone (docs/ADR-0010);
    /// this is what says it stays gone.
    @Test("Disabling one slider group leaves the other one running")
    func disablingOneGroupLeavesTheOtherRunning() throws {
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
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["skin", "warp"])

        // Mặt off → Da untouched, and its node still registers.
        RPEngineFeatureFlags.disableWarpRenderGraph()
        #expect(RPEngineFeatureFlags.skinSliders)
        #expect(RPEngineFeatureFlags.guidedFilter)
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["skin"])

        // …and symmetrically: Da off → Mặt untouched.
        RPEngineFeatureFlags.enableWarpRenderGraph()
        RPEngineFeatureFlags.disableSkinRenderGraph()
        #expect(RPEngineFeatureFlags.warpSliders)
        #expect(RPEngineFeatureFlags.mlsMeshWarp)
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["warp"])

        // Both off: an empty graph, because the graph is not itself flagged.
        RPEngineFeatureFlags.disableWarpRenderGraph()
        #expect(try RenderGraph.standard(context: context).nodes.isEmpty)
    }

    /// **The same regression, one level down.** The "Da" and "Mắt / Răng" groups
    /// are independent, but both are built on the `guidedFilter` *kernel*, so
    /// `disableSkinRenderGraph()` clearing that flag unconditionally would
    /// recreate the exact failure the umbrella `renderGraph` flag was deleted
    /// for: turning one group off making `RenderGraph.standard()` throw for the
    /// other. `RPEngineFeatureFlags.disableSkinRenderGraph()` therefore only
    /// clears the kernel flag when no other group still wants it.
    @Test("Disabling the Da group leaves the Mắt/Răng group running, and vice versa")
    func disablingTheSkinGroupLeavesTheEyesTeethGroupRunning() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableSkinRenderGraph()
                RPEngineFeatureFlags.disableEyesTeethRenderGraph()
            }
        }
        #expect(
            try RenderGraph.standard(context: context).nodes.map(\.name)
                == ["skin", "eyesTeeth"])

        // Da off → the shared kernel flag stays on, because Mắt/Răng needs it.
        RPEngineFeatureFlags.disableSkinRenderGraph()
        #expect(RPEngineFeatureFlags.eyesTeethSliders)
        #expect(RPEngineFeatureFlags.guidedFilter)
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["eyesTeeth"])

        // …and symmetrically.
        RPEngineFeatureFlags.enableSkinRenderGraph()
        RPEngineFeatureFlags.disableEyesTeethRenderGraph()
        #expect(RPEngineFeatureFlags.skinSliders)
        #expect(RPEngineFeatureFlags.guidedFilter)
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["skin"])

        // Last one out turns the kernel off.
        RPEngineFeatureFlags.disableSkinRenderGraph()
        #expect(!RPEngineFeatureFlags.guidedFilter)
        #expect(try RenderGraph.standard(context: context).nodes.isEmpty)
    }

    @Test("Constructing the eyes/teeth node needs its own flag")
    func eyesTeethNodeHasItsOwnFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.eyesTeethSliders = false
            RPEngineFeatureFlags.guidedFilter = true
        }
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) {
            try EyesTeethRenderNode(context: context)
        }
    }

    @Test("Constructing the color node needs its own flag")
    func colorNodeHasItsOwnFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.colorSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) { try ColorRenderNode(context: context) }
    }

    /// The "Color" group borrows **no** kernel flag — it owns all four of its
    /// kernels — so its disable helper is unconditional and still cannot take
    /// another group down. This is the same regression as
    /// `disablingOneGroupLeavesTheOtherRunning`, checked for the fourth group.
    @Test("Disabling the Color group leaves every other group running")
    func disablingTheColorGroupLeavesTheOthersRunning() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableColorRenderGraph()
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableColorRenderGraph()
                RPEngineFeatureFlags.disableSkinRenderGraph()
                RPEngineFeatureFlags.disableEyesTeethRenderGraph()
            }
        }
        #expect(
            try RenderGraph.standard(context: context).nodes.map(\.name)
                == ["color", "skin", "eyesTeeth"])

        RPEngineFeatureFlags.disableColorRenderGraph()
        #expect(RPEngineFeatureFlags.skinSliders)
        #expect(RPEngineFeatureFlags.eyesTeethSliders)
        #expect(RPEngineFeatureFlags.guidedFilter)
        #expect(
            try RenderGraph.standard(context: context).nodes.map(\.name) == ["skin", "eyesTeeth"])

        // …and symmetrically: turning the other groups off leaves Color alone,
        // because it never wanted their kernel flags in the first place.
        RPEngineFeatureFlags.enableColorRenderGraph()
        RPEngineFeatureFlags.disableSkinRenderGraph()
        RPEngineFeatureFlags.disableEyesTeethRenderGraph()
        #expect(RPEngineFeatureFlags.colorSliders)
        #expect(try RenderGraph.standard(context: context).nodes.map(\.name) == ["color"])
    }

    /// All four groups on at once: the graph must run them in the order
    /// docs/PLAN.md §2 fixes, whatever order they were registered in.
    @Test("All four shipped groups sort into the plan's stage order")
    func fourGroupsSortByStage() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableColorRenderGraph()
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableWarpRenderGraph()
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableColorRenderGraph()
                RPEngineFeatureFlags.disableSkinRenderGraph()
                RPEngineFeatureFlags.disableWarpRenderGraph()
                RPEngineFeatureFlags.disableEyesTeethRenderGraph()
            }
        }
        let graph = try RenderGraph.standard(context: context)
        #expect(graph.nodes.map(\.name) == ["color", "skin", "warp", "eyesTeeth"])
        #expect(graph.nodes.map(\.stage) == [.color, .skin, .warp, .eyesTeeth])
    }

    /// The 0-default rule for this group at the graph level.
    @Test("The eyes/teeth node stays inactive when the image has no eye or mouth mask")
    func noEyeOrMouthMaskMeansNoWork() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }
        let graph = try RenderGraph.standard(context: context)
        var state = EditState()
        EyesTeethSliders(eyeBrighten: 100, teethWhiten: 100).write(into: &state)
        #expect(graph.activeNodes(for: RenderRequest(editState: state, faces: [])).isEmpty)
        // A face carrying only the skin mask is not enough either.
        let skinOnly = SkinReference.face(imageWidth: 64, imageHeight: 64)
        #expect(
            graph.activeNodes(for: RenderRequest(editState: state, faces: [skinOnly])).isEmpty)
        // …but the fixture face, which carries both kinds, is.
        #expect(
            graph.activeNodes(
                for: RenderRequest(editState: state, faces: [EyesTeethRenderNodeTests.face])
            ).map(\.name) == ["eyesTeeth"])
    }

    @Test("Nodes run in the order docs/PLAN.md §2 fixes, not in registration order")
    func nodesAreSortedByStage() throws {
        guard let context = SpikeS3Support.context else { return }
        let makeup = InertNode(name: "makeup", stage: .makeup, context: context)
        let color = InertNode(name: "color", stage: .color, context: context)
        let warp = InertNode(name: "warp", stage: .warp, context: context)
        let graph = RenderGraph(context: context, nodes: [makeup, warp, color])
        #expect(graph.nodes.map(\.name) == ["color", "warp", "makeup"])
    }

    /// The 0-default rule at the graph level: an untouched document runs no node
    /// and the picture still arrives in `destination`.
    @Test("An empty EditState renders nothing and blits the source through")
    func emptyEditStateIsPassthrough() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        let graph = try RenderGraph.standard(context: context)

        let width = 48, height = 32
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 5)
        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        let request = RenderRequest(
            editState: EditState(),
            faces: [SkinReference.face(imageWidth: width, imageHeight: height)])
        let (output, report) = try graph.renderPixels(
            quantised, width: width, height: height, request: request)

        #expect(report.isPassthrough)
        #expect(report.nodes.isEmpty)
        #expect(SpikeTextureIO.maxAbsoluteDifference(quantised, output) == 0)
    }

    /// "Giữ texture" is a modifier on "Mịn da", so a document that sets only it
    /// must still be an identity — otherwise moving one slider would change the
    /// picture with the effect it modifies switched off.
    @Test("keepTexture alone is an identity")
    func keepTextureAloneIsIdentity() {
        var state = EditState()
        state.setSlider(
            SkinSliders.Key.keepTexture, in: EditState.SectionKey.skin, to: 100)
        #expect(SkinSliders(state).isIdentity)
        state.setSlider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin, to: 1)
        #expect(!SkinSliders(state).isIdentity)
    }

    @Test("Every Da slider round-trips through EditState and clamps to 0…100")
    func slidersRoundTripThroughEditState() {
        let sliders = SkinSliders(
            smooth: 40, keepTexture: 25, evenTone: 10, redness: 60, shine: 5,
            brighten: 30, darkCircle: 70, wrinkle: 15)
        var state = EditState()
        sliders.write(into: &state)
        #expect(SkinSliders(state) == sliders)
        // Out of range is clamped, not rejected.
        #expect(SkinSliders(smooth: 400).smooth == 100)
        #expect(SkinSliders(smooth: -10).smooth == 0)
        #expect(SkinSliders(smooth: .nan).smooth == 0)
        // A zeroed slider leaves no key behind (EditSection.setSlider's contract).
        var zeroed = state
        SkinSliders().write(into: &zeroed)
        #expect(zeroed.isDefault)
    }

    @Test("The skin node stays inactive when the image has no face")
    func noFaceMeansNoWork() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        let graph = try RenderGraph.standard(context: context)
        var state = EditState()
        state.setSlider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin, to: 100)
        #expect(graph.activeNodes(for: RenderRequest(editState: state, faces: [])).isEmpty)
        let face = SkinReference.face(imageWidth: 64, imageHeight: 64)
        #expect(
            graph.activeNodes(for: RenderRequest(editState: state, faces: [face])).map(\.name)
                == ["skin"])
    }

    /// A preview renders at 2048 px while `FaceAnalyzer` ran on the full frame,
    /// so this conversion happens on every preview and getting it wrong puts the
    /// mask half a face out of place.
    @Test("Scaling a face scales the geometry and leaves the mask bytes alone")
    func scalingAFaceMovesOnlyTheTransform() throws {
        let face = SkinReference.face(imageWidth: 400, imageHeight: 400, faceWidth: 200)
        let scaled = face.scaled(by: 0.5)
        #expect(scaled.faceWidth == 100)
        let original = try #require(face.masks[.skin])
        let half = try #require(scaled.masks[.skin])
        #expect(half.values == original.values)
        #expect(half.width == original.width)
        // A mask pixel must land on half the image coordinate it used to.
        let probe = CGPoint(x: 17, y: 41)
        let before = probe.applying(original.maskToImage)
        let after = probe.applying(half.maskToImage)
        #expect(abs(after.x - before.x / 2) < 1e-9)
        #expect(abs(after.y - before.y / 2) < 1e-9)
        // …and the inverse a caller actually uses must round-trip.
        let back = after.applying(half.imageToMask)
        #expect(abs(back.x - probe.x) < 1e-6)
        #expect(abs(back.y - probe.y) < 1e-6)
    }

    @Test("Source and destination of different sizes is rejected, not silently cropped")
    func sizeMismatchThrows() throws {
        guard let context = SpikeS3Support.context else { return }
        let graph = RenderGraph(context: context, nodes: [])
        let a = try SpikeTextureIO.makeTexture(
            width: 8, height: 8, device: context.device, usage: [.shaderRead, .shaderWrite])
        let b = try SpikeTextureIO.makeTexture(
            width: 8, height: 4, device: context.device, usage: [.shaderRead, .shaderWrite])
        #expect(throws: RenderGraphError.self) {
            try graph.render(source: a, destination: b, request: RenderRequest())
        }
    }

    /// Radii are fractions of face width, which is what makes a preset transfer
    /// between a head-and-shoulders frame and a full-length one.
    @Test("Blur radii scale with face width and stay inside their bounds")
    func radiiScaleWithFaceWidth() {
        #expect(SkinRenderNode.smoothRadius(faceWidth: 600) == 18)
        #expect(SkinRenderNode.lowRadius(faceWidth: 600) == 90)
        // A tiny face must still get a usable radius rather than 0 (a 0-radius
        // box is the identity, which reads as "the slider did nothing").
        #expect(SkinRenderNode.smoothRadius(faceWidth: 4) == 2)
        #expect(SkinRenderNode.lowRadius(faceWidth: 4) == 4)
        // …and a 24 MP frame must not ask for an unbounded box.
        #expect(SkinRenderNode.smoothRadius(faceWidth: 100_000) == 96)
        #expect(SkinRenderNode.lowRadius(faceWidth: 100_000) == 256)
        #expect(SkinRenderNode.smoothRadius(faceWidth: .nan) == 2)
    }

    @Test("The mandatory S3 configuration is what RenderQuality reports")
    func qualityCarriesTheS3Constraints() {
        #expect(RenderQuality.preview.guidedSubsample == 4)
        #expect(RenderQuality.export.guidedSubsample == 4)
        #expect(RenderQuality.preview.meshGrid == 65)
        #expect(RenderQuality.export.meshGrid == 129)
        #expect(RenderQuality.preview.pixelSpace == .sRGBEncoded)
        #expect(RenderQuality.export.pixelSpace == .sRGBEncoded)
    }

    @Test("Every shader source is in the bundle and they compile into one library")
    func shaderSourcesAreAllPresent() throws {
        guard let context = SpikeS3Support.context else { return }
        // Five files (spike S3 + Da + Mắt/Răng + Color + the live preview's
        // present pass), still **one** `makeLibrary(source:)` call and therefore
        // one compile per process — the property `RenderGraph.prewarm()` relies
        // on.
        #expect(MetalContext.shaderSources.count == 5)
        // A missing resource would surface as `shaderSourceMissing` at init, but
        // a source that compiled and produced no symbols would not.
        for name in [
            "rp_gf_reconstruct", "rp_mls_grid", "rp_skin_mask", "rp_skin_composite",
            "rp_eyes_teeth_composite", "rp_color_composite", "rp_color_luma_downsample",
            "rp_color_box_h", "rp_color_box_v", "rp_preview_present",
        ] {
            #expect(throws: Never.self) { _ = try context.computePipeline(name) }
        }
    }

    /// A node that reports itself active and copies its input, so the graph's
    /// ping-pong can be exercised without any real maths.
    private final class InertNode: RenderNode, @unchecked Sendable {
        let name: String
        let stage: RenderStage
        let context: MetalContext
        init(name: String, stage: RenderStage, context: MetalContext) {
            self.name = name
            self.stage = stage
            self.context = context
        }
        func isActive(for request: RenderRequest) -> Bool { true }
        func prewarm() throws {}
        func encode(
            into commandBuffer: any MTLCommandBuffer, source: any MTLTexture,
            destination: any MTLTexture, request: RenderRequest
        ) throws {
            // `rp_render_copy`, not a blit: the last node writes into an
            // rgba32Float destination while the pool is rgba16Float, and a blit
            // across formats is illegal.
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source,
                destination: destination)
        }
    }

    /// Three copy-only nodes chained through the pool must still deliver the
    /// original pixels — i.e. the ping-pong never hands a node the texture it is
    /// writing to.
    @Test("Chaining three nodes through the intermediate pool preserves the picture")
    func pingPongPreservesPixels() throws {
        guard let context = SpikeS3Support.context else { return }
        let graph = RenderGraph(
            context: context,
            nodes: [
                InertNode(name: "a", stage: .color, context: context),
                InertNode(name: "b", stage: .skin, context: context),
                InertNode(name: "c", stage: .warp, context: context),
            ])
        let width = 37, height = 21
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 9)
        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        let (output, report) = try graph.renderPixels(
            quantised, width: width, height: height, request: RenderRequest())
        #expect(report.nodes == ["a", "b", "c"])
        #expect(report.poolBytes > 0)
        // The pool is rgba32Float here (renderPixels' destination format), so the
        // copies are lossless and this is an exact comparison.
        #expect(SpikeTextureIO.maxAbsoluteDifference(quantised, output) == 0)
        graph.releaseIntermediates()
    }
}
