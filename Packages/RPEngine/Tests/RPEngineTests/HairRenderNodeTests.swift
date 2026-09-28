import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 5 "Tóc" — the slider model, with no GPU.
@Suite("Phase 5 hair sliders (model)", .serialized)
struct HairSlidersTests {
    @Test("The five keys round-trip through EditState's hair section")
    func keysRoundTrip() {
        let sliders = HairSliders(gloss: 40, lighten: 10, darken: 20, dye: 70, dyeTone: 55)
        var state = EditState()
        sliders.write(into: &state)
        #expect(HairSliders(state) == sliders)
        #expect(Set(state[section: EditState.SectionKey.hair].values.keys) == Set(HairSliders.Key.all))
    }

    @Test("Everything at 0 writes nothing, so the document stays default")
    func zeroWritesNothing() {
        var state = EditState()
        HairSliders().write(into: &state)
        #expect(state.isDefault)
        #expect(HairSliders(state).isIdentity)
    }

    @Test("Tông màu alone is a modifier and changes nothing")
    func toneAloneIsIdentity() {
        #expect(HairSliders(dyeTone: 80).isIdentity)
        #expect(!HairSliders(dye: 1).isIdentity)
    }

    @Test("Values are clamped to 0…100")
    func clamps() {
        let sliders = HairSliders(gloss: 140, lighten: -5, darken: .nan, dye: 100, dyeTone: 101)
        #expect(sliders.gloss == 100)
        #expect(sliders.lighten == 0)
        #expect(sliders.darken == 0)
        #expect(sliders.dyeTone == 100)
    }

    @Test("Only Bóng tóc needs the blurred layer")
    func onlyGlossNeedsTheLayer() {
        #expect(HairSliders(gloss: 1).needsLocalMeanLayer)
        #expect(!HairSliders(lighten: 100, darken: 100, dye: 100).needsLocalMeanLayer)
    }

    @Test("The lightness exponent is 1 at rest and the two sliders multiply")
    func lightnessExponent() {
        #expect(HairSliders().lightnessExponent == 1)
        #expect(abs(HairSliders(lighten: 100).lightnessExponent - HairSliders.lightenExponent) < 1e-12)
        #expect(abs(HairSliders(darken: 100).lightnessExponent - HairSliders.darkenExponent) < 1e-12)
        let both = HairSliders(lighten: 50, darken: 50).lightnessExponent
        let expected = HairSliders(lighten: 50).lightnessExponent
            * HairSliders(darken: 50).lightnessExponent
        #expect(abs(both - expected) < 1e-12)
        #expect(HairSliders(lighten: 30).lightnessExponent < 1)
        #expect(HairSliders(darken: 30).lightnessExponent > 1)
    }

    @Test("Every dye tint has luma 1, so the dye keeps the pixel's brightness")
    func dyeTintIsLumaNormalised() {
        for tone in stride(from: 0.0, through: 100.0, by: 12.5) {
            let tint = HairSliders.dyeTint(tone: tone)
            let y = (tint * HairSliders.lumaWeights).sum()
            #expect(abs(y - 1) < 1e-9, "tone \(tone): luma \(y)")
        }
    }

    @Test("The tint's ends are the palette's ends")
    func dyeTintEnds() {
        func direction(_ c: SIMD3<Double>) -> SIMD3<Double> {
            c / (c * HairSliders.lumaWeights).sum()
        }
        func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let d = a - b
            return (d * d).sum().squareRoot()
        }
        let first = direction(HairSliders.dyePalette[0])
        let last = direction(HairSliders.dyePalette[HairSliders.dyePalette.count - 1])
        #expect(distance(HairSliders.dyeTint(tone: 0), first) < 1e-9)
        #expect(distance(HairSliders.dyeTint(tone: 100), last) < 1e-9)
        // Copper sits at 25 and must be redder than the ash brown at 0.
        let copper = HairSliders.dyeTint(tone: 25)
        #expect(copper.x / copper.z > first.x / first.z)
    }

    @Test("The shader parameter struct has the layout HairShaders.metal declares")
    func parameterStructMatchesShaderLayout() {
        // uint2 + 6 floats = 32, then a 16-aligned float4.
        #expect(MemoryLayout<HairParams>.stride == 48)
        #expect(MemoryLayout<HairParams>.offset(of: \HairParams.dyeTint) == 32)
    }

    @Test("A hair mask at 0 coverage is not usable; one at a few percent is")
    func coverageThreshold() {
        func mask(filled: Int) -> RenderMask {
            var values = [UInt8](repeating: 0, count: 100 * 100)
            for i in 0..<filled { values[i] = 255 }
            return RenderMask(width: 100, height: 100, values: values, maskToImage: .identity)
        }
        #expect(!HairRenderNode.isUsableHairCoverage(mask(filled: 0)))
        #expect(!HairRenderNode.isUsableHairCoverage(mask(filled: 5)))
        #expect(HairRenderNode.isUsableHairCoverage(mask(filled: 300)))
    }

    @Test("The mask requirements ask for hair when the hair group is on")
    func maskRequirementsFollowTheFlag() {
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.hairSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        #expect(!RenderMaskRequirements.forEnabledGroups().contains(.hair))
        RPEngineFeatureFlags.hairSliders = true
        #expect(RenderMaskRequirements.forEnabledGroups().contains(.hair))
    }

    @Test("Turning another guided-filter group off keeps the hair group's kernel flag")
    func sharedKernelFlagSurvivesOtherGroups() {
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableHairRenderGraph()
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.enableEyesTeethRenderGraph()
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.disableHairRenderGraph()
                RPEngineFeatureFlags.disableSkinRenderGraph()
                RPEngineFeatureFlags.disableEyesTeethRenderGraph()
            }
        }
        RPEngineFeatureFlags.disableSkinRenderGraph()
        RPEngineFeatureFlags.disableEyesTeethRenderGraph()
        #expect(RPEngineFeatureFlags.guidedFilter)
        RPEngineFeatureFlags.disableHairRenderGraph()
        #expect(!RPEngineFeatureFlags.guidedFilter)
    }
}

/// Phase 5 "Tóc" — the node on a GPU. Every test returns early when there is no
/// Metal device, like every other render suite.
@Suite("Phase 5 hair sliders (render)", .serialized)
struct HairRenderNodeTests {
    static let fixture = HairReference.fixture()

    static let allSliders = HairSliders(gloss: 60, lighten: 30, darken: 15, dye: 70, dyeTone: 40)

    static func request(_ sliders: HairSliders, faces: [FaceRenderInput]? = nil) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        return RenderRequest(editState: state, faces: faces ?? [fixture.face])
    }

    static func runNode(_ node: HairRenderNode, context: MetalContext, request: RenderRequest)
        throws -> [Float]
    {
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: fixture.pixels, width: fixture.width, height: fixture.height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: fixture.width, height: fixture.height, device: context.device,
            pixelFormat: .rgba32Float, usage: [.shaderRead, .shaderWrite])
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        try node.encode(
            into: commandBuffer, source: source, destination: destination, request: request)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try RenderGraph.readFloat32(destination, queue: context.commandQueue)
    }

    @Test("The node refuses to build with its flag off")
    func flagGatesConstruction() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.guidedFilter = true
            RPEngineFeatureFlags.hairSliders = false
        }
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        #expect(throws: RPEngineFeatureDisabled.self) { _ = try HairRenderNode(context: context) }
    }

    @Test("The standard graph registers the hair node only when its flag is on")
    func standardGraphRegistration() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.hairSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let without = try RenderGraph.standard(context: context)
        #expect(!without.nodes.contains { $0.name == "hair" })
        RPEngineFeatureFlags.enableHairRenderGraph()
        let with = try RenderGraph.standard(context: context)
        #expect(with.nodes.map(\.name).contains("hair"))
    }

    @Test("All sliders at 0 is a bit-exact identity even with a full mask")
    func allZeroIsBitExact() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let node = try HairRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(HairSliders(dyeTone: 70)))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.fixture.pixels, output) == 0)
        #expect(!node.isActive(for: Self.request(HairSliders(dyeTone: 70))))
    }

    @Test("Pixels outside the hair mask are bit-exact")
    func outsideTheMaskIsBitExact() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let node = try HairRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        var worst: Float = 0
        for i in Self.fixture.isOutside.indices where Self.fixture.isOutside[i] {
            for k in 0..<4 {
                worst = max(worst, abs(output[i * 4 + k] - Self.fixture.pixels[i * 4 + k]))
            }
        }
        #expect(worst == 0, "max change outside the mask \(worst)")
    }

    @Test("The composite matches the Double reference fed the node's own layers (≥ 45 dB)")
    func compositeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let fixture = Self.fixture
        for sliders in [
            Self.allSliders, HairSliders(gloss: 100), HairSliders(lighten: 100),
            HairSliders(darken: 100), HairSliders(dye: 100, dyeTone: 0),
            HairSliders(dye: 100, dyeTone: 100),
        ] {
            let node = try HairRenderNode(context: context)
            let output = try Self.runNode(node, context: context, request: Self.request(sliders))
            let layers = try #require(node.debugLayers())
            let mask = try SkinRenderNodeTests.readR8(
                try #require(layers.hair), queue: context.commandQueue)
            var low = fixture.pixels
            if let texture = layers.low {
                low = try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
            }
            #expect((layers.low != nil) == sliders.needsLocalMeanLayer)
            let reference = HairReference.composite(
                pixels: fixture.pixels, low: low, mask: mask, width: fixture.width,
                height: fixture.height, sliders: sliders)
            let psnr = SpikeTextureIO.psnr(reference, output)
            print("P5 hair composite vs Double reference \(sliders): \(psnr) dB")
            #expect(psnr >= 45, "\(sliders): \(psnr) dB")
        }
    }

    @Test("Each slider moves hair luma the way its label says, and dye keeps it")
    func selectivity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let fixture = Self.fixture
        let before = HairReference.meanLuma(fixture.pixels, where: fixture.isHair)

        let node = try HairRenderNode(context: context)
        let lighter = try Self.runNode(
            node, context: context, request: Self.request(HairSliders(lighten: 100)))
        let darker = try Self.runNode(
            node, context: context, request: Self.request(HairSliders(darken: 100)))
        let dyed = try Self.runNode(
            node, context: context, request: Self.request(HairSliders(dye: 100, dyeTone: 25)))

        let lighterLuma = HairReference.meanLuma(lighter, where: fixture.isHair)
        let darkerLuma = HairReference.meanLuma(darker, where: fixture.isHair)
        let dyedLuma = HairReference.meanLuma(dyed, where: fixture.isHair)
        print("P5 hair mean luma: before \(before), lighten \(lighterLuma), darken \(darkerLuma), dye \(dyedLuma)")
        #expect(lighterLuma > before * 1.3)
        #expect(darkerLuma < before * 0.8)
        // Luma-preserving by construction; only the final clamp can move it.
        #expect(abs(dyedLuma - before) < 0.01)

        // The dye moved the hair's chroma toward copper: red over blue rises.
        func redOverBlue(_ pixels: [Float]) -> Double {
            var r = 0.0
            var b = 0.0
            for i in fixture.isHair.indices where fixture.isHair[i] {
                r += Double(pixels[i * 4])
                b += Double(pixels[i * 4 + 2])
            }
            return r / max(b, 1e-9)
        }
        #expect(redOverBlue(dyed) > redOverBlue(fixture.pixels))
    }

    @Test("Gloss lifts the strands that are brighter than their neighbourhood")
    func glossLiftsHighlights() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let fixture = Self.fixture
        let node = try HairRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(HairSliders(gloss: 100)))
        // Split hair pixels by source luma: the bright half must gain more than
        // the dark half, i.e. the stripe contrast goes up.
        var lumas: [(Double, Double)] = []
        for i in fixture.isHair.indices where fixture.isHair[i] {
            let o = i * 4
            let a = (SIMD3(Double(fixture.pixels[o]), Double(fixture.pixels[o + 1]),
                           Double(fixture.pixels[o + 2])) * HairReference.luma).sum()
            let b = (SIMD3(Double(output[o]), Double(output[o + 1]), Double(output[o + 2]))
                     * HairReference.luma).sum()
            lumas.append((a, b))
        }
        let median = lumas.map(\.0).sorted()[lumas.count / 2]
        let bright = lumas.filter { $0.0 > median }
        let dark = lumas.filter { $0.0 <= median }
        let brightGain = bright.map { $0.1 - $0.0 }.reduce(0, +) / Double(bright.count)
        let darkGain = dark.map { $0.1 - $0.0 }.reduce(0, +) / Double(dark.count)
        print("P5 hair gloss: bright-half gain \(brightGain), dark-half gain \(darkGain)")
        #expect(brightGain > darkGain)
        #expect(brightGain > 0)
    }

    @Test("No hair mask: inactive; empty hair mask: the node says so")
    func detectionNotice() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHairRenderGraph()
        defer { flags.leave { RPEngineFeatureFlags.disableHairRenderGraph() } }
        let node = try HairRenderNode(context: context)

        var noHair = Self.fixture.face
        noHair.masks[.hair] = nil
        #expect(!node.isActive(for: Self.request(Self.allSliders, faces: [noHair])))
        #expect(
            node.detectionNotice(for: Self.request(Self.allSliders, faces: [noHair]))
                == HairRenderNode.noHairNotice)

        var empty = Self.fixture.face
        let mask = try #require(empty.masks[.hair])
        empty.masks[.hair] = RenderMask(
            width: mask.width, height: mask.height,
            values: [UInt8](repeating: 0, count: mask.values.count),
            maskToImage: mask.maskToImage)
        #expect(
            node.detectionNotice(for: Self.request(Self.allSliders, faces: [empty]))
                == HairRenderNode.noHairNotice)

        // Healthy frame, sliders at 0, or no face at all: nothing to report.
        #expect(node.detectionNotice(for: Self.request(Self.allSliders)) == nil)
        #expect(node.detectionNotice(for: Self.request(HairSliders(), faces: [empty])) == nil)
        #expect(node.detectionNotice(for: Self.request(Self.allSliders, faces: [])) == nil)

        // Flag off after construction: the user cannot have asked for it.
        RPEngineFeatureFlags.hairSliders = false
        #expect(node.detectionNotice(for: Self.request(Self.allSliders, faces: [empty])) == nil)
    }
}
