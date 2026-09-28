import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 5 "Trang điểm" — the slider model and the blush geometry, no GPU.
@Suite("Phase 5 makeup sliders (model)", .serialized)
struct MakeupSlidersTests {
    @Test("The four keys round-trip through EditState's makeup section")
    func keysRoundTrip() {
        let sliders = MakeupSliders(lipstick: 60, lipTone: 50, blush: 30, brows: 20)
        var state = EditState()
        sliders.write(into: &state)
        #expect(MakeupSliders(state) == sliders)
        #expect(
            Set(state[section: EditState.SectionKey.makeup].values.keys) == Set(MakeupSliders.Key.all))
    }

    @Test("Everything at 0 writes nothing; Tông son alone is a modifier")
    func identity() {
        var state = EditState()
        MakeupSliders().write(into: &state)
        #expect(state.isDefault)
        #expect(MakeupSliders(lipTone: 90).isIdentity)
        #expect(!MakeupSliders(brows: 1).isIdentity)
        #expect(MakeupSliders().browsLumaExponent == 1)
    }

    @Test("Values are clamped to 0…100")
    func clamps() {
        let sliders = MakeupSliders(lipstick: 250, lipTone: -1, blush: .infinity, brows: 50)
        #expect(sliders.lipstick == 100)
        #expect(sliders.lipTone == 0)
        #expect(sliders.blush == 0)  // non-finite → default
        #expect(sliders.brows == 50)
    }

    @Test("Lip tints are luma-normalised and carry the palette colour's own luma")
    func lipTint() {
        for tone in stride(from: 0.0, through: 100.0, by: 10) {
            let tint = MakeupSliders.lipTint(tone: tone)
            #expect(abs((tint.normalised * MakeupSliders.lumaWeights).sum() - 1) < 1e-9)
            #expect(tint.luma > 0.05 && tint.luma < 0.8)
        }
        let red = MakeupSliders.lipTint(tone: 50)
        let nude = MakeupSliders.lipTint(tone: 0)
        // Red is darker and redder than nude — the reason the luma pull exists.
        #expect(red.luma < nude.luma)
        #expect(red.normalised.x / red.normalised.y > nude.normalised.x / nude.normalised.y)
        #expect(abs((MakeupSliders.blushTint * MakeupSliders.lumaWeights).sum() - 1) < 1e-9)
    }

    @Test("The shader parameter struct has the layout MakeupShaders.metal declares")
    func parameterLayout() {
        #expect(MemoryLayout<MakeupParams>.stride == 64)
        #expect(MemoryLayout<MakeupParams>.offset(of: \MakeupParams.lipTint) == 32)
        #expect(MemoryLayout<MakeupParams>.offset(of: \MakeupParams.blushTint) == 48)
        // The lobes are bound as ColorShaders' `ContourLobe`.
        #expect(MemoryLayout<ContourLobe>.stride == 32)
    }

    @Test("An absent mask forces its amount to 0 in the parameters")
    func absentMaskZeroesTheAmount() {
        let sliders = MakeupSliders(lipstick: 80, blush: 80, brows: 80)
        let none = MakeupParams(
            sliders: sliders, width: 4, height: 4, hasLips: false, hasBrows: false,
            blushLobeCount: 0)
        #expect(none.lipstick == 0)
        #expect(none.blush == 0)
        #expect(none.browsExponent == 1)
        let all = MakeupParams(
            sliders: sliders, width: 4, height: 4, hasLips: true, hasBrows: true,
            blushLobeCount: 2)
        #expect(all.lipstick == 0.8)
        #expect(all.blush == 0.8)
        #expect(all.browsExponent > 1)
    }

    @Test("Blush: two lobes per face, one per cheek, between the eye and mouth lines")
    func blushGeometry() throws {
        let face = SyntheticFaceMesh.renderInput(width: 200, centre: CGPoint(x: 300, y: 300))
        let lobes = BlushMask.lobes(faces: [face])
        #expect(lobes.count == 2)
        let frame = try #require(FaceMeshFrame(landmarks: face.landmarks, faceWidth: face.faceWidth))
        let us = lobes.map { frame.u(CGPoint(x: CGFloat($0.centre.x), y: CGFloat($0.centre.y))) }
        #expect(us[0] > 0 && us[1] < 0, "one lobe on each side of the midline: \(us)")
        #expect(abs(us[0] + us[1]) < 0.05 * face.faceWidth, "a frontal face gets symmetric blush")
        for lobe in lobes {
            let t = frame.t(CGPoint(x: CGFloat(lobe.centre.x), y: CGFloat(lobe.centre.y)))
            #expect(t > frame.tEyeLine && t < frame.tMouthLine)
            #expect(lobe.strength == 1)
        }
        // Sizes follow the face: twice the face, twice the lobe.
        let big = BlushMask.lobes(
            faces: [SyntheticFaceMesh.renderInput(width: 400, centre: CGPoint(x: 300, y: 300))])
        #expect(abs(big[0].halfExtent.x / lobes[0].halfExtent.x - 2) < 0.02)
    }

    @Test("No mesh, no blush")
    func blushNeedsTheMesh() {
        #expect(BlushMask.lobes(faces: [FaceRenderInput(faceWidth: 100)]).isEmpty)
    }

    @Test("The mask requirements ask for lips, brows and skin when the group is on")
    func maskRequirementsFollowTheFlag() {
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.makeupSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        #expect(!RenderMaskRequirements.forEnabledGroups().contains(.lips))
        RPEngineFeatureFlags.makeupSliders = true
        let kinds = RenderMaskRequirements.forEnabledGroups()
        #expect(kinds.isSuperset(of: [.lips, .brows, .skin]))
    }
}

/// Phase 5 "Trang điểm" — the node on a GPU; returns early without Metal.
@Suite("Phase 5 makeup sliders (render)", .serialized)
struct MakeupRenderNodeTests {
    static let fixture = MakeupReference.fixture()
    static let allSliders = MakeupSliders(lipstick: 70, lipTone: 50, blush: 80, brows: 60)

    static func request(_ sliders: MakeupSliders, faces: [FaceRenderInput]? = nil) -> RenderRequest {
        var state = EditState()
        sliders.write(into: &state)
        return RenderRequest(editState: state, faces: faces ?? [fixture.face])
    }

    static func runNode(_ node: MakeupRenderNode, context: MetalContext, request: RenderRequest)
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

    static func enter() -> RPEngineTestFlags.Scope {
        RPEngineTestFlags.enter { RPEngineFeatureFlags.makeupSliders = true }
    }

    @Test("The node refuses to build with its flag off, and the graph leaves it out")
    func flagGates() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.makeupSliders = false }
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        #expect(throws: RPEngineFeatureDisabled.self) { _ = try MakeupRenderNode(context: context) }
        let without = try RenderGraph.standard(context: context)
        #expect(!without.nodes.contains { $0.name == "makeup" })
        RPEngineFeatureFlags.makeupSliders = true
        let with = try RenderGraph.standard(context: context)
        #expect(with.nodes.map(\.name).contains("makeup"))
    }

    @Test("All amounts at 0 is bit-exact and inactive, whatever the tone")
    func zeroIsBitExact() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        let node = try MakeupRenderNode(context: context)
        let request = Self.request(MakeupSliders(lipTone: 70))
        #expect(!node.isActive(for: request))
        let output = try Self.runNode(node, context: context, request: request)
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.fixture.pixels, output) == 0)
    }

    @Test("Pixels outside every mask and lobe are bit-exact")
    func outsideIsBitExact() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        let node = try MakeupRenderNode(context: context)
        let output = try Self.runNode(node, context: context, request: Self.request(Self.allSliders))
        var worst: Float = 0
        for i in Self.fixture.outside.indices where Self.fixture.outside[i] {
            for k in 0..<4 { worst = max(worst, abs(output[i * 4 + k] - Self.fixture.pixels[i * 4 + k])) }
        }
        #expect(worst == 0, "max change outside \(worst)")
    }

    @Test("The composite matches the Double reference fed the node's own masks (≥ 45 dB)")
    func compositeMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        let fixture = Self.fixture
        for sliders in [
            Self.allSliders, MakeupSliders(lipstick: 100, lipTone: 0),
            MakeupSliders(lipstick: 100, lipTone: 100), MakeupSliders(blush: 100),
            MakeupSliders(brows: 100),
        ] {
            let node = try MakeupRenderNode(context: context)
            let output = try Self.runNode(node, context: context, request: Self.request(sliders))
            let layers = try #require(node.debugLayers())
            func read(_ t: (any MTLTexture)?) throws -> [Double]? {
                guard let t else { return nil }
                return try SkinRenderNodeTests.readR8(t, queue: context.commandQueue)
            }
            let lips = try read(layers.lips)
            let brows = try read(layers.brows)
            let skin = try read(layers.skin)
            #expect((lips != nil) == (sliders.lipstick > 0))
            #expect((brows != nil) == (sliders.brows > 0))
            #expect((skin != nil) == (sliders.blush > 0))
            let reference = MakeupReference.composite(
                pixels: fixture.pixels, width: fixture.width, height: fixture.height,
                sliders: sliders, lips: lips, brows: brows, skin: skin, lobes: layers.lobes)
            let psnr = SpikeTextureIO.psnr(reference, output)
            print("P5 makeup composite vs Double reference \(sliders): \(psnr) dB")
            #expect(psnr >= 45, "\(sliders): \(psnr) dB")
        }
    }

    @Test("Each slider acts on its own region, the way its label says")
    func selectivity() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        let f = Self.fixture
        let node = try MakeupRenderNode(context: context)
        let luma = { (c: SIMD3<Double>) in (c * MakeupReference.luma).sum() }
        let redOverGreen = { (c: SIMD3<Double>) in c.x / max(c.y, 1e-9) }

        // Red lipstick: lips redder and darker; brows and cheeks untouched.
        let lipped = try Self.runNode(
            node, context: context, request: Self.request(MakeupSliders(lipstick: 100, lipTone: 50)))
        let lipsRedBefore = MakeupReference.mean(f.pixels, where: f.lipsCore, redOverGreen)
        let lipsRedAfter = MakeupReference.mean(lipped, where: f.lipsCore, redOverGreen)
        let lipsLumaBefore = MakeupReference.mean(f.pixels, where: f.lipsCore, luma)
        let lipsLumaAfter = MakeupReference.mean(lipped, where: f.lipsCore, luma)
        let cheekBefore = MakeupReference.mean(f.pixels, where: f.cheekProbe, luma)
        let cheekAfterLipstick = MakeupReference.mean(lipped, where: f.cheekProbe, luma)
        #expect(lipsRedAfter > lipsRedBefore * 1.3)
        #expect(lipsLumaAfter < lipsLumaBefore)
        #expect(cheekAfterLipstick == cheekBefore)

        // Brows: darker; lips untouched.
        let browed = try Self.runNode(
            node, context: context, request: Self.request(MakeupSliders(brows: 100)))
        let browsBefore = MakeupReference.mean(f.pixels, where: f.browsCore, luma)
        let browsAfter = MakeupReference.mean(browed, where: f.browsCore, luma)
        let lipsAfterBrows = MakeupReference.mean(browed, where: f.lipsCore, luma)
        #expect(browsAfter < browsBefore * 0.8)
        #expect(lipsAfterBrows == lipsLumaBefore)

        // Blush: cheeks pinker at (nearly) the same luma.
        let blushed = try Self.runNode(
            node, context: context, request: Self.request(MakeupSliders(blush: 100)))
        let cheekAfter = MakeupReference.mean(blushed, where: f.cheekProbe, luma)
        let redMinusGreen = { (c: SIMD3<Double>) in c.x - c.y }
        let pinkBefore = MakeupReference.mean(f.pixels, where: f.cheekProbe, redMinusGreen)
        let pinkAfter = MakeupReference.mean(blushed, where: f.cheekProbe, redMinusGreen)
        print("P5 makeup blush cheek luma \(cheekBefore) → \(cheekAfter), R−G \(pinkBefore) → \(pinkAfter)")
        #expect(abs(cheekAfter - cheekBefore) < 0.01)
        #expect(pinkAfter > pinkBefore + 0.02)
    }

    @Test("Blush stays off pixels the skin mask excludes")
    func blushIsSkinGated() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        var face = Self.fixture.face
        let skin = try #require(face.masks[.skin])
        face.masks[.skin] = RenderMask(
            width: skin.width, height: skin.height,
            values: [UInt8](repeating: 0, count: skin.values.count),
            maskToImage: skin.maskToImage)
        let node = try MakeupRenderNode(context: context)
        let output = try Self.runNode(
            node, context: context, request: Self.request(MakeupSliders(blush: 100), faces: [face]))
        #expect(SpikeTextureIO.maxAbsoluteDifference(Self.fixture.pixels, output) == 0)
    }

    @Test("A face without lips / brows masks makes those sliders inactive, not a crash")
    func missingMasks() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = Self.enter()
        defer { flags.leave { RPEngineFeatureFlags.makeupSliders = false } }
        var face = Self.fixture.face
        face.masks[.lips] = nil
        face.masks[.brows] = nil
        let node = try MakeupRenderNode(context: context)
        let lipsAndBrows = Self.request(MakeupSliders(lipstick: 100, brows: 100), faces: [face])
        let withBlush = Self.request(MakeupSliders(lipstick: 100, blush: 50), faces: [face])
        #expect(!node.isActive(for: lipsAndBrows))
        // Blush still reaches: mesh + skin are there.
        #expect(node.isActive(for: withBlush))
        let output = try Self.runNode(
            node, context: context,
            request: Self.request(MakeupSliders(lipstick: 100, blush: 50), faces: [face]))
        // Lips are not coloured. Compare only the lip-core pixels no blush lobe
        // reaches, so the check is about the absent lips mask and not about
        // where the cheek lobes happen to end.
        let lobes = BlushMask.lobes(faces: [face])
        var probe = Self.fixture.lipsCore
        for i in probe.indices where probe[i] {
            let p = CGPoint(
                x: Double(i % Self.fixture.width) + 0.5, y: Double(i / Self.fixture.width) + 0.5)
            if ContourMask.value(at: p, lobes: lobes) != 0 { probe[i] = false }
        }
        let red = { (c: SIMD3<Double>) in c.x }
        let before = MakeupReference.mean(Self.fixture.pixels, where: probe, red)
        let after = MakeupReference.mean(output, where: probe, red)
        #expect(probe.contains(true))
        #expect(after == before)
    }
}
