import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.2 golden + selectivity tests for "Tạo khối" (Contour).
///
/// docs/PLAN.md §6.2 asks for exactly one new thing: *"vài mask ellipse/radial
/// mềm neo tại index landmark 478 điểm sẵn có … rồi nhân mask đó vào đúng công
/// thức dodge/burn LUT đã có"*. The dodge/burn LUT step is unchanged and already
/// measured (docs/ADR-0012, `ColorRenderNodeTests`), so what is new here — and
/// therefore what has to carry a number — is **the mask**:
///
/// 1. **Accuracy.** The GPU's mask-gated composite against `ColorReference`, the
///    same `Double` CPU control the colour group golden-tests against, extended
///    with the one extra step. Bar: the plan's 45 dB. This says the kernel
///    evaluates the documented ellipse, in the documented order, with the
///    documented falloff.
/// 2. **Selectivity.** ADR-0011's shape, restated for a face's contour zones:
///    *the cheekbone slider changes the cheekbone probe, and changes the forehead
///    centre by exactly 0*. "Exactly" is available rather than approximate
///    because outside every lobe the mask is 0, `w` is 0, and `mix(c, …, 0)`
///    returns `c` bit-for-bit — the same reason "teethWhiten changes the gums
///    region by exactly 0" was available there.
/// 3. **Locality.** The fraction of the frame the mask claims. A contour that
///    covered the frame would be Auto D&B under another name, which is the one
///    thing §6.2 says this must not be.
///
/// Plus the default-off checks: with `RPEngineFeatureFlags.contourSliders` off,
/// or with the three sliders at 0, or with no face, the render is **bit-exact**
/// what `ColorRenderNode` produced before this group existed.
///
/// Nothing here claims the result is *pretty*: every geometric constant in
/// ``ContourMask`` is argued from where the anatomy is and is untuned, the same
/// disclosure ADR-0010 / ADR-0011 / ADR-0012 make for their groups.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 6.2 contour (Tạo khối)", .serialized)
struct ContourRenderTests {
    static var width: Int { ContourFixture.width }
    static var height: Int { ContourFixture.height }
    static var source: [Float] { ContourFixture.chart.pixels }

    static let allContour = ContourSliders(cheek: 100, nose: 100, jaw: 100)

    // MARK: - Layout

    @Test("ContourLobe has the layout ColorShaders.metal declares")
    func lobeStructMatchesShaderLayout() {
        // 3 x float2 (24) + 2 x float (8) = 32, and float2's alignment is 8, so
        // there is no tail padding to disagree about.
        #expect(MemoryLayout<ContourLobe>.stride == 32)
        #expect(MemoryLayout<ContourLobe>.alignment == 8)
        // One more `uint` on the end of ColorParams, which had 4 bytes of tail
        // padding to spend — so the stride the colour group pinned is unchanged.
        #expect(MemoryLayout<ColorParams>.stride == 96)
        #expect(ContourMask.lobesPerFace * MemoryLayout<ContourLobe>.stride <= 512)
    }

    // MARK: - Sliders

    @Test("The three amounts are 0…100, default 0, and round-trip through EditState")
    func slidersAreZeroToOneHundredInTheFaceSection() {
        #expect(ContourSliders().isIdentity)
        #expect(ContourSliders(cheek: 1).isIdentity == false)
        for key in ContourSliders.Key.all {
            let range = Slider.range(for: key, in: EditState.SectionKey.face)
            #expect(range == 0...100, "\(key) range \(range)")
        }
        // Out of range in both directions, and NaN, all land on the clamp.
        #expect(ContourSliders(cheek: 180).cheek == 100)
        #expect(ContourSliders(nose: -40).nose == 0)
        #expect(ContourSliders(jaw: .nan).jaw == 0)

        var state = EditState()
        Self.allContour.write(into: &state)
        #expect(ContourSliders(state) == Self.allContour)
        // …and the reshape group in the same section is untouched by it, which
        // is what the `contour…` key prefix is for.
        #expect(FaceSliders(state).isIdentity)
    }

    // MARK: - Default off

    @Test("With the flag off there are no lobes and the render is bit-exact the old one")
    func flagOffIsBitExactTheOldRender() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.enableColorRenderGraph() }
        defer { flags.leave { RPEngineFeatureFlags.disableColorRenderGraph() } }
        #expect(RPEngineFeatureFlags.contourSliders == false)

        let node = try ColorRenderNode(context: context)
        let request = ContourFixture.request(Self.allContour)
        #expect(node.contourLobes(for: request).isEmpty)
        #expect(node.isActive(for: request) == false)
        let output = try ContourFixture.run(node, context: context, request: request)
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)

        // …and with a colour grade on top, the graded picture is bit-exact the
        // one the colour group shipped: the contour branch costs nothing and
        // changes nothing while the flag is off.
        let graded = ContourFixture.request(Self.allContour, color: ColorSliders(contrast: 40))
        let withContourSliders = try ContourFixture.run(node, context: context, request: graded)
        let colourOnly = ContourFixture.request(ContourSliders(), color: ColorSliders(contrast: 40))
        let withoutContourSliders = try ContourFixture.run(
            node, context: context, request: colourOnly)
        #expect(
            SpikeTextureIO.maxAbsoluteDifference(withContourSliders, withoutContourSliders) == 0)
    }

    @Test("With the flag on, the three sliders at 0 are still a bit-exact identity")
    func slidersAtZeroAreBitExactIdentity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let request = ContourFixture.request(ContourSliders())
        #expect(node.contourLobes(for: request).isEmpty)
        #expect(node.isActive(for: request) == false)
        let output = try ContourFixture.run(node, context: context, request: request)
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)
    }

    @Test("No face means no lobes, and the colour grade is unaffected")
    func noFaceMeansNoContour() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        var state = EditState()
        Self.allContour.write(into: &state)
        let faceless = RenderRequest(editState: state, faces: [], quality: .preview)
        #expect(node.contourLobes(for: faceless).isEmpty)
        #expect(node.isActive(for: faceless) == false)
        let output = try ContourFixture.run(node, context: context, request: faceless)
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) == 0)

        // A face whose mesh is unusable (too few points) is the same story.
        let stub = FaceRenderInput(landmarks: [CGPoint(x: 1, y: 1)], faceWidth: 10)
        let broken = RenderRequest(editState: state, faces: [stub], quality: .preview)
        #expect(node.contourLobes(for: broken).isEmpty)
    }

    // MARK: - Lobe construction

    @Test("Each slider builds its own lobes and nobody else's")
    func eachSliderBuildsItsOwnLobes() throws {
        let face = ContourFixture.chart.face
        func count(_ sliders: ContourSliders) -> Int {
            ContourMask.lobes(faces: [face], sliders: sliders).count
        }
        #expect(count(ContourSliders()) == 0)
        #expect(count(ContourSliders(cheek: 100)) == 4)  // 2 highlights + 2 shadows
        #expect(count(ContourSliders(nose: 100)) == 1)
        #expect(count(ContourSliders(jaw: 100)) == 6)  // 3 segments per side
        #expect(count(Self.allContour) == ContourMask.lobesPerFace)

        // Highlights dodge, shadows burn — the sign is the direction, and it is
        // the only thing that makes this one kernel step do both jobs.
        let cheek = ContourMask.lobes(faces: [face], sliders: ContourSliders(cheek: 100))
        #expect(cheek.filter { $0.strength > 0 }.count == 2)
        #expect(cheek.filter { $0.strength < 0 }.count == 2)
        let nose = ContourMask.lobes(faces: [face], sliders: ContourSliders(nose: 100))
        #expect(nose.allSatisfy { $0.strength > 0 })
        let jaw = ContourMask.lobes(faces: [face], sliders: ContourSliders(jaw: 100))
        #expect(jaw.allSatisfy { $0.strength < 0 })
    }

    @Test("Strength scales with the slider and every extent scales with face width")
    func lobesScaleWithSliderAndFaceWidth() throws {
        let face = ContourFixture.chart.face
        let half = ContourMask.lobes(faces: [face], sliders: ContourSliders(cheek: 50))
        let full = ContourMask.lobes(faces: [face], sliders: ContourSliders(cheek: 100))
        for (a, b) in zip(half, full) {
            #expect(abs(Double(a.strength) * 2 - Double(b.strength)) < 1e-5)
            // The geometry is the slider's business only through `strength`.
            #expect(a.centre == b.centre)
            #expect(a.halfExtent == b.halfExtent)
        }

        // Twice the face, twice every length — the property that lets a preset
        // carry these three numbers between images (docs/PLAN.md §2).
        let small = SyntheticFaceMesh.renderInput(width: 100, centre: CGPoint(x: 200, y: 200))
        let big = SyntheticFaceMesh.renderInput(width: 200, centre: CGPoint(x: 400, y: 400))
        let smallLobes = ContourMask.lobes(faces: [small], sliders: Self.allContour)
        let bigLobes = ContourMask.lobes(faces: [big], sliders: Self.allContour)
        #expect(smallLobes.count == bigLobes.count)
        for (a, b) in zip(smallLobes, bigLobes) {
            let ratioAlong = Double(b.halfExtent.x) / Double(a.halfExtent.x)
            let ratioAcross = Double(b.halfExtent.y) / Double(a.halfExtent.y)
            #expect(abs(ratioAlong - 2) < 1e-3, "along ratio \(ratioAlong)")
            #expect(abs(ratioAcross - 2) < 1e-3, "across ratio \(ratioAcross)")
            #expect(abs(Double(a.strength) - Double(b.strength)) < 1e-6)
        }
    }

    @Test("Several faces each get their own lobes, up to the cap")
    func severalFacesAndTheCap() {
        let faces = (0..<3).map {
            SyntheticFaceMesh.renderInput(
                width: 120, centre: CGPoint(x: 150 + 200 * Double($0), y: 200))
        }
        #expect(
            ContourMask.lobes(faces: faces, sliders: Self.allContour).count
                == 3 * ContourMask.lobesPerFace)

        let crowd = (0..<40).map {
            SyntheticFaceMesh.renderInput(
                width: 120, centre: CGPoint(x: 150 + 200 * Double($0), y: 200))
        }
        let capped = ContourMask.lobes(faces: crowd, sliders: Self.allContour)
        #expect(capped.count <= ContourMask.maxLobes)
        // Whole faces only: a half-drawn face would be a visible asymmetry.
        #expect(capped.count % ContourMask.lobesPerFace == 0)
    }

    @Test("The mask is exactly 0 outside every lobe, and peaks where the lobe says")
    func maskIsZeroOutsideEveryLobe() {
        let lobes = ContourFixture.chart.allLobes
        for lobe in lobes {
            let centre = CGPoint(x: CGFloat(lobe.centre.x), y: CGFloat(lobe.centre.y))
            let peak = ContourMask.value(at: centre, lobes: [lobe])
            #expect(abs(peak - Double(lobe.strength)) < 1e-9)
            // Just past the rim, on both axes: exactly 0, not merely small.
            let u = CGVector(dx: CGFloat(lobe.axisU.x), dy: CGFloat(lobe.axisU.y))
            let reach = CGFloat(lobe.halfExtent.x) * 1.001
            let alongOutside = CGPoint(x: centre.x + u.dx * reach, y: centre.y + u.dy * reach)
            #expect(ContourMask.value(at: alongOutside, lobes: [lobe]) == 0)
            let across = CGFloat(lobe.halfExtent.y) * 1.001
            let acrossOutside = CGPoint(
                x: centre.x - u.dy * across, y: centre.y + u.dx * across)
            #expect(ContourMask.value(at: acrossOutside, lobes: [lobe]) == 0)
        }
        // The clamp is the last thing that happens, so the sum can never leave
        // -1…1 no matter how many lobes pile up.
        for y in stride(from: 0, to: ContourFixture.height, by: 7) {
            for x in stride(from: 0, to: ContourFixture.width, by: 7) {
                let m = ContourMask.value(
                    at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), lobes: lobes)
                #expect(m >= -1 && m <= 1)
            }
        }
    }

    @Test("The forehead-centre control probe is outside every lobe")
    func foreheadProbeIsOutsideEveryLobe() {
        let lobes = ContourFixture.chart.allLobes
        var worst = 0.0
        for i in 0..<ContourFixture.chart.regions.count
        where ContourFixture.chart.regions[i] == .foreheadCentre {
            let x = i % ContourFixture.width
            let y = i / ContourFixture.width
            worst = max(
                worst,
                abs(
                    ContourMask.value(
                        at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), lobes: lobes)))
        }
        print("P6.2 contour: worst |mask| over the forehead control probe = \(worst)")
        #expect(worst == 0)
    }

    // MARK: - Accuracy

    @Test("The mask-gated composite matches the Double reference at ≥ 45 dB")
    func contourMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let request = ContourFixture.request(Self.allContour)
        let output = try ContourFixture.run(node, context: context, request: request)
        let reference = try Self.reference(node: node, context: context, request: request)
        let psnr = SpikeTextureIO.psnr(reference, output)
        let worst = SpikeTextureIO.maxAbsoluteDifference(reference, output)
        print("P6.2 contour vs Double reference: PSNR = \(psnr) dB, max abs = \(worst)")
        #expect(psnr >= 45, "contour PSNR \(psnr) dB")
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.source, output) > 1e-3)
    }

    @Test(
        "Each contour slider alone matches the reference",
        arguments: [
            ("cheek", ContourSliders(cheek: 100)),
            ("nose", ContourSliders(nose: 100)),
            ("jaw", ContourSliders(jaw: 100)),
            ("all at 40", ContourSliders(cheek: 40, nose: 40, jaw: 40)),
        ])
    func eachSliderAloneMatchesReference(name: String, sliders: ContourSliders) throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let request = ContourFixture.request(sliders)
        let output = try ContourFixture.run(node, context: context, request: request)
        let reference = try Self.reference(node: node, context: context, request: request)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P6.2 contour '\(name)' vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "\(name) PSNR \(psnr) dB")
        #expect(
            SpikeTextureIO.maxAbsoluteDifference(Self.source, output) > 1e-3,
            "\(name) changed nothing")
    }

    /// Contour on top of a full colour grade — including Auto D&B, so the
    /// contour step and the global dodge/burn step run on the same pixels and a
    /// mix-up between the two would show here.
    @Test("Contour under a full colour grade matches the reference at ≥ 45 dB")
    func contourWithAFullGradeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let request = ContourFixture.request(
            Self.allContour, color: ColorRenderNodeTests.allSliders)
        let output = try ContourFixture.run(node, context: context, request: request)
        let reference = try Self.reference(node: node, context: context, request: request)
        let psnr = SpikeTextureIO.psnr(reference, output)
        print("P6.2 contour + full grade vs Double reference: PSNR = \(psnr) dB")
        #expect(psnr >= 45, "contour + grade PSNR \(psnr) dB")

        // …and it is not the same picture as the grade alone.
        let gradeOnly = ContourFixture.request(
            ContourSliders(), color: ColorRenderNodeTests.allSliders)
        let graded = try ContourFixture.run(node, context: context, request: gradeOnly)
        #expect(SpikeTextureIO.maxAbsoluteDifference(graded, output) > 1e-3)
    }

    // MARK: - Selectivity

    @Test("Gò má lightens the cheekbone, darkens the hollow, and leaves the forehead at exactly 0")
    func cheekIsSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let output = try ContourFixture.run(
            node, context: context, request: ContourFixture.request(ContourSliders(cheek: 100)))
        let highlight = ContourFixture.meanLuminanceChange(Self.source, output, .cheekHighlight)
        let shadow = ContourFixture.meanLuminanceChange(Self.source, output, .cheekShadow)
        let forehead = ContourFixture.maxChange(Self.source, output, .foreheadCentre)
        let outside = ContourFixture.maxChange(Self.source, output, .outsideFace)
        let nose = ContourFixture.maxChange(Self.source, output, .noseBridge)
        print(
            "P6.2 contour cheek: highlight \(highlight), hollow \(shadow), "
                + "forehead max |Δ| \(forehead), outside max |Δ| \(outside), nose max |Δ| \(nose)")
        #expect(highlight > 0.01, "the cheekbone was not lightened (\(highlight))")
        #expect(shadow < -0.01, "the hollow was not darkened (\(shadow))")
        #expect(forehead == 0, "the forehead centre moved by \(forehead)")
        #expect(outside == 0, "outside the face moved by \(outside)")
        #expect(nose == 0, "the nose bridge moved by \(nose)")
    }

    @Test("Sống mũi lightens the bridge and leaves the cheeks and forehead at exactly 0")
    func noseIsSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let output = try ContourFixture.run(
            node, context: context, request: ContourFixture.request(ContourSliders(nose: 100)))
        let bridge = ContourFixture.meanLuminanceChange(Self.source, output, .noseBridge)
        let cheek = ContourFixture.maxChange(Self.source, output, .cheekHighlight)
        let hollow = ContourFixture.maxChange(Self.source, output, .cheekShadow)
        let forehead = ContourFixture.maxChange(Self.source, output, .foreheadCentre)
        print(
            "P6.2 contour nose: bridge \(bridge), cheek max |Δ| \(cheek), "
                + "hollow max |Δ| \(hollow), forehead max |Δ| \(forehead)")
        #expect(bridge > 0.01, "the bridge was not lightened (\(bridge))")
        #expect(cheek == 0, "the cheekbone moved by \(cheek)")
        #expect(hollow == 0, "the cheek hollow moved by \(hollow)")
        #expect(forehead == 0, "the forehead centre moved by \(forehead)")
    }

    @Test("Hàm darkens the jaw band and leaves the forehead and the background at exactly 0")
    func jawIsSelective() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterContourRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableContourAndColor() } }

        let node = try ColorRenderNode(context: context)
        let output = try ContourFixture.run(
            node, context: context, request: ContourFixture.request(ContourSliders(jaw: 100)))
        let jaw = ContourFixture.meanLuminanceChange(Self.source, output, .jaw)
        let forehead = ContourFixture.maxChange(Self.source, output, .foreheadCentre)
        let outside = ContourFixture.maxChange(Self.source, output, .outsideFace)
        let nose = ContourFixture.maxChange(Self.source, output, .noseBridge)
        print(
            "P6.2 contour jaw: jaw \(jaw), forehead max |Δ| \(forehead), "
                + "outside max |Δ| \(outside), nose max |Δ| \(nose)")
        #expect(jaw < -0.01, "the jaw band was not darkened (\(jaw))")
        #expect(forehead == 0, "the forehead centre moved by \(forehead)")
        #expect(outside == 0, "outside the face moved by \(outside)")
        #expect(nose == 0, "the nose bridge moved by \(nose)")
    }

    // MARK: - Locality

    @Test("The mask is local: it claims a small fraction of the frame")
    func maskIsLocalNotGlobal() {
        let lobes = ContourFixture.chart.allLobes
        let any = ContourFixture.coverage(lobes, threshold: 0)
        let strong = ContourFixture.coverage(lobes, threshold: 0.25)
        print("P6.2 contour coverage: |mask| > 0 on \(any), > 0.25 on \(strong) of the frame")
        // The whole point of §6.2: "theo mesh, không toàn khung".
        #expect(any < 0.35, "the mask touches \(any) of the frame")
        #expect(strong < 0.15, "the mask is strong over \(strong) of the frame")
        #expect(any > 0.02, "the mask touches almost nothing (\(any))")
    }

    // MARK: - Helpers

    /// The `Double` reference for one request, fed the node's **own** analysis
    /// planes and its **own** uploaded lobes — so a disagreement is the kernel's
    /// mask evaluation and not a second transcription of the geometry. Call it
    /// after `ContourFixture.run`, which is what populates `debugAnalysis()`.
    static func reference(node: ColorRenderNode, context: MetalContext, request: RenderRequest)
        throws -> [Float]
    {
        var big: [Double] = []
        var small: [Double] = []
        var size = (width: 1, height: 1)
        if let analysis = node.debugAnalysis() {
            size = (analysis.big.width, analysis.big.height)
            big = try ColorRenderNodeTests.readR32(analysis.big, queue: context.commandQueue)
            small = try ColorRenderNodeTests.readR32(analysis.small, queue: context.commandQueue)
        }
        return ColorReference.composite(
            source: source, width: width, height: height, big: big, small: small,
            analysisSize: size, amounts: ColorReference.Amounts(ColorSliders(request.editState)),
            curveTable: node.curveTable, contourLobes: node.contourLobes(for: request))
    }
}
