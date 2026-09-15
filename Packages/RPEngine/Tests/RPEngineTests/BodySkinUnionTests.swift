import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// docs/PLAN.md §6.2 "Sửa da" — the whole-body skin sync, as seen by
/// ``SkinRenderNode``.
///
/// The feature adds **no retouch maths**: the eight "Da" sliders and their
/// kernel (`rp_skin_composite`, 79.0 dB in docs/ADR-0009) are untouched, and the
/// only thing that changes is the coverage texture bound at index 3. So what
/// there is to test is not "does it look right" but four structural claims:
///
/// 1. **Flag off is bit-exact.** A request carrying a `bodySkinMask` while
///    `RPEngineFeatureFlags.bodySkinSync` is off renders the *same bytes* as one
///    carrying none. Without this the flag is not a flag.
/// 2. **The union widens and never narrows.** `rp_body_skin_union` is
///    `max(face, body * (1 - authority))`, so the merged coverage is `>=` the
///    per-face coverage at every pixel: switching the feature on can only add
///    area, never take smoothing away from a face that already had it.
/// 3. **The widening reaches outside the parsing crop.** That *is* the feature —
///    neck, shoulders and arms, which BiSeNet never saw.
/// 4. **Widen happens before narrow.** The §6.1 gates (`RenderGateMask`: the
///    hand-painted brush, "Khoá nền") multiply into the coverage *after* the
///    union. This is the load-bearing ordering decision of the merge that
///    brought the two features together, and it is the one an implementation can
///    get backwards without any compiler complaining: gate-then-union would let
///    the whole-frame mask re-add exactly the area the user had just brushed
///    away. Test 4 below fails loudly in that case, and passes for the shipped
///    order.
///
/// See `RenderRequest.bodySkinMask` for why the body mask is *not* a
/// `RenderGateMask` (gates compose by multiplication, which can only ever
/// subtract area) and `RenderGateMask`'s own doc comment, which was corrected to
/// match.
@Suite("Phase 6.2 whole-body skin union", .serialized)
struct BodySkinUnionTests {

    static let width = SkinRenderNodeTests.width
    static let height = SkinRenderNodeTests.height

    /// A whole-frame mask that says "all of this is skin".
    ///
    /// Deliberately saturated rather than a shaped blob: the shaped case is what
    /// ``SkinCoreTests`` and `SkinSyncBenchTests` measure, while what these tests
    /// are about is *where the coverage is allowed to land*, and a mask with
    /// holes in it would make a failed assertion ambiguous between "the union is
    /// wrong" and "the classifier did not fire here".
    static func fullFrameMask(value: UInt8 = 255) -> RenderMask {
        RenderMask(
            width: width, height: height,
            values: [UInt8](repeating: value, count: width * height),
            maskToImage: .identity)
    }

    /// A gate that is open in the top half and shut in the bottom half.
    static func topHalfGate(context: MetalContext) throws -> TextureGateMask {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<(height / 2) {
            for x in 0..<width { bytes[y * width + x] = 255 }
        }
        // Through the brush suite's blit helper, because `SpikeTextureIO`'s
        // textures are `.private` and cannot be written from the host.
        return TextureGateMask(
            texture: try ManualMaskTests.makeR8(
                bytes, context: context, width: width, height: height))
    }

    /// The pixels whose value the node moved away from the source.
    static func touched(_ output: [Float]) -> Set<Int> {
        let source = SkinRenderNodeTests.source
        var out = Set<Int>()
        for pixel in 0..<(width * height) {
            for channel in 0..<3 where output[pixel * 4 + channel] != source[pixel * 4 + channel] {
                out.insert(pixel)
                break
            }
        }
        return out
    }

    // MARK: - Layout

    @Test("Shader parameter structs have the layout BodySkinShaders.metal declares")
    func parameterStructsMatchShaderLayout() {
        #expect(MemoryLayout<BodySkinUnionParams>.stride == 16)  // uint2 + uint, padded
        // float3 aligns to 16 in Metal: 16 + 16 + 8 + 4 -> 44, padded to 48.
        #expect(MemoryLayout<BodySkinUnionTransform>.stride == 48)
    }

    // MARK: - 1. The flag

    @Test("Flag off ignores the whole-frame mask, byte for byte")
    func flagOffIgnoresTheWholeFrameMask() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        // enableSkinRenderGraph() must NOT have turned this on with it: the Da
        // group shipping is not the body sync shipping.
        #expect(RPEngineFeatureFlags.bodySkinSync == false)

        let node = try SkinRenderNode(context: context)
        let sliders = SkinRenderNodeTests.allSliders
        let control = try SkinRenderNodeTests.runNode(
            node, context: context, request: SkinRenderNodeTests.request(sliders))

        var request = SkinRenderNodeTests.request(sliders)
        request.bodySkinMask = Self.fullFrameMask()
        let withMask = try SkinRenderNodeTests.runNode(
            node, context: context, request: request)

        #expect(SpikeTextureIO.maxAbsoluteDifference(control, withMask) == 0)
        #expect(node.debugUnionMask == nil, "the union ran while the flag was off")
    }

    // MARK: - 2 & 3. The union

    @Test("The union is >= the per-face mask everywhere and adds area outside the crop")
    func unionWidensAndNeverNarrows() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }

        let node = try SkinRenderNode(context: context)
        let sliders = SkinRenderNodeTests.allSliders

        let faceOnly = try SkinRenderNodeTests.runNode(
            node, context: context, request: SkinRenderNodeTests.request(sliders))
        let faceCoverage = try SkinRenderNodeTests.readR8(
            #require(node.debugFaceMask), queue: context.commandQueue)

        var request = SkinRenderNodeTests.request(sliders)
        request.bodySkinMask = Self.fullFrameMask()
        let merged = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        let unionTexture = try #require(node.debugUnionMask, "the union did not run")
        let unionCoverage = try SkinRenderNodeTests.readR8(
            unionTexture, queue: context.commandQueue)

        // 2. Never narrows. r8Unorm quantisation is 1/255, and the kernel's max()
        // is exact, so the only slack allowed is a single quantisation step.
        var worstLoss = 0.0
        var added = 0
        for i in 0..<unionCoverage.count {
            worstLoss = max(worstLoss, faceCoverage[i] - unionCoverage[i])
            if unionCoverage[i] > faceCoverage[i] + 1.0 / 255 { added += 1 }
        }
        #expect(worstLoss <= 1.0 / 255, "the union weakened the face mask by \(worstLoss)")
        #expect(added > 0, "the union added nothing")

        // 3. And the added area is a real widening of what the node touches.
        let before = Self.touched(faceOnly)
        let after = Self.touched(merged)
        #expect(before.isSubset(of: after), "the union stopped touching \(before.subtracting(after).count) pixels")
        #expect(
            after.count > before.count,
            "face-only touched \(before.count), merged touched \(after.count)")
        print(
            "P6.2 union: face-only \(before.count) px, merged \(after.count) px of "
                + "\(Self.width * Self.height), coverage added at \(added) px")

        // The point of the feature: the added pixels are *outside* the parsing
        // crop, which is where BiSeNet never had an opinion.
        let face = SkinRenderNodeTests.face
        let mask = try #require(face.masks[.skin])
        let toMask = mask.imageToMask
        var outsideCrop = 0
        for pixel in after.subtracting(before) {
            let p = CGPoint(x: Double(pixel % Self.width) + 0.5, y: Double(pixel / Self.width) + 0.5)
                .applying(toMask)
            if p.x < 0 || p.y < 0 || p.x >= CGFloat(mask.width) || p.y >= CGFloat(mask.height) {
                outsideCrop += 1
            }
        }
        #expect(
            outsideCrop > 0,
            "every pixel the union added was inside the crop; the neck was never reached")
    }

    @Test("With no faces the node stays inactive, whole-frame mask or not")
    func noFaceStillMeansNoWork() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }
        let node = try SkinRenderNode(context: context)
        var request = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders, faces: [])
        request.bodySkinMask = Self.fullFrameMask()
        // "Sync the body to the face" has no meaning without a face: every length
        // in this node is a fraction of face width, and the union's feather is
        // measured at the crop border there is none of.
        #expect(node.isActive(for: request) == false)
        let output = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        #expect(SpikeTextureIO.maxAbsoluteDifference(output, SkinRenderNodeTests.source) == 0)
    }

    // MARK: - 4. Order: widen, then narrow

    @Test("A gate narrows the unioned region — union runs before the gate, not after")
    func gateNarrowsTheUnionedRegion() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }

        let node = try SkinRenderNode(context: context)
        let sliders = SkinRenderNodeTests.allSliders
        let body = Self.fullFrameMask()

        // a) Body mask, no gate: the bottom half is reached.
        var ungated = SkinRenderNodeTests.request(sliders)
        ungated.bodySkinMask = body
        let ungatedTouched = Self.touched(
            try SkinRenderNodeTests.runNode(node, context: context, request: ungated))
        let bottomUngated = ungatedTouched.filter { $0 / Self.width >= Self.height / 2 }
        #expect(
            !bottomUngated.isEmpty,
            "the body mask never reached the bottom half; this test proves nothing")

        // b) Same, plus a gate that is shut over the bottom half.
        var gated = SkinRenderNodeTests.request(sliders)
        gated.bodySkinMask = body
        gated.gateMasks = [try Self.topHalfGate(context: context)]
        let gatedOutput = try SkinRenderNodeTests.runNode(node, context: context, request: gated)
        let gatedTouched = Self.touched(gatedOutput)
        let bottomGated = gatedTouched.filter { $0 / Self.width >= Self.height / 2 }

        // THE assertion. If the node gated the per-face coverage and *then*
        // unioned the whole-frame mask in, `bottomGated` would be as full as
        // `bottomUngated`: the body mask would have re-added every pixel the gate
        // had just shut. A brush that cannot protect a shoulder is not a brush.
        let survived = "\(bottomGated.count) survived, ungated \(bottomUngated.count)"
        #expect(
            bottomGated.isEmpty,
            "the gate was applied before the union: \(survived) in the shut half")

        // …and it is a *narrowing*, not a different edit: what survives in the
        // open half is bit-identical to the ungated render there.
        let ungatedOutput = try SkinRenderNodeTests.runNode(
            node, context: context, request: ungated)
        var worstTopDifference = 0.0
        for pixel in 0..<(Self.width * Self.height / 2) {
            for channel in 0..<4 {
                worstTopDifference = max(
                    worstTopDifference,
                    Double(
                        abs(
                            gatedOutput[pixel * 4 + channel]
                                - ungatedOutput[pixel * 4 + channel])))
            }
        }
        #expect(worstTopDifference == 0, "the gate changed the open half by \(worstTopDifference)")
        print(
            "P6.2 order: ungated bottom half \(bottomUngated.count) px, gated "
                + "\(bottomGated.count) px; open half identical to \(worstTopDifference)")
    }

    @Test("A gate alone still narrows exactly as it did before 6.2 landed")
    func gateWithoutBodyMaskIsUnchanged() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }
        // The flag is on but no mask is supplied — the state a document is in
        // before anyone computes a body mask. Nothing may change.
        let node = try SkinRenderNode(context: context)
        var request = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        request.gateMasks = [try Self.topHalfGate(context: context)]
        let withFlag = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        #expect(node.debugUnionMask == nil)

        RPEngineFeatureFlags.bodySkinSync = false
        let control = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        #expect(SpikeTextureIO.maxAbsoluteDifference(withFlag, control) == 0)
    }

    // MARK: - Resources

    @Test("The union texture is allocated only once a request carries a body mask")
    func unionTextureIsLazy() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableSkinRenderGraph()
            RPEngineFeatureFlags.bodySkinSync = true
        }
        defer {
            flags.leave {
                RPEngineFeatureFlags.bodySkinSync = false
                RPEngineFeatureFlags.disableSkinRenderGraph()
            }
        }
        let node = try SkinRenderNode(context: context)
        _ = try SkinRenderNodeTests.runNode(
            node, context: context, request: SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders))
        let withoutBody = node.allocatedBytes

        var request = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        request.bodySkinMask = Self.fullFrameMask()
        _ = try SkinRenderNodeTests.runNode(node, context: context, request: request)
        let withBody = node.allocatedBytes

        // One r8 frame for the union plus the rasteriser's own output and the
        // uploaded whole-frame mask.
        #expect(withBody > withoutBody)
        node.releaseIntermediates()
        #expect(node.allocatedBytes == 0)
    }
}
