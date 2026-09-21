import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing
import simd

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

    /// The same idea on the **negative** side (docs/ADR-0016): every slider that
    /// went bidirectional, mixed in sign so a signed sum would cancel several of
    /// them against each other. `curves` and `autoDodgeBurn` stay positive —
    /// they are the two that stayed one-directional.
    static let allSlidersSigned = ColorSliders(
        exposure: -30, contrast: -40, highlights: -55, shadows: -45, wbTemperature: -35,
        wbTint: 25, vibrance: -50, saturation: 20, curves: 60, autoDodgeBurn: 70,
        hsl: [-40, 15, -30, 20, -10, 45, -25, 35])

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

    /// One case per **bidirectional** key, at −100. `curves` and `autoDodgeBurn`
    /// are absent because they are the two that stayed 0…100; the test that says
    /// so is `oneDirectionalSlidersIgnoreNegativeValues`.
    static let negativeSliderCases: [(String, ColorSliders)] = [
        ("exposure", ColorSliders(exposure: -100)),
        ("contrast", ColorSliders(contrast: -100)),
        ("highlights", ColorSliders(highlights: -100)),
        ("shadows", ColorSliders(shadows: -100)),
        ("wbTemperature", ColorSliders(wbTemperature: -100)),
        ("wbTint", ColorSliders(wbTint: -100)),
        ("vibrance", ColorSliders(vibrance: -100)),
        ("saturation", ColorSliders(saturation: -100)),
    ]
        + HueBand.allCases.map { band in
            var sliders = ColorSliders()
            sliders[band] = -100
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
        // 2 x float4 (32) + float3x3 (48, three 16-byte columns) + 2 x uint2 (16)
        // + 10 floats (40) + 2 uint (8) = 144, already a multiple of the float4
        // alignment of 16. It was 96 before docs/ADR-0023 added `wbMatrix`.
        #expect(MemoryLayout<ColorParams>.stride == 144)
        #expect(MemoryLayout<simd_float3x3>.size == 48)
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

    /// docs/ADR-0016: the same isolation level on the negative side. Without it
    /// a sign error in one term would only show up in the mixed composite, where
    /// the other seventeen sliders hide it.
    @Test(
        "Each bidirectional Color slider at −100 matches the reference",
        arguments: negativeSliderCases)
    func eachNegativeSliderAloneMatchesReference(name: String, sliders: ColorSliders) throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(sliders))
        let reference = try Self.compositeReference(node: node, context: context, sliders: sliders)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P2 color slider '\(name)' at -100 vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "\(name) at -100 PSNR \(psnr) dB")

        let change = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        #expect(change > 1e-3, "\(name) at -100 changed the picture by only \(change)")
        // …and the two directions must not be the same picture.
        let mirrored = try #require(Self.singleSliderCases.first { $0.0 == name }?.1)
        let positive = try Self.runNode(node, context: context, request: Self.request(mirrored))
        let split = SpikeTextureIO.maxAbsoluteDifference(positive, output)
        #expect(split > 1e-3, "\(name) at +100 and -100 render the same picture")
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

    @Test("The whole Color node matches the reference with mixed-sign sliders")
    func wholeNodeMatchesReferenceWithSignedSliders() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let graph = try RenderGraph.standard(context: context)
        let (output, report) = try graph.renderPixels(
            Self.source, width: Self.width, height: Self.height,
            request: Self.request(Self.allSlidersSigned))
        #expect(report.nodes == ["color"])

        let node = try ColorRenderNode(context: context)
        let reference = ColorReference.renderNode(
            source: Self.source, width: Self.width, height: Self.height,
            sliders: Self.allSlidersSigned, curveTable: node.curveTable)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P2 color node end-to-end (signed) vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "signed end-to-end PSNR \(psnr) dB")
    }

    // MARK: - 3. Behaviour — the claims a PSNR cannot make

    /// **+5 EV at 100 since 2026-09-21** (docs/ADR-0023); it was +1 EV, and
    /// `exposureIsSymmetricInStops` below is the matching −5 EV.
    ///
    /// The measurement is taken at the **dark** end of the ramp rather than the
    /// middle, because 32× on a mid-grey is far past white and a clipped pixel
    /// can only say "≥ 1". That is not the slider being wrong — the same is true
    /// of Lightroom at +5 — it is what makes the *ratio* unmeasurable there.
    @Test("Exposure brightens, and the linear-light gain is +5 EV at 100")
    func exposureIsAStopOfLight() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        // A DARK ramp pixel (linear ≈ 0.010), so 32x still lands inside 0…1 and
        // the ratio is a number rather than a clip.
        let x = 21
        let y = 120
        let o = (y * Self.width + x) * 4
        let before = ColorReference.toLinear(Double(Self.source[o + 1]))
        let after = ColorReference.toLinear(Double(output[o + 1]))
        print("P2 color exposure: linear \(before) -> \(after), ratio \(after / before)")
        #expect(after < 1, "the probe pixel clipped; pick a darker one")
        #expect(abs(after / before - 32) < 0.2, "ratio \(after / before) is not five stops")
        // …and a mid-grey really does go to white, which is the point of the
        // wider range: +5 EV is a rescue, not a nudge.
        let mid = (y * Self.width + Self.width / 2) * 4
        #expect(output[mid + 1] >= 0.999, "mid-grey did not reach white at +5 EV")
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

    // MARK: - 4. The negative half (docs/ADR-0016)

    /// The bug the whole signed change is one `fabs` away from: the kernel's
    /// "is anything on" test is a **sum** of the eighteen amounts, and a signed
    /// sum cancels. `exposure +50, contrast −50` sums to 0 and would have taken
    /// the bit-exact passthrough branch on a picture the user has graded.
    @Test("Sliders that cancel in a signed sum still change the picture")
    func signedSlidersDoNotCancelInTheActiveTest() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let cancelling = ColorSliders(exposure: 50, contrast: -50)
        #expect(!cancelling.isIdentity)
        #expect(node.isActive(for: Self.request(cancelling)))
        let output = try Self.runNode(node, context: context, request: Self.request(cancelling))
        let change = SpikeTextureIO.maxAbsoluteDifference(Self.source, output)
        print("P2 color signed-sum cancellation: max abs change = \(change)")
        #expect(change > 1e-2, "the cancelling pair was treated as a passthrough (\(change))")

        // Same trap one level down, in the HSL branch's own sum.
        var bands = ColorSliders()
        bands[.red] = 60
        bands[.aqua] = -60
        #expect(!bands.isIdentity)
        let bandOutput = try Self.runNode(node, context: context, request: Self.request(bands))
        let bandChange = SpikeTextureIO.maxAbsoluteDifference(Self.source, bandOutput)
        print("P2 color signed HSL cancellation: max abs change = \(bandChange)")
        #expect(bandChange > 1e-2, "the cancelling bands were skipped (\(bandChange))")
    }

    @Test("Exposure at −100 is −5 EV, the exact inverse of +100")
    func exposureIsSymmetricInStops() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: -100)))
        let x = Self.width / 2
        let y = 120
        let o = (y * Self.width + x) * 4
        let before = ColorReference.toLinear(Double(Self.source[o + 1]))
        let after = ColorReference.toLinear(Double(output[o + 1]))
        print("P2 color exposure -100: linear \(before) -> \(after), ratio \(after / before)")
        #expect(
            abs(after / before - 1.0 / 32) < 0.002,
            "ratio \(after / before) is not minus five stops")
        // Nothing went negative or NaN on the way down — the concern a 32x
        // range raises that a 2x one did not.
        for value in output where !(value.isFinite && value >= 0) {
            Issue.record("exposure -100 produced \(value)")
            break
        }
    }

    @Test("Highlights at −100 pushes the bright end up and still leaves the dark end alone")
    func negativeHighlightsPushTheBrightEndUp() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(highlights: -100)))
        let bright = Self.rampLumaChange(output, xFraction: 0.75...0.95)
        let dark = Self.rampLumaChange(output, xFraction: 0.05...0.25)
        print("P2 color highlights -100: bright \(bright), dark \(dark)")
        #expect(bright > 0.02, "the bright end did not come up (\(bright))")
        #expect(abs(dark) < 0.002, "the dark end moved by \(dark)")
    }

    /// The reason the negative half is a **reciprocal gamma** and not the
    /// mirrored mix: `2c − c^0.65` goes negative below c ≈ 0.06, so a mirrored
    /// Shadows slider would crush the bottom of the range to solid black. The
    /// reciprocal gamma cannot, and this measures that it does not.
    @Test("Shadows at −100 deepens the dark end without crushing it to black")
    func negativeShadowsDeepenWithoutCrushing() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(shadows: -100)))
        let bright = Self.rampLumaChange(output, xFraction: 0.75...0.95)
        let dark = Self.rampLumaChange(output, xFraction: 0.05...0.25)
        var crushed = 0
        var darkest = 1.0
        for y in 100..<140 {
            for x in 0..<(Self.width / 4) {
                let o = (y * Self.width + x) * 4
                let value = Double(output[o + 1])
                darkest = min(darkest, value)
                if value <= 0 && Double(Self.source[o + 1]) > 0 { crushed += 1 }
            }
        }
        print("P2 color shadows -100: bright \(bright), dark \(dark), darkest \(darkest), crushed \(crushed)")
        #expect(dark < -0.02, "the dark end was not deepened (\(dark))")
        #expect(abs(bright) < 0.002, "the bright end moved by \(bright)")
        #expect(crushed == 0, "\(crushed) pixels were crushed to black")
    }

    /// **±x is no longer a round trip, and that is the change, not a
    /// regression** (docs/ADR-0023). The gains used to be `pow(1 ± 0.22, x)`,
    /// which made −x the exact channel-wise inverse of +x; they are now a
    /// Bradford adaptation to a colour temperature interpolated in **mired**,
    /// and the two halves of the slider cover wildly different mired distances
    /// (from a 6500 K neutral: 346 mired down to 2000 K, 134 mired up to
    /// 50000 K). Lightroom's Temp slider is asymmetric for exactly the same
    /// reason — it is what the Planckian locus looks like.
    ///
    /// What replaces the round trip is the property that actually matters, and
    /// the one the photographer complained was missing: the cool half has to be
    /// *strong enough to fix a real cast*. That is
    /// `aTungstenCastIsNeutralised` in `WhiteBalanceTests` on the maths and
    /// `aYellowCastFrameIsNeutralisedThroughTheGraph` below on the GPU. Here we
    /// only check the direction and the magnitude on the chart.
    @Test("White balance cools at −100, and moves the picture far more than the old gain did")
    func whiteBalanceDirectionsAreInverse() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let cool = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(wbTemperature: -100)))
        let o = (120 * Self.width + Self.width / 2) * 4
        #expect(cool[o] < Self.source[o], "red did not go down")
        #expect(cool[o + 2] > Self.source[o + 2], "blue did not go up")

        // At ±50, i.e. half travel, in **linear light** where the gain actually
        // lives. Before docs/ADR-0023 the same ±50 was `pow(1 ± 0.22, ±0.5)`
        // renormalised — a linear R/B ratio change of 1.2506x warm and 0.7996x
        // cool. It is now 1.835x and 0.1097x, and those are the numbers asserted
        // rather than only printed.
        func linearRatio(_ data: [Float]) -> Double {
            ColorReference.toLinear(Double(data[o])) / ColorReference.toLinear(Double(data[o + 2]))
        }
        let halfWarm = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(wbTemperature: 50)))
        let halfCool = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(wbTemperature: -50)))
        let base = linearRatio(Self.source)
        let warmFactor = linearRatio(halfWarm) / base
        let coolFactor = linearRatio(halfCool) / base
        print(
            "P2 color WB ±50 linear R/B factor: warm \(warmFactor)x, cool \(coolFactor)x "
                + "(the 0.22 von Kries this replaces: 1.2506x / 0.7996x)")
        #expect(warmFactor > 1.7, "the warm half is only \(warmFactor)x")
        #expect(coolFactor < 0.15, "the cool half is only \(coolFactor)x")

        // Stated rather than hidden: at −100 the adaptation asks for a
        // *negative* red gain on a neutral (white gain −0.373, docs/ADR-0023
        // "Known limitations"), so the red channel of a near-neutral pixel pins
        // at 0. Lightroom's Temp 2000 does the same thing to a daylight frame;
        // it is the extreme end of a corrective slider, not a working value.
        print("P2 color WB −100 red on a mid-ramp pixel: \(cool[o]) (source \(Self.source[o]))")
        #expect(cool[o] >= 0, "red went negative rather than clamping")
    }

    /// The bug this whole change exists to fix, end to end **through
    /// `RenderGraph`**: a frame with a heavy tungsten cast, a real `EditState`
    /// with one slider in it, and the three channel means measured before and
    /// after.
    ///
    /// The cast is built from *published* CIE Planckian chromaticities, not from
    /// ``WhiteBalance/planckianChromaticity(kelvin:)``, so the fixture and the
    /// correction cannot cancel a shared mistake.
    @Test("A yellow-cast frame is neutralised through the real render graph")
    func aYellowCastFrameIsNeutralisedThroughTheGraph() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let side = 64
        func whitePoint(_ x: Double, _ y: Double) -> SIMD3<Double> {
            SIMD3(x / y, 1, (1 - x - y) / y)
        }
        // A neutral developed for daylight (6500 K) but lit at 3200 K.
        let castMatrix =
            WhiteBalance.xyzToLinearSRGB
            * (WhiteBalance.bradfordXYZ(
                sourceWhite: whitePoint(0.3135, 0.3236),
                destinationWhite: whitePoint(0.4234, 0.3990))
                * WhiteBalance.linearSRGBToXYZ)
        var pixels = [Float](repeating: 1, count: side * side * 4)
        for i in 0..<(side * side) {
            // A gentle luminance ramp so the frame is a photograph and not one
            // flat colour, kept dark enough that no channel clips on the way in.
            let grey = 0.18 + 0.30 * Double(i % side) / Double(side - 1)
            var lit = castMatrix * SIMD3<Double>(grey, grey, grey)
            let luma = 0.2126 * lit.x + 0.7152 * lit.y + 0.0722 * lit.z
            lit *= grey / max(luma, 1e-6)  // keep the brightness, change the colour
            for c in 0..<3 {
                pixels[i * 4 + c] = Float(ColorReference.toSRGB(min(max(lit[c], 0), 1)))
            }
        }
        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))

        func channelMeans(_ data: [Float]) -> SIMD3<Double> {
            var sum = SIMD3<Double>(0, 0, 0)
            for i in 0..<(side * side) {
                for c in 0..<3 {
                    sum[c] += ColorReference.toLinear(Double(data[i * 4 + c]))
                }
            }
            return sum / Double(side * side)
        }
        /// Max relative gap between the three linear channel means. 0 is a
        /// perfectly neutral frame.
        func castStrength(_ means: SIMD3<Double>) -> Double {
            let mean = (means.x + means.y + means.z) / 3
            return (means.max() - means.min()) / max(mean, 1e-6)
        }

        let graph = try RenderGraph.standard(context: context)
        func render(_ temperature: Double) throws -> [Float] {
            var state = EditState()
            state.setSlider(
                ColorSliders.Key.wbTemperature, in: EditState.SectionKey.color, to: temperature)
            let source = try SpikeTextureIO.makeTexture(
                fromFloatPixels: quantised, width: side, height: side, device: context.device,
                usage: [.shaderRead, .shaderWrite])
            let destination = try SpikeTextureIO.makeTexture(
                width: side, height: side, device: context.device, pixelFormat: .rgba32Float,
                usage: [.shaderRead, .shaderWrite])
            _ = try graph.render(
                source: source, destination: destination,
                request: RenderRequest(editState: state, faces: [], quality: .preview))
            return try RenderGraph.readFloat32(destination, queue: context.commandQueue)
        }

        // Control: slider 0 must leave the cast exactly where it is.
        let control = try render(0)
        #expect(
            SpikeTextureIO.maxAbsoluteDifference(quantised, control) == 0,
            "slider 0 was not a bit-exact passthrough on the cast frame")

        let before = castStrength(channelMeans(quantised))
        var best = (strength: Double.infinity, amount: 0.0)
        var atFullTravel = Double.infinity
        for amount in stride(from: -100.0, through: 0.0, by: 5.0) {
            let strength = castStrength(channelMeans(try render(amount)))
            if strength < best.strength { best = (strength, amount) }
            if amount == -100 { atFullTravel = strength }
        }
        print(
            "P2 color yellow cast (3200 K on a daylight-balanced frame): "
                + "before \(before), best \(best.strength) at slider \(best.amount), "
                + "at -100 \(atFullTravel)")
        #expect(before > 1.0, "the fixture is not actually cast (\(before))")
        // Neutralised to within a few percent, and reached **inside** the
        // slider's travel rather than at its end — i.e. there is headroom left.
        #expect(best.strength < 0.05, "the cast survived at \(best.strength)")
        #expect(best.amount > -100, "the correction needed the whole slider")
        #expect(best.amount < -10, "the correction was suspiciously small")
    }

    @Test("Saturation at −100 is grayscale, and the eight HSL bands agree with it")
    func negativeSaturationIsGrayscale() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        let node = try ColorRenderNode(context: context)
        let grey = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(saturation: -100)))
        var worstChroma = 0.0
        for i in stride(from: 0, to: grey.count, by: 4) {
            worstChroma = max(
                worstChroma,
                max(
                    abs(Double(grey[i]) - Double(grey[i + 1])),
                    abs(Double(grey[i + 1]) - Double(grey[i + 2]))))
        }
        print("P2 color saturation -100: worst residual chroma = \(worstChroma)")
        #expect(worstChroma < 1e-6, "not grayscale, worst channel spread \(worstChroma)")

        // The partition of unity has to hold on the negative side too.
        let bands = try Self.runNode(
            node, context: context,
            request: Self.request(ColorSliders(hsl: Array(repeating: -100, count: 8))))
        let worst = SpikeTextureIO.maxAbsoluteDifference(bands, grey)
        print("P2 color HSL partition of unity at -100: max abs diff vs saturation = \(worst)")
        #expect(worst < 1e-5, "bands and saturation differ by \(worst)")
    }

    /// Positive contrast mixes toward the S-curve, negative extrapolates away
    /// from it. Both have to stay monotone — a non-monotone tone curve inverts
    /// local detail — and the flattening has to actually flatten.
    @Test("Contrast at −100 flattens the ramp and stays monotone")
    func negativeContrastFlattensMonotonically() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }

        // Monotonicity, in `Double`, over the whole range: the mix's slope with
        // t = −0.5 is 1.5 − 0.5·S′(c), and S′ tops out at 1.5, so the floor is
        // 0.75. Measured rather than argued.
        var previous = -1.0
        var slowest = Double.greatestFiniteMagnitude
        let steps = 100_000
        for i in 0...steps {
            let c = Double(i) / Double(steps)
            let s = c * c * (3 - 2 * c)
            let v = c + (s - c) * (-1.0 * ColorReference.contrastMax)
            if i > 0 { slowest = min(slowest, (v - previous) * Double(steps)) }
            #expect(v > previous, "contrast at -100 is not monotone at \(c)")
            previous = v
        }
        print("P2 color contrast -100: minimum slope = \(slowest)")
        #expect(slowest > 0.7, "slope floor \(slowest)")

        let node = try ColorRenderNode(context: context)
        func rampSpread(_ pixels: [Float]) -> Double {
            Self.rampLuma(pixels, xFraction: 0.75...0.95)
                - Self.rampLuma(pixels, xFraction: 0.05...0.25)
        }
        let flat = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(contrast: -100)))
        let punchy = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(contrast: 100)))
        let base = rampSpread(Self.source)
        print(
            "P2 color contrast: ramp spread \(base) -> \(rampSpread(flat)) at -100, "
                + "\(rampSpread(punchy)) at +100")
        #expect(rampSpread(flat) < base - 0.02, "-100 did not flatten the ramp")
        #expect(rampSpread(punchy) > base + 0.02, "+100 did not steepen the ramp")
    }

    /// The two sliders that deliberately stayed 0…100 (docs/ADR-0016). A
    /// negative value is clamped away at the RPCore boundary, so it never
    /// reaches the kernel and the render is the bit-exact source.
    @Test("Curves and Auto D&B refuse a negative value")
    func oneDirectionalSlidersIgnoreNegativeValues() throws {
        #expect(ColorSliders(curves: -100).curves == 0)
        #expect(ColorSliders(autoDodgeBurn: -100).autoDodgeBurn == 0)
        #expect(ColorSliders(curves: -100, autoDodgeBurn: -100).isIdentity)
        var state = EditState()
        state.setSlider(ColorSliders.Key.curves, in: EditState.SectionKey.color, to: -60)
        state.setSlider(ColorSliders.Key.autoDodgeBurn, in: EditState.SectionKey.color, to: -60)
        #expect(state.isDefault)

        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterColorRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }
        let node = try ColorRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context,
            request: Self.request(ColorSliders(curves: -100, autoDodgeBurn: -100)))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    /// The range table lives in `RPCore.Slider` (that is where the clamp
    /// happens) and is written with string literals, because RPCore cannot
    /// import RPEngine. This is the test that keeps the two lists honest — and
    /// that says the other three groups did not get widened along the way.
    @Test("The −100…100 range is scoped to the Color group's 16 bidirectional keys")
    func rangesAreScopedToTheColorGroup() {
        let color = EditState.SectionKey.color
        let oneDirectional = Set([ColorSliders.Key.curves, ColorSliders.Key.autoDodgeBurn])
        #expect(Slider.oneDirectionalParameters[color] == oneDirectional)
        var signed = 0
        for key in ColorSliders.Key.all {
            let expected: ClosedRange<Double> = oneDirectional.contains(key) ? 0...100 : -100...100
            #expect(Slider.range(for: key, in: color) == expected, "\(key)")
            if !oneDirectional.contains(key) { signed += 1 }
        }
        #expect(signed == 16)

        // The other three groups are untouched, keys and all.
        for key in SkinSliders.Key.all {
            #expect(Slider.range(for: key, in: EditState.SectionKey.skin) == 0...100, "\(key)")
        }
        for key in FaceSliders.Key.all {
            #expect(Slider.range(for: key, in: EditState.SectionKey.face) == 0...100, "\(key)")
        }
        for key in EyesTeethSliders.Key.all {
            #expect(Slider.range(for: key, in: EditState.SectionKey.eyesTeeth) == 0...100, "\(key)")
        }
        #expect(SkinSliders(smooth: -50).smooth == 0)
        #expect(FaceSliders(slim: -50).slim == 0)
        #expect(EyesTeethSliders(eyeBrighten: -50).eyeBrighten == 0)
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
        // Phase 6.2 ("Tạo khối", docs/ADR-0020) gave this node a second
        // permanent allocation: the 4 kB contour lobe buffer, made in `init` and
        // never released, so it belongs in the *fixed* baseline rather than
        // being a leak. What this test is about is unchanged — the **analysis
        // grid** is the lazy one, and `releaseIntermediates()` still returns the
        // node to exactly this floor.
        let fixedBytes = lutBytes + MemoryLayout<ContourLobe>.stride * ContourMask.maxLobes
        #expect(node.allocatedBytes == fixedBytes)

        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        #expect(node.allocatedBytes == fixedBytes, "a grade without D&B allocated an analysis grid")
        #expect(node.debugAnalysis() == nil)

        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(autoDodgeBurn: 100)))
        let size = ColorRenderNode.analysisSize(width: Self.width, height: Self.height)
        #expect(node.allocatedBytes == fixedBytes + 4 * size.width * size.height * 4)
        #expect(node.debugAnalysis() != nil)

        // …and the *reported* layers follow the last request, not what is still
        // allocated — the stale-layer bug ADR-0009 records.
        _ = try Self.runNode(
            node, context: context, request: Self.request(ColorSliders(exposure: 100)))
        #expect(node.debugAnalysis() == nil)

        node.releaseIntermediates()
        #expect(node.allocatedBytes == fixedBytes)
    }

    // MARK: - Values

    @Test("Every Color slider round-trips through EditState and clamps to its range")
    func slidersRoundTripThroughEditState() {
        let sliders = Self.allSliders
        var state = EditState()
        sliders.write(into: &state)
        #expect(ColorSliders(state) == sliders)
        // …and so do the negative ones, which is the round trip docs/ADR-0016
        // adds: a −40 must survive the JSON section, not be dropped as a default.
        var signedState = EditState()
        Self.allSlidersSigned.write(into: &signedState)
        #expect(ColorSliders(signedState) == Self.allSlidersSigned)
        #expect(
            signedState[section: EditState.SectionKey.color].values.count
                == ColorSliders.Key.all.count)
        // They live in their own section, not in another group's.
        #expect(state.sections.keys.contains(EditState.SectionKey.color))
        #expect(SkinSliders(state).isIdentity)
        #expect(FaceSliders(state).isIdentity)
        #expect(EyesTeethSliders(state).isIdentity)
        // Out of range is clamped, not rejected.
        #expect(ColorSliders(exposure: 400).exposure == 100)
        #expect(ColorSliders(exposure: -400).exposure == -100)
        #expect(ColorSliders(exposure: -10).exposure == -10)
        #expect(ColorSliders(exposure: .nan).exposure == 0)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.red] == 100)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.orange] == -5)
        #expect(ColorSliders(hsl: [400, -5, .nan])[.yellow] == 0)
        // …and the two one-directional exceptions still floor at 0.
        #expect(ColorSliders(curves: -400).curves == 0)
        #expect(ColorSliders(autoDodgeBurn: -400).autoDodgeBurn == 0)
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
        // …and a negative value is a value, not an absence.
        #expect(!ColorSliders(exposure: -1).isIdentity)
        #expect(!ColorSliders(hsl: [0, 0, -1]).isIdentity)
        #expect(!ColorSliders(exposure: 50, contrast: -50).isIdentity)
        // Only Auto D&B pays for the analysis pyramid.
        #expect(ColorSliders(autoDodgeBurn: 1).needsDodgeBurnAnalysis)
        #expect(!ColorSliders(exposure: 100, curves: 100).needsDodgeBurnAnalysis)
        #expect(!ColorSliders(exposure: -100).needsDodgeBurnAnalysis)
        // Only exposure and the two WB axes pay for the linear-light round trip,
        // and −40 is as much work as +40.
        #expect(ColorSliders(exposure: 1).needsLinearLight)
        #expect(ColorSliders(exposure: -1).needsLinearLight)
        #expect(ColorSliders(wbTemperature: 1).needsLinearLight)
        #expect(ColorSliders(wbTemperature: -1).needsLinearLight)
        #expect(ColorSliders(wbTint: -1).needsLinearLight)
        #expect(!ColorSliders(contrast: 100, saturation: 100).needsLinearLight)
        #expect(!ColorSliders(contrast: -100, saturation: -100).needsLinearLight)
        // The HSL branch test is absolute: +50 red and −50 aqua is not "no HSL".
        var cancelling = ColorSliders()
        cancelling[.red] = 50
        cancelling[.aqua] = -50
        #expect(cancelling.hslAbsoluteTotal == 100)
    }

    // MARK: - Helpers

    /// Mean luminance over a slice of the background ramp — the absolute value
    /// ``rampLumaChange`` differences. Used to measure how far apart the ramp's
    /// two ends are, i.e. its contrast.
    static func rampLuma(_ pixels: [Float], xFraction: ClosedRange<Double>) -> Double {
        let x0 = Int(xFraction.lowerBound * Double(width))
        let x1 = Int(xFraction.upperBound * Double(width))
        var sum = 0.0
        var count = 0
        for y in 100..<140 {
            for x in x0..<x1 {
                let o = (y * width + x) * 4
                sum += ColorReference.luminance(
                    (Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

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
        _ node: ColorRenderNode, context: MetalContext, request: RenderRequest,
        pixels: [Float]? = nil
    ) throws -> [Float] {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels ?? Self.source, width: width, height: height,
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
