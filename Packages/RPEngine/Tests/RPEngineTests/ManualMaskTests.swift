import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// Phase 6.1 — the hand-painted mask ("Cọ mask thủ công", docs/PLAN.md §6.1).
///
/// Four things have to hold, and each has its own test rather than being folded
/// into one end-to-end check, so a failure says *where*:
///
/// 1. **The splat is the shape it claims to be** — `rp_manual_mask_splat`
///    against ``ManualMaskSplatReference``, a `Double` CPU implementation written
///    from the specification (soft disc, plateau at `hardness x radius`,
///    smoothstep to 0 at `radius`), the same arrangement `SkinReference` uses
///    for the "Da" group.
/// 2. **A live drag and a replay agree bit for bit.** This is not a nicety: undo
///    is defined as "replay the stroke list from the start" (docs/PLAN.md §6.1),
///    so if incremental stamping drifted from a replay, every undo would change
///    pixels the user did not undo.
/// 3. **The PNG round-trips exactly**, because the PNG *is* the document.
/// 4. **The gate is a narrowing and nothing else**: `SkinRenderNode` with no
///    manual mask is bit-identical to its pre-6.1 self, and with one it is
///    bit-identical to the source wherever the brush did not paint.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Phase 6.1 manual mask", .serialized)
struct ManualMaskTests {
    static let width = 160
    static let height = 120

    /// Runs `body` with `manualMask` on, and puts it back. Targeted restore, not
    /// `resetToDefaults()` — see `RPEngineTestFlags`.
    static func withManualMask<T>(_ body: () throws -> T) rethrows -> T {
        try RPEngineTestFlags.exclusive {
            RPEngineFeatureFlags.manualMask = true
            defer { RPEngineFeatureFlags.manualMask = false }
            return try body()
        }
    }

    /// Both flags: the brush plus the group it gates.
    static func withManualMaskAndSkin<T>(_ body: () throws -> T) rethrows -> T {
        try RPEngineTestFlags.exclusive {
            RPEngineFeatureFlags.manualMask = true
            RPEngineFeatureFlags.enableSkinRenderGraph()
            defer {
                RPEngineFeatureFlags.manualMask = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
            return try body()
        }
    }

    // MARK: - Layout

    @Test("Shader parameter structs have the layout ManualMaskShaders.metal declares")
    func parameterStructsMatchShaderLayout() {
        // MSL and Swift agree on all four because both give a 2-component vector
        // 8-byte alignment and a 3-component vector 16: `{uint2, float}` is 12
        // bytes of payload rounded up to a 16-byte stride, not 12.
        //
        // Getting `ManualMaskStamp` wrong is the dangerous one — it is an *array*
        // in the shader, so a stride the CPU and GPU disagree about would make
        // every stamp after the first read a garbage centre. That is why
        // `splatMatchesReference` exists as well: this test pins the number, that
        // one proves the number is the right one (it measured 0.0 max abs
        // difference against the CPU reference).
        #expect(MemoryLayout<ManualMaskClearParams>.stride == 16)  // uint2, float, pad
        #expect(MemoryLayout<ManualMaskStamp>.stride == 16)  // float2, float, pad
        #expect(MemoryLayout<ManualMaskSplatParams>.stride == 24)  // uint2, 2 float, 2 uint
        // uint2, uint2, then two float3 at 16-byte alignment, then a float.
        #expect(MemoryLayout<ManualMaskModulateParams>.stride == 64)
    }

    // MARK: - The flag

    @Test("Both producers refuse to build while the flag is off")
    func flagGatesConstruction() {
        guard let context = SpikeS3Support.context else { return }
        // No `try`: every throwing call in here is inside an `#expect(throws:)`
        // closure, which swallows it.
        RPEngineTestFlags.exclusive {
            RPEngineFeatureFlags.manualMask = false
            #expect(throws: RPEngineFeatureDisabled.self) {
                _ = try ManualMaskCoverage(context: context, width: 8, height: 8)
            }
            #expect(throws: RPEngineFeatureDisabled.self) {
                _ = try ManualMaskSession(context: context, width: 8, height: 8)
            }
            // The *gating* half is deliberately not behind this flag: it is the
            // shared slot "Khoá nền" plugs into under its own `backgroundLock`
            // flag, so requiring `manualMask` here would be the rework
            // docs/ADR-0018 deferred the slot to avoid.
            #expect(throws: Never.self) { _ = try GateMaskCompositor(context: context) }
        }
    }

    @Test("A painted gate stops narrowing the moment its flag goes off")
    func aPaintedGateAnswersToItsOwnFlag() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(context: context, width: 16, height: 16)
            #expect(session.coverage.isGateEnabled)
            RPEngineFeatureFlags.manualMask = false
            #expect(session.coverage.isGateEnabled == false)
            RPEngineFeatureFlags.manualMask = true

            // A gate with no flag of its own is always live — the default a
            // `TextureGateMask` (i.e. a subject mask) takes.
            let texture = try SpikeTextureIO.makeTexture(
                width: 16, height: 16, device: context.device, pixelFormat: .r8Unorm,
                usage: [.shaderRead, .shaderWrite])
            #expect(TextureGateMask(texture: texture).isGateEnabled)
        }
    }

    // MARK: - 1. The splat

    @Test("rp_manual_mask_splat matches a Double reference")
    func splatMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            let stroke = Self.diagonalStroke(radius: 18, hardness: 0.4, flow: 1, mode: .add)
            try Self.draw(stroke, in: session)

            let measured = try session.readValues().map { Double($0) / 255 }
            let reference = ManualMaskSplatReference.rasterise(
                [stroke], width: Self.width, height: Self.height)
            var worst = 0.0
            for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
            print("P6.1 splat vs Double reference: max abs diff = \(worst)")
            // r8Unorm quantises to 1/255 = 3.9e-3; everything above that would be
            // a different falloff, a different radius or a different stamp
            // spacing, all of which move whole pixels.
            #expect(worst < 4.1e-3, "max abs diff \(worst)")

            // …and the stroke is actually somewhere: a kernel that wrote 0
            // everywhere would pass the bound above with room to spare.
            let painted = measured.filter { $0 > 0.5 }.count
            #expect(painted > 200, "only \(painted) painted pixels")
            #expect(painted < measured.count / 2, "\(painted) painted pixels is the whole frame")
        }
    }

    @Test("Subtract rubs coverage back out")
    func subtractRemovesCoverage() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(
                Self.diagonalStroke(radius: 24, hardness: 1, flow: 1, mode: .add), in: session)
            let afterAdd = try session.readValues()

            try Self.draw(
                Self.diagonalStroke(radius: 10, hardness: 1, flow: 1, mode: .subtract),
                in: session)
            let afterSubtract = try session.readValues()

            // Subtract can only lower coverage, never raise it…
            for i in 0..<afterAdd.count {
                #expect(afterSubtract[i] <= afterAdd[i])
            }
            // …and it actually lowered some of it.
            #expect(zip(afterAdd, afterSubtract).contains { $0.0 > $0.1 })
        }
    }

    // MARK: - 2. Replay

    @Test("A live drag is bit-identical to a replay of the same stroke")
    func liveDragMatchesAReplay() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let stroke = Self.diagonalStroke(radius: 15, hardness: 0.5, flow: 0.8, mode: .add)

            // (a) point by point, as a finger delivers them.
            let live = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(stroke, in: live)
            let dragged = try live.readValues()

            // (b) the same stroke rasterised in one batch, as undo's replay does.
            let replayed = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(stroke, in: replayed)
            replayed.undo()
            replayed.redo()
            let afterReplay = try replayed.readValues()

            #expect(dragged == afterReplay)
        }
    }

    @Test("Undo puts back exactly the pixels the previous stroke left")
    func undoRestoresThePreviousMask() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let first = Self.diagonalStroke(radius: 16, hardness: 0.5, flow: 1, mode: .add)
            let second = Self.horizontalStroke(radius: 12, hardness: 0.8, flow: 1, mode: .add)

            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(first, in: session)
            let afterFirst = try session.readValues()

            try Self.draw(second, in: session)
            let afterSecond = try session.readValues()
            #expect(afterSecond != afterFirst)

            #expect(session.undo())
            #expect(try session.readValues() == afterFirst)
            #expect(session.canRedo)
            #expect(session.redo())
            #expect(try session.readValues() == afterSecond)

            // …and undoing past the start is a no-op, not a crash.
            #expect(session.undo())
            #expect(session.undo())
            #expect(session.undo() == false)
            #expect(try session.readValues().allSatisfy { $0 == 0 })
        }
    }

    @Test("A new stroke drops the redo stack")
    func aNewStrokeDropsRedo() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(Self.diagonalStroke(radius: 10), in: session)
            #expect(session.undo())
            #expect(session.canRedo)
            try Self.draw(Self.horizontalStroke(radius: 10), in: session)
            #expect(session.canRedo == false)
            #expect(session.strokeCount == 1)
        }
    }

    // MARK: - 3. Storage

    @Test("The PNG round-trips the coverage byte for byte")
    func pngRoundTripIsExact() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(
                Self.diagonalStroke(radius: 20, hardness: 0.3, flow: 0.7), in: session)
            let painted = try session.readValues()
            let png = try session.pngData()

            let reopened = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try reopened.load(pngData: png)
            #expect(try reopened.readValues() == painted)
            // A loaded mask has no stroke history — there is nothing behind it to
            // undo to — but it is not "empty" either.
            #expect(reopened.canUndo == false)
            #expect(reopened.isEmpty == false)
        }
    }

    @Test("A mask of the wrong size is refused rather than stretched")
    func loadingAWrongSizedMaskThrows() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let small = try ManualMaskSession(context: context, width: 32, height: 24)
            let png = try small.pngData()
            let large = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            #expect(throws: ManualMaskError.self) { try large.load(pngData: png) }
        }
    }

    @Test("Clear takes the mask back to nothing painted")
    func clearAllEmptiesTheMask() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(Self.diagonalStroke(radius: 20), in: session)
            session.clearAll()
            #expect(try session.readValues().allSatisfy { $0 == 0 })
            #expect(session.isEmpty)
            #expect(session.canUndo == false)
        }
    }

    // MARK: - 4. The gate

    @Test("rp_manual_mask_modulate is coverage x mask")
    func modulateMultipliesCoverage() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMask {
            let session = try ManualMaskSession(
                context: context, width: Self.width, height: Self.height)
            try Self.draw(Self.diagonalStroke(radius: 22, hardness: 0.4), in: session)
            let painted = try session.readValues().map { Double($0) / 255 }

            // A coverage texture with a known non-constant value, so a kernel
            // that returned its input unchanged would be caught.
            var base = [UInt8](repeating: 0, count: Self.width * Self.height)
            for y in 0..<Self.height {
                for x in 0..<Self.width {
                    base[y * Self.width + x] = UInt8(min(255, x * 255 / max(1, Self.width - 1)))
                }
            }
            let coverage = try Self.makeR8(base, context: context)
            let destination = try SpikeTextureIO.makeTexture(
                width: Self.width, height: Self.height, device: context.device,
                pixelFormat: .r8Unorm, usage: [.shaderRead, .shaderWrite])

            let compositor = try GateMaskCompositor(context: context)
            guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
            compositor.encode(
                into: commandBuffer, coverage: coverage, gate: session.coverage,
                destination: destination)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            let measured = try SkinRenderNodeTests.readR8(
                destination, queue: context.commandQueue)
            var worst = 0.0
            for i in 0..<measured.count {
                let expected = Double(base[i]) / 255 * painted[i]
                worst = max(worst, abs(expected - measured[i]))
            }
            print("P6.1 modulate vs Double reference: max abs diff = \(worst)")
            // One r8 quantisation on the way out, plus the bilinear tap on a
            // mask that is here at 1:1 (so the tap is exact).
            #expect(worst < 4.1e-3, "max abs diff \(worst)")
        }
    }

    /// The shared-slot claim, exercised: a plain coverage texture — which is
    /// exactly what `BackgroundLockMaskSource.encode(…)` returns — goes through
    /// the same gate as the brush with no new code, and two gates intersect.
    ///
    /// This is what "Khoá nền could plug in later without rework" means in
    /// practice (docs/ADR-0018 stopped at the mask; docs/ADR-0019 §"one slot").
    @Test("Two gate masks intersect, and a plain texture is a gate")
    func gateMasksIntersect() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMaskAndSkin {
            let node = try SkinRenderNode(context: context)
            let sliders = SkinRenderNodeTests.allSliders
            let width = SkinRenderNodeTests.width
            let height = SkinRenderNodeTests.height

            // Gate A: the painted brush, a disc left of centre.
            let session = try ManualMaskSession(context: context, width: width, height: height)
            // Straddling the midline on purpose, so gate B has something to cut.
            session.beginStroke(
                radius: 40, hardness: 0.95, flow: 1, mode: .add,
                at: BrushPoint(location: CGPoint(x: Double(width) * 0.5, y: Double(height) * 0.5)))
            session.endStroke()
            let brush = try session.readValues()

            // Gate B: a whole-frame texture that is 1 on the left half and 0 on
            // the right — the shape a subject mask has, built by hand so the test
            // needs no Vision request.
            var half = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<(width / 2) { half[y * width + x] = 255 }
            }
            let halfTexture = try Self.makeR8(half, context: context, width: width, height: height)
            let subject = TextureGateMask(texture: halfTexture)
            #expect(subject.gateWidth == width)
            #expect(subject.gateMaskToImage == .identity)

            let source = SkinRenderNodeTests.source
            func changedPixels(_ gates: [any RenderGateMask]) throws -> Set<Int> {
                var request = SkinRenderNodeTests.request(sliders)
                request.gateMasks = gates
                let out = try SkinRenderNodeTests.runNode(node, context: context, request: request)
                var changed = Set<Int>()
                for pixel in 0..<(width * height) {
                    for channel in 0..<3
                    where abs(out[pixel * 4 + channel] - source[pixel * 4 + channel]) > 1e-4 {
                        changed.insert(pixel)
                        break
                    }
                }
                return changed
            }

            let brushOnly = try changedPixels([session.coverage])
            let subjectOnly = try changedPixels([subject])
            let both = try changedPixels([session.coverage, subject])
            print(
                "P6.1 gate composition: brush \(brushOnly.count), subject \(subjectOnly.count), "
                    + "intersection \(both.count)")

            #expect(!brushOnly.isEmpty)
            #expect(!subjectOnly.isEmpty)
            // The product of two coverages can only be narrower than either.
            #expect(both.isSubset(of: brushOnly))
            #expect(both.isSubset(of: subjectOnly))
            // Nothing in the right half survives gate B, brush or no brush…
            #expect(both.allSatisfy { $0 % width < width / 2 })
            // …and the brush's own right-hand lobe *did* reach there before B was
            // added, so the check above is testing something.
            #expect(brushOnly.contains { $0 % width >= width / 2 })
            #expect(!both.isEmpty)
            // Where the brush painted nothing, no gate combination may act.
            #expect(both.allSatisfy { brush[$0] > 0 })
        }
    }

    @Test("With no manual mask the skin node is bit-identical to its pre-6.1 self")
    func noManualMaskChangesNothing() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMaskAndSkin {
            let node = try SkinRenderNode(context: context)
            let request = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
            #expect(request.gateMasks.isEmpty)
            let ungated = try SkinRenderNodeTests.runNode(
                node, context: context, request: request)

            // The control: the same node, the same request, with the feature
            // flag off entirely.
            RPEngineFeatureFlags.manualMask = false
            let control = try SkinRenderNodeTests.runNode(
                node, context: context, request: request)
            RPEngineFeatureFlags.manualMask = true
            #expect(SpikeTextureIO.maxAbsoluteDifference(ungated, control) == 0)
        }
    }

    @Test("A manual mask narrows the skin node to the painted region")
    func manualMaskNarrowsTheSkinNode() throws {
        guard let context = SpikeS3Support.context else { return }
        try Self.withManualMaskAndSkin {
            let node = try SkinRenderNode(context: context)
            let sliders = SkinRenderNodeTests.allSliders
            let ungated = try SkinRenderNodeTests.runNode(
                node, context: context, request: SkinRenderNodeTests.request(sliders))

            // Paint a disc over the middle of the face, at the *image* size, so
            // mask pixels and image pixels are the same pixels.
            let session = try ManualMaskSession(
                context: context, width: SkinRenderNodeTests.width,
                height: SkinRenderNodeTests.height)
            let centre = CGPoint(
                x: Double(SkinRenderNodeTests.width) * 0.45,
                y: Double(SkinRenderNodeTests.height) * 0.5)
            session.beginStroke(
                radius: 28, hardness: 0.9, flow: 1, mode: .add,
                at: BrushPoint(location: centre))
            session.endStroke()
            let manual = try session.readValues()

            var request = SkinRenderNodeTests.request(sliders)
            request.gateMasks = [session.coverage]
            let gated = try SkinRenderNodeTests.runNode(
                node, context: context, request: request)

            let source = SkinRenderNodeTests.source
            var changedInside = 0
            var changedOutside = 0
            for pixel in 0..<manual.count {
                var difference: Float = 0
                for channel in 0..<3 {
                    difference = max(
                        difference, abs(gated[pixel * 4 + channel] - source[pixel * 4 + channel]))
                }
                if manual[pixel] == 0 {
                    // Unpainted: the node must not have touched this pixel at
                    // all. Bit-exact, not "close" — the composite mixes by the
                    // mask, so a zero mask is an exact identity.
                    if difference != 0 { changedOutside += 1 }
                } else if difference > 1e-4 {
                    changedInside += 1
                }
            }
            print(
                "P6.1 gate: \(changedInside) pixels changed inside the brush, "
                    + "\(changedOutside) outside")
            #expect(changedOutside == 0, "\(changedOutside) unpainted pixels changed")
            #expect(changedInside > 100, "only \(changedInside) painted pixels changed")

            // And the gate is a narrowing of the *same* edit: inside the brush
            // the gated render must be the ungated one, not something new.
            var worstInside: Float = 0
            for pixel in 0..<manual.count where manual[pixel] == 255 {
                for channel in 0..<3 {
                    worstInside = max(
                        worstInside, abs(gated[pixel * 4 + channel] - ungated[pixel * 4 + channel]))
                }
            }
            #expect(worstInside < 2e-3, "fully painted pixels differ by \(worstInside)")

            // …and switching the flag off with the *same* request still in hand
            // puts the node back to its pre-6.1 output, bit for bit. This is the
            // guarantee `noManualMaskChangesNothing` cannot make, because there
            // the request carried no mask to ignore in the first place.
            RPEngineFeatureFlags.manualMask = false
            let switchedOff = try SkinRenderNodeTests.runNode(
                node, context: context, request: request)
            RPEngineFeatureFlags.manualMask = true
            #expect(SpikeTextureIO.maxAbsoluteDifference(switchedOff, ungated) == 0)
        }
    }

    // MARK: - Fixtures

    /// A stroke across the frame, as a finger would deliver it: points ~3 px
    /// apart with a pressure ramp.
    static func diagonalStroke(
        radius: Double, hardness: Double = 0.5, flow: Double = 1, mode: BrushMode = .add
    ) -> BrushStroke {
        var stroke = BrushStroke(radius: radius, hardness: hardness, flow: flow, mode: mode)
        for step in 0...40 {
            let t = Double(step) / 40
            stroke.points.append(
                BrushPoint(
                    location: CGPoint(
                        x: 24 + t * Double(width - 48), y: 20 + t * Double(height - 40)),
                    pressure: 0.4 + 0.6 * t))
        }
        return stroke
    }

    static func horizontalStroke(
        radius: Double, hardness: Double = 0.5, flow: Double = 1, mode: BrushMode = .add
    ) -> BrushStroke {
        var stroke = BrushStroke(radius: radius, hardness: hardness, flow: flow, mode: mode)
        for step in 0...30 {
            let t = Double(step) / 30
            stroke.points.append(
                BrushPoint(
                    location: CGPoint(x: 16 + t * Double(width - 32), y: Double(height) * 0.7),
                    pressure: 1))
        }
        return stroke
    }

    /// Feeds a stroke to a session the way a finger does — begin, many extends,
    /// end — so every test exercises the incremental path and not a batch one.
    static func draw(_ stroke: BrushStroke, in session: ManualMaskSession) throws {
        guard let first = stroke.points.first else { return }
        session.beginStroke(
            radius: stroke.radius, hardness: stroke.hardness, flow: stroke.flow,
            mode: stroke.mode, at: first)
        for point in stroke.points.dropFirst() { session.extendStroke(to: point) }
        session.endStroke()
    }

    static func makeR8(
        _ values: [UInt8], context: MetalContext, width: Int = width, height: Int = height
    ) throws -> any MTLTexture {
        let texture = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .r8Unorm,
            usage: [.shaderRead, .shaderWrite])
        guard
            let staging = values.withUnsafeBytes({
                context.device.makeBuffer(
                    bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }),
            let commandBuffer = context.commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: width,
            sourceBytesPerImage: width * height,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }
}

/// The `Double` CPU control for `rp_manual_mask_splat`.
///
/// Written from docs/PLAN.md §6.1's description of the brush — *"splat tròn mềm,
/// falloff … add/subtract là cờ blend-mode"* — and from the stamp spacing
/// `BrushStroke` documents, **not** from the shader. That is the point: a
/// reference transcribed from the kernel it is checking proves only that the
/// transcription was faithful.
enum ManualMaskSplatReference {

    static func rasterise(_ strokes: [BrushStroke], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for stroke in strokes {
            let stamps = stroke.stamps
            let plateau = min(0.999, max(0, stroke.hardness))
            let flow = min(1, max(0, stroke.flow))
            for y in 0..<height {
                for x in 0..<width {
                    let qx = Double(x) + 0.5
                    let qy = Double(y) + 0.5
                    var coverage = 0.0
                    for stamp in stamps {
                        let radius = max(stamp.radius, 1e-4)
                        let dx = qx - Double(stamp.center.x)
                        let dy = qy - Double(stamp.center.y)
                        let distance = (dx * dx + dy * dy).squareRoot()
                        guard distance < radius else { continue }
                        coverage = max(
                            coverage, 1 - smoothstep(plateau, 1, distance / radius))
                        if coverage >= 1 { break }
                    }
                    coverage *= flow
                    guard coverage > 0 else { continue }
                    let index = y * width + x
                    out[index] =
                        stroke.mode.isSubtract
                        ? min(out[index], 1 - coverage) : max(out[index], coverage)
                }
            }
            // Quantise between strokes, as the r8Unorm texture does.
            for index in out.indices { out[index] = (out[index] * 255).rounded() / 255 }
        }
        return out
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
