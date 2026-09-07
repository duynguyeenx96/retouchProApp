import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 golden tests for the "Mắt / Răng" slider group.
///
/// docs/PLAN.md Phase 2 sets the bar: **golden render PSNR ≥ 45 dB**. The
/// control is `EyesTeethReference`, a `Double` CPU implementation written from
/// the specification rather than from the shader, in the same arrangement the
/// "Da" group uses (`SkinReference`).
///
/// Three levels, so a failure says *where*:
/// 1. `rp_skin_mask` (through `MaskRasteriser`) for **both** kinds, against a
///    `Double` affine + bilinear + max;
/// 2. `rp_eyes_teeth_composite` fed the **GPU's own** `low` layer, which isolates
///    the composite from the guided filter;
/// 3. the whole node against the whole reference.
///
/// Plus a fourth thing PSNR cannot say: **selectivity** — whether the whitening
/// weight actually lands on teeth rather than on gums, and on sclera rather than
/// on iris. A reference agreeing with the shader proves the formula was
/// transcribed correctly; only the region measurements below say the formula
/// picks the right pixels.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 eyes/teeth sliders", .serialized)
struct EyesTeethRenderNodeTests {
    static let portrait = EyesTeethReference.portrait()
    static var width: Int { portrait.width }
    static var height: Int { portrait.height }
    static var source: [Float] { portrait.pixels }
    static var face: FaceRenderInput { portrait.face }

    /// Every slider at a mid value, so no term of the composite is skipped.
    static let allSliders = EyesTeethSliders(
        eyeBrighten: 60, scleraWhiten: 70, eyeDefinition: 45, teethWhiten: 80)

    static func request(
        _ sliders: EyesTeethSliders, faces: [FaceRenderInput]? = nil,
        quality: RenderQuality = .preview
    ) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        return RenderRequest(editState: state, faces: faces ?? [face], quality: quality)
    }

    // MARK: - Layout

    @Test("The shader parameter struct has the layout EyesTeethShaders.metal declares")
    func parameterStructMatchesShaderLayout() {
        #expect(MemoryLayout<EyesTeethParams>.stride == 24)  // uint2 + 4 floats
    }

    // MARK: - 1. Mask rasterisation, both kinds

    @Test("Both masks rasterise to a Double affine + bilinear reference")
    func maskRasterisationMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        let layers = try #require(node.debugLayers())

        for (kind, texture) in [(RenderMaskKind.eyes, layers.eyes), (.mouth, layers.mouth)] {
            let measured = try SkinRenderNodeTests.readR8(
                try #require(texture), queue: context.commandQueue)
            let reference = EyesTeethReference.rasterisedMask(
                faces: [Self.face], kind: kind, width: Self.width, height: Self.height)
            var worst = 0.0
            for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
            print("P2 eyes/teeth \(kind) mask vs Double reference: max abs diff = \(worst)")
            // r8Unorm quantises to 1/255 = 3.9e-3; the source is already 8-bit, so
            // the only new error is one bilinear tap plus that rounding. A wrong
            // transform shifts the mask by whole pixels and lands far above 6e-3.
            #expect(worst < 6e-3, "\(kind) max abs diff \(worst)")

            // A nearly-right transform can also give a plausibly small error, so
            // assert the mask is somewhere: it must cover part of the frame and
            // not all of it. These are small objects — an eye pair is ~1 % of the
            // frame — so the bar is asymmetric on purpose.
            let coverage = measured.reduce(0, +) / Double(measured.count)
            #expect(coverage > 0.002 && coverage < 0.5, "\(kind) coverage \(coverage)")
        }
    }

    @Test("Masks that are 0 everywhere leave every pixel bit-exact")
    func zeroMaskIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var blank = Self.face
        for kind in [RenderMaskKind.eyes, .mouth] {
            let mask = try #require(blank.masks[kind])
            blank.masks[kind] = RenderMask(
                width: mask.width, height: mask.height,
                values: [UInt8](repeating: 0, count: mask.values.count),
                maskToImage: mask.maskToImage)
        }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(Self.allSliders, faces: [blank]))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    @Test("All sliders at 0 is a bit-exact identity even with full masks")
    func allSlidersZeroIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }
        let node = try EyesTeethRenderNode(context: context)
        // Straight at the node, bypassing RenderGraph's isActive short-circuit,
        // so this tests the kernel's own 0-handling and not the graph's.
        let output = try Self.runNode(
            node, context: context, request: Self.request(EyesTeethSliders()))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    /// Outside both masks nothing may move, whatever the sliders say — otherwise
    /// "Trắng răng" would bleach the lips it is drawn next to.
    @Test("Pixels outside both masks are bit-exact")
    func outsideTheMasksIsBitExact() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(Self.allSliders))
        let eye = EyesTeethReference.rasterisedMask(
            faces: [Self.face], kind: .eyes, width: Self.width, height: Self.height)
        let mouth = EyesTeethReference.rasterisedMask(
            faces: [Self.face], kind: .mouth, width: Self.width, height: Self.height)

        var touched = 0
        var outside = 0
        for i in 0..<eye.count where eye[i] == 0 && mouth[i] == 0 {
            outside += 1
            let o = i * 4
            for channel in 0..<3 where output[o + channel] != Self.source[o + channel] {
                touched += 1
            }
        }
        // The fixture must actually have somewhere outside both masks, or this
        // passes vacuously.
        #expect(outside > Self.width * Self.height / 2, "only \(outside) pixels outside")
        #expect(touched == 0, "\(touched) channels changed outside both masks")
    }

    // MARK: - 2. Composite

    @Test("rp_eyes_teeth_composite matches a Double reference fed the GPU's own layer")
    func compositeMatchesReferenceOnItsOwnLayer() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(Self.allSliders))
        let reference = try Self.compositeReference(
            node: node, context: context, sliders: Self.allSliders)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 eyes/teeth composite vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "composite PSNR \(psnr) dB")
    }

    /// Each slider on its own, so an error in one term cannot be hidden by the
    /// others' magnitude in the combined PSNR.
    @Test(
        "Each Mắt/Răng slider alone matches the reference",
        arguments: [
            ("eyeBrighten", EyesTeethSliders(eyeBrighten: 100)),
            ("scleraWhiten", EyesTeethSliders(scleraWhiten: 100)),
            ("eyeDefinition", EyesTeethSliders(eyeDefinition: 100)),
            ("teethWhiten", EyesTeethSliders(teethWhiten: 100)),
        ])
    func eachSliderAloneMatchesReference(name: String, sliders: EyesTeethSliders) throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(sliders))
        let reference = try Self.compositeReference(
            node: node, context: context, sliders: sliders)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 eyes/teeth slider '\(name)' vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "\(name) PSNR \(psnr) dB")

        // …and it must actually do something, or a PSNR of infinity would pass.
        let change = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        #expect(change > 1e-3, "\(name) changed the picture by only \(change)")
    }

    // MARK: - 3. Whole node

    @Test("The whole Mắt/Răng node matches the whole Double reference at ≥ 45 dB")
    func wholeNodeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let (output, report) = try graph.renderPixels(
            Self.source, width: Self.width, height: Self.height,
            request: Self.request(Self.allSliders))
        #expect(report.nodes == ["eyesTeeth"])

        let reference = EyesTeethReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders,
            subsample: RenderQuality.preview.guidedSubsample)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 eyes/teeth node end-to-end vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "end-to-end PSNR \(psnr) dB")
    }

    // MARK: - 4. Selectivity — does the heuristic pick the right pixels?

    /// **The claim a PSNR cannot make.** There is no teeth class in
    /// CelebAMask-HQ, so "Trắng răng" derives teeth from luminance and
    /// saturation inside the mouth *interior* mask, which also contains gums.
    /// A slider that whitened the mask uniformly would pass every test above.
    ///
    /// Measured on the synthetic portrait, whose regions are known by
    /// construction: mean |Δ| on teeth against mean |Δ| on gums.
    @Test("Trắng răng moves teeth far more than the gums in the same mask")
    func teethWhiteningIsSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(EyesTeethSliders(teethWhiten: 100)))
        let teeth = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .teeth)
        let gums = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .gums)
        let skin = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .skin)
        print(
            "P2 eyes/teeth selectivity, teethWhiten=100: teeth \(teeth), gums \(gums), skin \(skin)"
        )
        #expect(teeth > 0.02, "teeth barely moved (\(teeth))")
        #expect(teeth > gums * 5, "teeth \(teeth) vs gums \(gums) — not selective")
        // Skin is outside the *hard* mouth ellipse, but the mask is feathered
        // (which is mandatory — spike S2 §4), so its ramp reaches a little past
        // that ellipse and the skin change is small rather than exactly zero.
        // Measured 3.9e-7 against 0.025 on teeth, i.e. ~64 000x smaller.
        #expect(skin < teeth / 1000, "skin moved by \(skin) against teeth \(teeth)")
    }

    /// The same claim for "Trắng lòng trắng": the eye mask is the whole opening,
    /// so the slider has to find the sclera inside it and leave the iris alone.
    @Test("Trắng lòng trắng moves the sclera far more than the iris in the same mask")
    func scleraWhiteningIsSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(EyesTeethSliders(scleraWhiten: 100)))
        let sclera = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .sclera)
        let iris = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .iris)
        let pupil = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .pupil)
        print(
            "P2 eyes/teeth selectivity, scleraWhiten=100: sclera \(sclera), iris \(iris), pupil \(pupil)"
        )
        #expect(sclera > 0.01, "sclera barely moved (\(sclera))")
        #expect(sclera > iris * 5, "sclera \(sclera) vs iris \(iris) — not selective")
        #expect(pupil <= iris, "the pupil moved more than the iris")
    }

    /// "Sáng mắt" is the opposite claim: it is *not* selective inside the eye —
    /// it lifts the whole opening, which is what the slider means. Stated as a
    /// test so a later "improvement" that quietly restricts it to the sclera is
    /// a failure and not a silent change of behaviour.
    @Test("Sáng mắt lifts the whole eye opening, iris included")
    func eyeBrightenCoversTheWholeOpening() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(EyesTeethSliders(eyeBrighten: 100)))
        let sclera = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .sclera)
        let iris = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .iris)
        let teeth = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .teeth)
        print("P2 eyes/teeth brighten: sclera \(sclera), iris \(iris), teeth \(teeth)")
        #expect(iris > 0.05, "the iris was not lifted (\(iris))")
        // A gamma lift moves a dark value further than a bright one, so the iris
        // must move *more* than the sclera. That is the shape of the curve, and
        // asserting it here pins the direction as well as the presence.
        #expect(iris > sclera, "iris \(iris) should move more than sclera \(sclera)")
        // Nothing in the mouth may move: this slider does not read that mask.
        #expect(teeth == 0, "teeth moved by \(teeth) on an eye-only slider")
    }

    // MARK: - Mask availability

    /// A face with no `.mouth` mask and only "Trắng răng" set must be inactive,
    /// not a full-frame no-op — and must not crash on a missing binding.
    @Test("A slider whose mask is absent is inactive, and the picture survives")
    func missingMaskIsInactive() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var eyesOnly = Self.face
        eyesOnly.masks[.mouth] = nil
        let node = try EyesTeethRenderNode(context: context)
        let teethRequest = Self.request(EyesTeethSliders(teethWhiten: 100), faces: [eyesOnly])
        #expect(!node.isActive(for: teethRequest))
        // Directly at the node (the graph would have skipped it): still exact.
        let output = try Self.runNode(node, context: context, request: teethRequest)
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)

        // …and the eye sliders still work on the same face, i.e. the missing
        // mouth mask did not disable the whole node.
        let both = Self.request(
            EyesTeethSliders(eyeBrighten: 100, teethWhiten: 100), faces: [eyesOnly])
        #expect(node.isActive(for: both))
        let mixed = try Self.runNode(node, context: context, request: both)
        let iris = EyesTeethReference.meanChange(
            Self.source, mixed, regions: Self.portrait.regions, .iris)
        let teeth = EyesTeethReference.meanChange(
            Self.source, mixed, regions: Self.portrait.regions, .teeth)
        #expect(iris > 0.05, "the eye slider stopped working (\(iris))")
        #expect(teeth == 0, "teeth moved with no mouth mask (\(teeth))")
    }

    /// The mirror image: a mouth mask but no eye mask.
    @Test("Teeth whitening works on a face that has only the mouth mask")
    func mouthOnlyFace() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var mouthOnly = Self.face
        mouthOnly.masks[.eyes] = nil
        let node = try EyesTeethRenderNode(context: context)
        let request = Self.request(
            EyesTeethSliders(eyeBrighten: 100, teethWhiten: 100), faces: [mouthOnly])
        #expect(node.isActive(for: request))
        let output = try Self.runNode(node, context: context, request: request)
        let teeth = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .teeth)
        let iris = EyesTeethReference.meanChange(
            Self.source, output, regions: Self.portrait.regions, .iris)
        #expect(teeth > 0.02, "teeth did not whiten (\(teeth))")
        #expect(iris == 0, "the iris moved with no eye mask (\(iris))")
    }

    @Test("Masks of different sizes in one request are rejected, not blended wrong")
    func inconsistentMaskSizesThrow() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var odd = Self.face
        let mask = try #require(odd.masks[.eyes])
        odd.masks[.eyes] = RenderMask(
            width: 32, height: 32, values: [UInt8](repeating: 128, count: 32 * 32),
            maskToImage: mask.maskToImage)
        let node = try EyesTeethRenderNode(context: context)
        #expect(throws: RenderGraphError.self) {
            _ = try Self.runNode(
                node, context: context,
                request: Self.request(Self.allSliders, faces: [Self.face, odd]))
        }
    }

    /// Two faces must combine with `max`, not with submission order.
    @Test("Two faces combine their eye masks with max")
    func twoFacesCombineWithMax() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        var second = Self.face
        for kind in [RenderMaskKind.eyes, .mouth] {
            let mask = try #require(second.masks[kind])
            second.masks[kind] = RenderMask(
                width: mask.width, height: mask.height, values: mask.values,
                maskToImage: mask.maskToImage.concatenating(
                    CGAffineTransform(translationX: 70, y: 20)))
        }

        let node = try EyesTeethRenderNode(context: context)
        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, faces: [Self.face, second]))
        let layers = try #require(node.debugLayers())
        let measured = try SkinRenderNodeTests.readR8(
            try #require(layers.eyes), queue: context.commandQueue)
        let a = EyesTeethReference.rasterisedMask(
            faces: [Self.face], kind: .eyes, width: Self.width, height: Self.height)
        let b = EyesTeethReference.rasterisedMask(
            faces: [second], kind: .eyes, width: Self.width, height: Self.height)
        var unionError = 0.0
        for i in 0..<a.count { unionError = max(unionError, abs(max(a[i], b[i]) - measured[i])) }
        print("P2 eyes/teeth two-face eye mask vs elementwise max: max abs diff = \(unionError)")
        #expect(unionError < 6e-3, "union != elementwise max, worst \(unionError)")
        // …and the two faces really do land in different places, or the above is
        // vacuous.
        #expect(measured.reduce(0, +) > a.reduce(0, +) * 1.1)
        #expect(measured.reduce(0, +) > b.reduce(0, +) * 1.1)
    }

    // MARK: - Quality → guided-filter subsample

    /// Regression test for the bug class ADR-0009 records: `Resources` sized from
    /// a hardcoded `RenderQuality.preview` while `encode` takes its box radius
    /// from the request's own quality. `GuidedFilter.encode` reads the grid size
    /// out of `Resources` and the radius out of `Options`, so the two have to
    /// agree; today they only would because `guidedSubsample` is 4 for both
    /// qualities. This node threads `request.quality` through from the start —
    /// this is what says it keeps doing so.
    @Test("The guided-filter cache follows the request's quality, not a fixed preview constant")
    func cacheFollowsTheRequestQuality() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        // The hypothetical split: export buys a finer grid than preview.
        let node = try EyesTeethRenderNode(
            context: context, subsampleForQuality: { $0 == .preview ? 4 : 2 })

        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        #expect(node.debugGuidedSubsample == 4)

        _ = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, quality: .export))
        #expect(node.debugGuidedSubsample == 2)

        // …and back, so the cache invalidates in both directions rather than
        // sticking on whichever quality rendered first.
        _ = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        #expect(node.debugGuidedSubsample == 4)
    }

    /// The bookkeeping above only matters if the pixels follow it.
    @Test("Rendering at a non-default subsample still matches the Double reference")
    func alternateSubsampleMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterEyesTeethRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableEyesTeethRenderGraph() } }

        let node = try EyesTeethRenderNode(context: context, subsampleForQuality: { _ in 2 })
        let output = try Self.runNode(
            node, context: context,
            request: Self.request(Self.allSliders, quality: .export))
        #expect(node.debugGuidedSubsample == 2)

        let reference = EyesTeethReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders, subsample: 2)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 eyes/teeth node at s=2 vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "s=2 PSNR \(psnr) dB")

        // And it is genuinely a different render from the s=4 one, or the test
        // would pass with the subsample ignored entirely.
        let atFour = EyesTeethReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            faces: [Self.face], sliders: Self.allSliders, subsample: 4)
        #expect(SpikeTextureIO.maxAbsoluteDifference(atFour, reference) > 1e-4)
    }

    // MARK: - Values

    @Test("Every Mắt/Răng slider round-trips through EditState and clamps to 0…100")
    func slidersRoundTripThroughEditState() {
        let sliders = EyesTeethSliders(
            eyeBrighten: 40, scleraWhiten: 25, eyeDefinition: 10, teethWhiten: 60)
        var state = EditState()
        sliders.write(into: &state)
        #expect(EyesTeethSliders(state) == sliders)
        // They live in their own section, not in the skin one.
        #expect(state.sections.keys.contains(EditState.SectionKey.eyesTeeth))
        #expect(SkinSliders(state).isIdentity)
        #expect(FaceSliders(state).isIdentity)
        // Out of range is clamped, not rejected.
        #expect(EyesTeethSliders(eyeBrighten: 400).eyeBrighten == 100)
        #expect(EyesTeethSliders(eyeBrighten: -10).eyeBrighten == 0)
        #expect(EyesTeethSliders(eyeBrighten: .nan).eyeBrighten == 0)
        // A zeroed slider leaves no key behind (EditSection.setSlider's contract).
        var zeroed = state
        EyesTeethSliders().write(into: &zeroed)
        #expect(zeroed.isDefault)
    }

    @Test("Which layers and masks each slider needs")
    func layerRequirements() {
        #expect(EyesTeethSliders().isIdentity)
        #expect(!EyesTeethSliders(teethWhiten: 1).isIdentity)
        // Sáng mắt needs no neighbourhood, so it must not pull in the 192 MB
        // local-mean layer.
        #expect(!EyesTeethSliders(eyeBrighten: 100).needsLocalMeanLayer)
        #expect(EyesTeethSliders(eyeDefinition: 1).needsLocalMeanLayer)
        #expect(EyesTeethSliders(scleraWhiten: 1).needsLocalMeanLayer)
        #expect(EyesTeethSliders(teethWhiten: 1).needsLocalMeanLayer)
        // …and the mask each one reads.
        #expect(EyesTeethSliders(eyeBrighten: 1).needsEyeMask)
        #expect(!EyesTeethSliders(eyeBrighten: 1).needsMouthMask)
        #expect(EyesTeethSliders(teethWhiten: 1).needsMouthMask)
        #expect(!EyesTeethSliders(teethWhiten: 1).needsEyeMask)
    }

    /// The local-mean radius is a fraction of face width, which is what makes a
    /// preset transfer between images and a preview agree with an export.
    @Test("The local-mean radius scales with face width and stays inside its bounds")
    func radiusScalesWithFaceWidth() {
        #expect(EyesTeethRenderNode.localMeanRadius(faceWidth: 600) == 30)
        #expect(EyesTeethRenderNode.localMeanRadius(faceWidth: 1200) == 60)
        // A tiny face must still get a usable radius rather than 0 (a 0-radius
        // box is the identity, which reads as "the slider did nothing").
        #expect(EyesTeethRenderNode.localMeanRadius(faceWidth: 4) == 3)
        // …and a 24 MP frame must not ask for an unbounded box.
        #expect(EyesTeethRenderNode.localMeanRadius(faceWidth: 100_000) == 192)
        #expect(EyesTeethRenderNode.localMeanRadius(faceWidth: .nan) == 3)
    }

    /// The node must not invent a mask kind that nothing can produce — spike S2:
    /// CelebAMask-HQ has no teeth class.
    @Test("The node asks only for mask kinds that exist")
    func maskKindsExist() {
        #expect(EyesTeethRenderNode.maskKinds == [.eyes, .mouth])
        #expect(!RenderMaskKind.allCases.contains { $0.rawValue == "teeth" })
    }

    // MARK: - Helpers

    /// Encodes one node source → destination and reads the result back as
    /// float32. Deliberately *not* through `RenderGraph`, so a test can reach the
    /// kernel with slider values the graph would short-circuit.
    static func runNode(
        _ node: EyesTeethRenderNode, context: MetalContext, request: RenderRequest
    ) throws -> [Float] {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: Self.source, width: width, height: height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try RenderGraph.readFloat32(destination, queue: context.commandQueue)
    }

    /// The `Double` composite fed the node's **own** intermediates, so a
    /// composite failure and a guided-filter failure stay distinguishable.
    static func compositeReference(
        node: EyesTeethRenderNode, context: MetalContext, sliders: EyesTeethSliders
    ) throws -> [Float] {
        guard let layers = node.debugLayers() else { return Self.source }
        // An absent layer is the source itself and an absent mask is zero —
        // which is exactly what the node binds and what the amounts multiply by.
        var low = Self.source
        if let texture = layers.low {
            low = try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
        }
        var eye = [Double](repeating: 0, count: width * height)
        if let texture = layers.eyes {
            eye = try SkinRenderNodeTests.readR8(texture, queue: context.commandQueue)
        }
        var mouth = [Double](repeating: 0, count: width * height)
        if let texture = layers.mouth {
            mouth = try SkinRenderNodeTests.readR8(texture, queue: context.commandQueue)
        }
        return EyesTeethReference.composite(
            source: Self.source, low: low, eye: eye, mouth: mouth,
            amounts: EyesTeethReference.Amounts(sliders))
    }
}
