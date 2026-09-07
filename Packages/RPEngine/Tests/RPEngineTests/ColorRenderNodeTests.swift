import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 2 golden tests for the "Color" slider group.
///
/// docs/PLAN.md Phase 2 sets the bar: **golden render PSNR ≥ 45 dB**. The control
/// is `ColorReference`, a `Double` CPU implementation written from the
/// specification rather than from the shader, in the same arrangement the other
/// three groups use.
///
/// Two levels, because this node is a colour grade and not a geometric warp — the
/// third, "did the geometry land where the maths said", has no analogue here:
/// 1. `rp_color_composite` fed the **GPU's own** analysis planes, which isolates
///    the composite from the Auto D&B pyramid;
/// 2. the whole node (analysis + composite) against the whole reference.
///
/// Plus a set of **behavioural** checks a PSNR cannot make: that Highlights only
/// touches the bright end, that Shadows only touches the dark end, that an HSL
/// band lands on its own hue, that Vibrance holds back on skin, and that Auto D&B
/// moves a bright blob down and a dark blob up. A reference agreeing with the
/// shader proves the formula was transcribed correctly; only these say the
/// formula does what the slider's name claims.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 2 color sliders", .serialized)
struct ColorRenderNodeTests {
    static let chart = ColorReference.chart()
    static var width: Int { chart.width }
    static var height: Int { chart.height }
    static var source: [Float] { chart.pixels }

    /// Every slider at a mid value, so no term of the composite is skipped and
    /// none of them saturates.
    static let allSliders = ColorSliders(
        exposure: 30, contrast: 40, highlights: 55, shadows: 45, wbTemperature: 35,
        wbTint: 25, vibrance: 50, saturation: 20, curves: 60, autoDodgeBurn: 70,
        hsl: [40, 15, 30, 20, 10, 45, 25, 35])

    /// One case per key, at 100, for the per-slider isolation level.
    static let singleSliderCases: [(String, ColorSliders)] = [
        ("exposure", ColorSliders(exposure: 100)),
        ("contrast", ColorSliders(contrast: 100)),
        ("highlights", ColorSliders(highlights: 100)),
        ("shadows", ColorSliders(shadows: 100)),
        ("wbTemperature", ColorSliders(wbTemperature: 100)),
        ("wbTint", ColorSliders(wbTint: 100)),
        ("vibrance", ColorSliders(vibrance: 100)),
        ("saturation", ColorSliders(saturation: 100)),
        ("curves", ColorSliders(curves: 100)),
        ("autoDodgeBurn", ColorSliders(autoDodgeBurn: 100)),
    ]
        + HueBand.allCases.map { band in
            var sliders = ColorSliders()
            sliders[band] = 100
            return (band.key, sliders)
        }

    static func request(_ sliders: ColorSliders, quality: RenderQuality = .preview)
        -> RenderRequest
    {
        var state = EditState()
        sliders.write(into: &state)
        // Deliberately no faces: this node must not need one.
        return RenderRequest(editState: state, faces: [], quality: quality)
    }

    // MARK: - Layout

    @Test("The shader parameter structs have the layout ColorShaders.metal declares")
    func parameterStructsMatchShaderLayout() {
        // 2 x float4 (32) + 2 x uint2 (16) + 10 floats (40) + uint (4) = 92,
        // rounded to the float4 alignment of 16.
        #expect(MemoryLayout<ColorParams>.stride == 96)
        #expect(MemoryLayout<ColorAnalysisParams>.stride == 16)
        #expect(MemoryLayout<ColorBoxParams>.stride == 16)
    }

    // MARK: - Identity

    @Test("All sliders at 0 is a bit-exact identity")
    func allSlidersZeroIsBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }
        let node = try ColorRenderNode(context: context)
        // Straight at the node, bypassing RenderGraph's isActive short-circuit,
        // so this tests the kernel's own 0-handling and not the graph's.
        let output = try Self.runNode(node, context: context, request: Self.request(ColorSliders()))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    /// The node grades a frame with no face in it, which is the point of putting
    /// no `FaceRenderInput` in its inputs at all.
    @Test("The color node is active with no face and no mask")
    func noFaceIsStillActive() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }
        let node = try ColorRenderNode(context: context)
        #expect(node.isActive(for: Self.request(ColorSliders(exposure: 10))))
        #expect(!node.isActive(for: Self.request(ColorSliders())))
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 40)))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) > 1e-3)
    }

    // MARK: - 1. Composite

    @Test("rp_color_composite matches a Double reference fed the GPU's own analysis")
    func compositeMatchesReferenceOnItsOwnLayers() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        let reference = try Self.compositeReference(
            node: node, context: context, sliders: Self.allSliders)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 color composite vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "composite PSNR \(psnr) dB")
    }

    /// Each slider on its own, so an error in one term cannot be hidden by the
    /// others' magnitude in the combined PSNR.
    @Test("Each Color slider alone matches the reference", arguments: singleSliderCases)
    func eachSliderAloneMatchesReference(name: String, sliders: ColorSliders) throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(sliders))
        let reference = try Self.compositeReference(node: node, context: context, sliders: sliders)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 color slider '\(name)' vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "\(name) PSNR \(psnr) dB")

        // …and it must actually do something, or a PSNR of infinity would pass.
        let change = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        #expect(change > 1e-3, "\(name) changed the picture by only \(change)")
    }

    // MARK: - 2. Whole node

    @Test("The whole Color node matches the whole Double reference at ≥ 45 dB")
    func wholeNodeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let (output, report) = try graph.renderPixels(
            Self.source, width: Self.width, height: Self.height,
            request: Self.request(Self.allSliders))
        #expect(report.nodes == ["color"])

        let node = try ColorRenderNode(context: context)
        let reference = ColorReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height, sliders: Self.allSliders,
            curveTable: node.curveTable)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 color node end-to-end vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "end-to-end PSNR \(psnr) dB")
    }

    // MARK: - 3. Behaviour — the claims a PSNR cannot make

    @Test("Exposure brightens, and the linear-light gain is +1 EV at 100")
    func exposureIsAStopOfLight() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        // A mid-grey ramp pixel must land within rounding of 2x its linear value.
        let x = Self.width / 2
        let y = 120
        let o = (y * Self.width + x) * 4
        let before = ColorReference.toLinear(Double(Self.source[o + 1]))
        let after = ColorReference.toLinear(Double(output[o + 1]))
        print("P2 color exposure: linear \(before) -> \(after), ratio \(after / before)")
        #expect(abs(after / before - 2) < 0.01, "ratio \(after / before) is not one stop")
    }

    @Test("Highlights pulls the bright end down and leaves the dark end alone")
    func highlightsActOnlyOnTheBrightEnd() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(highlights: 100)))
        let bright = Self.rampLumaChange(output, xFraction: 0.75...0.95)
        let dark = Self.rampLumaChange(output, xFraction: 0.05...0.25)
        print("P2 color highlights: bright \(bright), dark \(dark)")
        #expect(bright < -0.02, "the bright end did not come down (\(bright))")
        #expect(abs(dark) < 0.002, "the dark end moved by \(dark)")
    }

    @Test("Shadows lifts the dark end and leaves the bright end alone")
    func shadowsActOnlyOnTheDarkEnd() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(shadows: 100)))
        let bright = Self.rampLumaChange(output, xFraction: 0.75...0.95)
        let dark = Self.rampLumaChange(output, xFraction: 0.05...0.25)
        print("P2 color shadows: bright \(bright), dark \(dark)")
        #expect(dark > 0.02, "the dark end was not lifted (\(dark))")
        #expect(abs(bright) < 0.002, "the bright end moved by \(bright)")
    }

    @Test("White balance warms without changing the overall brightness")
    func whiteBalanceIsLuminancePreserving() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(wbTemperature: 100)))
        let x = Self.width / 2
        let y = 120
        let o = (y * Self.width + x) * 4
        #expect(output[o] > Self.source[o], "red did not go up")
        #expect(output[o + 2] < Self.source[o + 2], "blue did not go down")
        // Luminance is preserved by construction (the gains are renormalised);
        // what survives is the gamma round trip, so the bar is loose but far
        // tighter than the ±10 % an un-normalised diagonal would give.
        let change = Self.rampLumaChange(output, xFraction: 0.3...0.7)
        print("P2 color WB: mean luma change \(change)")
        #expect(abs(change) < 0.01, "luminance moved by \(change)")
    }

    /// The eight bands are normalised by their weight sum, so all eight at 100
    /// must be exactly the plain Saturation slider at 100. That is the property
    /// that says no hue is boosted twice for sitting between two centres.
    @Test("All eight HSL bands at 100 equal plain Saturation at 100")
    func hslBandsSumToPlainSaturation() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let bands = try Self.runNode(
            node, context: context,
            request: Self.request(ColorSliders(hsl: Array(repeating: 100, count: 8))))
        let plain = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(saturation: 100)))
        let worst = SpikeTextureIO.maxAbsoluteDifference(bands, plain)
        print("P2 color HSL partition of unity: max abs diff vs saturation = \(worst)")
        #expect(worst < 1e-5, "bands and saturation differ by \(worst)")
        // …and both must have done something.
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, plain) > 0.05)
    }

    @Test("An HSL band saturates its own hue and not the opposite one")
    func hslBandsAreHueSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        var red = ColorSliders()
        red[.red] = 100
        let output = try Self.runNode(node, context: context, request: Self.request(red))
        let onRed = ColorReference.meanChange(
            Self.source, output, regions: Self.chart.regions, .red)
        let onAqua = ColorReference.meanChange(
            Self.source, output, regions: Self.chart.regions, .aqua)
        let onGreen = ColorReference.meanChange(
            Self.source, output, regions: Self.chart.regions, .green)
        print("P2 color hslRed: red \(onRed), green \(onGreen), aqua \(onAqua)")
        #expect(onRed > 0.01, "the red patch barely moved (\(onRed))")
        // Aqua is 180° away: outside the ±60° window, so exactly zero.
        #expect(onAqua == 0, "the aqua patch moved by \(onAqua)")
        #expect(onGreen == 0, "the green patch moved by \(onGreen)")
    }

    /// Vibrance is the one slider with a portrait-specific rule in it.
    @Test("Vibrance holds back on the skin-tone hue")
    func vibranceProtectsSkinHues() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        // Two pixels with **identical** max/min channels — so identical
        // saturation, which is the other term in the vibrance weight — differing
        // only in hue: 20° (skin) against 140° (not).
        let skin: [Float] = [0.72, 0.56, 0.48, 1]
        let other: [Float] = [0.48, 0.72, 0.56, 1]
        let pixels = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(skin + other))

        let node = try ColorRenderNode(context: context)
        let graph = RenderGraph(context: context, nodes: [node])
        let (output, _) = try graph.renderPixels(
            pixels, width: 2, height: 1, request: Self.request(ColorSliders(vibrance: 100)))

        func meanChange(_ index: Int) -> Double {
            (0..<3).reduce(0.0) {
                $0 + abs(Double(output[index * 4 + $1]) - Double(pixels[index * 4 + $1]))
            } / 3
        }
        let skinChange = meanChange(0)
        let otherChange = meanChange(1)
        print("P2 color vibrance: skin hue \(skinChange), non-skin hue \(otherChange)")
        #expect(otherChange > 0.03, "the control pixel barely moved (\(otherChange))")
        #expect(
            skinChange < otherChange * 0.6,
            "skin \(skinChange) vs control \(otherChange) — the protection is not working")
        #expect(skinChange > 0, "the skin pixel was frozen, not held back")
    }

    /// The claim in the Auto D&B slider's name: it evens out *local* luminance —
    /// a blob brighter than its surroundings comes down, a darker one goes up,
    /// and the smooth ramp between them is left where it is.
    @Test("Auto D&B burns a bright blob, dodges a dark one, and leaves the ramp alone")
    func autoDodgeBurnEvensLocalLuminance() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(autoDodgeBurn: 100)))
        let bright = ColorReference.meanLuminanceChange(
            Self.source, output, regions: Self.chart.regions, .brightDisc)
        let dark = ColorReference.meanLuminanceChange(
            Self.source, output, regions: Self.chart.regions, .darkDisc)
        let ramp = Self.rampLumaChange(output, xFraction: 0.35...0.65)
        print("P2 color autoDodgeBurn: bright disc \(bright), dark disc \(dark), ramp \(ramp)")
        #expect(bright < -0.02, "the bright blob was not burned (\(bright))")
        #expect(dark > 0.02, "the dark blob was not dodged (\(dark))")
        // The ramp has no *local* error — it is a straight gradient — so the
        // two-scale deviation there is near zero and the slider must ignore it.
        #expect(abs(ramp) < 0.01, "the flat ramp moved by \(ramp)")
    }

    @Test("The Auto D&B analysis grid and radii are autoskin.js's, unchanged")
    func analysisGeometryMatchesThePanel() {
        #expect(ColorRenderNode.analysisWidth == 320)
        // A 24 MP portrait frame: 320 wide, height in proportion.
        let full = ColorRenderNode.analysisSize(width: 4000, height: 6000)
        #expect(full.width == 320)
        #expect(full.height == 480)
        #expect(ColorRenderNode.bigRadius(analysisWidth: full.width) == 18)
        #expect(ColorRenderNode.smallRadius(analysisWidth: full.width) == 4)
        // Never upscaled: a thumbnail analyses itself.
        let small = ColorRenderNode.analysisSize(width: 64, height: 48)
        #expect(small.width == 64)
        #expect(small.height == 48)
        // …and the floors from dodgeBurnMaps survive on a tiny frame.
        #expect(ColorRenderNode.bigRadius(analysisWidth: 8) == 3)
        #expect(ColorRenderNode.smallRadius(analysisWidth: 8) == 1)
    }

    @Test("The dodge and burn gammas reproduce commands.js's curve points")
    func dodgeBurnGammasMatchTheCurvePoints() {
        // [[0,0],[128,146],[255,255]] and [[0,0],[128,110],[255,255]].
        #expect(abs(pow(128.0 / 255, ColorReference.dodgeGamma) - 146.0 / 255) < 1e-4)
        #expect(abs(pow(128.0 / 255, ColorReference.burnGamma) - 110.0 / 255) < 1e-4)
        // Both are endpoint-preserving, which a Photoshop curve through (0,0)
        // and (255,255) has to be.
        #expect(pow(0.0, ColorReference.dodgeGamma) == 0)
        #expect(pow(1.0, ColorReference.burnGamma) == 1)
    }

    // MARK: - The curve

    @Test("The film curve is monotone, lifts the toe and rolls the shoulder")
    func filmCurveShape() {
        for channel in 0..<3 {
            let limits = ColorToneCurve.limits(channel: channel)
            #expect(abs(ColorToneCurve.value(0, channel: channel) - limits.toe) < 1e-12)
            #expect(abs(ColorToneCurve.value(1, channel: channel) - (1 - limits.shoulder)) < 1e-12)
            var previous = -1.0
            for i in 0...1000 {
                let v = ColorToneCurve.value(Double(i) / 1000, channel: channel)
                #expect(v > previous, "not monotone at \(i) in channel \(channel)")
                previous = v
            }
        }
        // The per-channel split is the point of storing three curves: cool
        // shadows (blue toe highest) and warm highlights (red shoulder deepest).
        #expect(ColorToneCurve.toe.b > ColorToneCurve.toe.g)
        #expect(ColorToneCurve.toe.g > ColorToneCurve.toe.r)
        #expect(ColorToneCurve.shoulder.r > ColorToneCurve.shoulder.g)
        #expect(ColorToneCurve.shoulder.g > ColorToneCurve.shoulder.b)
    }

    /// The LUT is 256 entries with a lerp between them; this is what that costs
    /// against evaluating the curve exactly.
    @Test("256 LUT entries plus a lerp cost less than 1e-5 against the exact curve")
    func lutSamplingErrorIsNegligible() {
        let table = ColorToneCurve.table()
        var worst = 0.0
        for i in 0...20000 {
            let x = Double(i) / 20000
            for channel in 0..<3 {
                let exact = ColorToneCurve.value(x, channel: channel)
                let sampled = ColorToneCurve.lookup(table, x, channel: channel)
                worst = max(worst, abs(exact - sampled))
            }
        }
        print("P2 color curve LUT sampling error: max abs = \(worst)")
        #expect(worst < 1e-5, "LUT error \(worst)")
    }

    // MARK: - Allocation

    @Test("The analysis grid is allocated only when Auto D&B is used")
    func analysisIsAllocatedLazily() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let lutBytes = ColorToneCurve.size * 16
        #expect(node.allocatedBytes == lutBytes)

        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        #expect(node.allocatedBytes == lutBytes, "a grade without D&B allocated an analysis grid")
        #expect(node.debugAnalysis() == nil)

        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(autoDodgeBurn: 100)))
        let size = ColorRenderNode.analysisSize(width: Self.width, height: Self.height)
        #expect(node.allocatedBytes == lutBytes + 4 * size.width * size.height * 4)
        #expect(node.debugAnalysis() != nil)

        // …and the *reported* layers follow the last request, not what is still
        // allocated — the stale-layer bug ADR-0009 records.
        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        #expect(node.debugAnalysis() == nil)

        node.releaseIntermediates()
        #expect(node.allocatedBytes == lutBytes)
    }

    // MARK: - Values

    @Test("Every Color slider round-trips through EditState and clamps to 0…100")
    func slidersRoundTripThroughEditState() {
        let sliders = Self.allSliders
        var state = EditState()
        sliders.write(into: &state)
        #expect(ColorSliders(state) == sliders)
        // They live in their own section, not in another group's.
        #expect(state.sections.keys.contains(EditState.SectionKey.color))
        #expect(SkinSliders(state).isIdentity)
        #expect(FaceSliders(state).isIdentity)
        #expect(EyesTeethSliders(state).isIdentity)
        // Out of range is clamped, not rejected.
        #expect(ColorSliders(exposure: 400).exposure == 100)
        #expect(ColorSliders(exposure: -10).exposure == 0)
        #expect(ColorSliders(exposure: .nan).exposure == 0)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.red] == 100)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.orange] == 0)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.yellow] == 0)
        // A short array is padded rather than trapping.
        #expect(ColorSliders(hsl: []).hsl.count == HueBand.allCases.count)
        // A zeroed slider leaves no key behind (EditSection.setSlider's contract).
        var zeroed = state
        ColorSliders().write(into: &zeroed)
        #expect(zeroed.isDefault)
        // Every key the group owns is distinct and accounted for.
        #expect(ColorSliders.Key.all.count == 18)
        #expect(Set(ColorSliders.Key.all).count == 18)
    }

    @Test("Which work each slider needs")
    func workRequirements() {
        #expect(ColorSliders().isIdentity)
        #expect(!ColorSliders(autoDodgeBurn: 1).isIdentity)
        #expect(!ColorSliders(hsl: [0, 0, 1]).isIdentity)
        // Only Auto D&B pays for the analysis pyramid.
        #expect(ColorSliders(autoDodgeBurn: 1).needsDodgeBurnAnalysis)
        #expect(!ColorSliders(exposure: 100, curves: 100).needsDodgeBurnAnalysis)
        // Only exposure and the two WB axes pay for the linear-light round trip.
        #expect(ColorSliders(exposure: 1).needsLinearLight)
        #expect(ColorSliders(wbTemperature: 1).needsLinearLight)
        #expect(ColorSliders(wbTint: 1).needsLinearLight)
        #expect(!ColorSliders(contrast: 100, saturation: 100).needsLinearLight)
    }

    // MARK: - Helpers

    /// Mean luminance change over a slice of the background ramp, avoiding both
    /// the discs (y < 100) and the patches (y ≥ 145).
    static func rampLumaChange(_ after: [Float], xFraction: ClosedRange<Double>) -> Double {
        let x0 = Int(xFraction.lowerBound * Double(width))
        let x1 = Int(xFraction.upperBound * Double(width))
        var sum = 0.0
        var count = 0
        for y in 100..<140 {
            for x in x0..<x1 {
                let o = (y * width + x) * 4
                let before = ColorReference.luminance(
                    (Double(source[o]), Double(source[o + 1]), Double(source[o + 2])))
                let now = ColorReference.luminance(
                    (Double(after[o]), Double(after[o + 1]), Double(after[o + 2])))
                sum += now - before
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Encodes one node source → destination and reads the result back as
    /// float32. Deliberately *not* through `RenderGraph`, so a test can reach the
    /// kernel with slider values the graph would short-circuit.
    static func runNode(
        _ node: ColorRenderNode, context: MetalContext, request: RenderRequest
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

    /// The `Double` composite fed the node's **own** analysis planes, so a
    /// composite failure and an analysis failure stay distinguishable.
    static func compositeReference(
        node: ColorRenderNode, context: MetalContext, sliders: ColorSliders
    ) throws -> [Float] {
        var big: [Double] = []
        var small: [Double] = []
        var size = (width: 1, height: 1)
        if let analysis = node.debugAnalysis() {
            size = (analysis.big.width, analysis.big.height)
            big = try readR32(analysis.big, queue: context.commandQueue)
            small = try readR32(analysis.small, queue: context.commandQueue)
        }
        return ColorReference.composite(
            source: Self.source, width: width, height: height, big: big, small: small,
            analysisSize: size, amounts: ColorReference.Amounts(sliders),
            curveTable: node.curveTable)
    }

    /// Reads an r32Float texture back as `Double`.
    static func readR32(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [Double] {
        let bytesPerRow = texture.width * 4
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var floats = [Float](repeating: 0, count: texture.width * texture.height)
        floats.withUnsafeMutableBytes { raw in
            raw.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.contents(), count: bytesPerRow * texture.height))
        }
        return floats.map(Double.init)
    }
}
