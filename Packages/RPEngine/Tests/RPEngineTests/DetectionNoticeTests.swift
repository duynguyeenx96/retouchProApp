import CoreGraphics
import Foundation
import Metal
import RPCore
import Testing

@testable import RPEngine

/// "Detection failed, tell the user" — the engine half.
///
/// The product rule is one sentence: **a feature that depends on detection must
/// say so when the detection finds nothing, instead of silently doing nothing.**
/// The mechanism is `RenderNode.detectionNotice(for:)` + `RenderReport.notices`,
/// and what has to be true of it is:
///
/// 1. the default is silence, so adding the method changed no existing node;
/// 2. a notice reaches `RenderReport` **even from a node the graph skipped** —
///    which is the whole difficulty, because "detection found nothing" is
///    usually the very reason `isActive(for:)` said no;
/// 3. the two implemented nodes fire on the real failure and stay quiet
///    otherwise, in particular with their feature flag off.
///
/// `.serialized` because `RPEngineFeatureFlags` is process-global (ADR-0006).
@Suite("Detection notices", .serialized)
struct DetectionNoticeTests {

    // MARK: - Stubs

    /// A node that reports whatever it is told to, active or not, and copies its
    /// input so the graph can actually run it.
    private final class StubNode: RenderNode, @unchecked Sendable {
        let name: String
        let stage: RenderStage
        let context: MetalContext
        let active: Bool
        let notice: String?

        init(
            name: String, stage: RenderStage, context: MetalContext, active: Bool = true,
            notice: String? = nil
        ) {
            self.name = name
            self.stage = stage
            self.context = context
            self.active = active
            self.notice = notice
        }

        func isActive(for request: RenderRequest) -> Bool { active }
        func prewarm() throws {}
        func detectionNotice(for request: RenderRequest) -> String? { notice }
        func encode(
            into commandBuffer: any MTLCommandBuffer, source: any MTLTexture,
            destination: any MTLTexture, request: RenderRequest
        ) throws {
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
        }
    }

    /// The same, minus the method: it takes the protocol extension's default and
    /// is therefore a stand-in for every node that existed before this feature.
    private final class SilentNode: RenderNode, @unchecked Sendable {
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
            try RenderGraph.encodeCopy(
                into: commandBuffer, context: context, source: source, destination: destination)
        }
    }

    // MARK: - The graph

    @Test("A node's notice reaches RenderReport; a silent node adds no key")
    func noticesReachTheReport() throws {
        guard let context = SpikeS3Support.context else { return }
        let graph = RenderGraph(
            context: context,
            nodes: [
                StubNode(name: "loud", stage: .color, context: context, notice: "không thấy gì."),
                SilentNode(name: "quiet", stage: .skin, context: context),
            ])
        let width = 16, height = 12
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 3)
        let (_, report) = try graph.renderPixels(
            pixels, width: width, height: height, request: RenderRequest())

        #expect(report.nodes == ["loud", "quiet"])
        #expect(report.notices == ["loud": "không thấy gì."])
        #expect(report.notices["quiet"] == nil, "the default implementation reported something")
        graph.releaseIntermediates()
    }

    /// **The property the whole design turns on.** A node that answers `false` to
    /// `isActive(for:)` — because its detection found nothing, which is exactly
    /// how `WarpRenderNode` behaves for a "Đầu" edit with no traceable hairline —
    /// must still be able to tell the user why. Collecting notices from the
    /// *active* nodes only would silently drop every case that matters.
    @Test("An inactive node can still report a notice")
    func inactiveNodesStillReport() throws {
        guard let context = SpikeS3Support.context else { return }
        let graph = RenderGraph(
            context: context,
            nodes: [
                StubNode(
                    name: "asleep", stage: .warp, context: context, active: false,
                    notice: "không phát hiện được gì.")
            ])
        let width = 8, height = 8
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 5)
        let (_, report) = try graph.renderPixels(
            pixels, width: width, height: height, request: RenderRequest())

        #expect(report.isPassthrough, "the node must not have run")
        #expect(report.notices == ["asleep": "không phát hiện được gì."])
        // …and the cheap query answers the same thing without a render.
        #expect(graph.detectionNotices(for: RenderRequest()) == report.notices)
    }

    @Test("An empty graph reports no notices")
    func emptyGraphIsQuiet() throws {
        guard let context = SpikeS3Support.context else { return }
        let graph = RenderGraph(context: context, nodes: [])
        #expect(graph.detectionNotices(for: RenderRequest()).isEmpty)
        #expect(RenderReport().notices.isEmpty)
    }

    // MARK: - SkinRenderNode ("Sửa da")

    /// The threshold, without a GPU: what counts as "the classifier found
    /// nothing" and what does not.
    @Test("Coverage below a thousandth of the frame counts as nothing found")
    func theCoverageThresholdIsAFloorJustAboveZero() {
        let count = 320 * 213
        func mask(covered: Int) -> RenderMask {
            var values = [UInt8](repeating: 0, count: count)
            for i in 0..<covered { values[i] = 255 }
            return RenderMask(width: 320, height: 213, values: values, maskToImage: .identity)
        }
        // The measured failure (ADR-0021 §5, tone VI): nothing at all.
        #expect(!SkinRenderNode.isUsableBodyCoverage(mask(covered: 0)))
        // A handful of stray samples is still "nothing found".
        #expect(!SkinRenderNode.isUsableBodyCoverage(mask(covered: 20)))
        // A working portrait is 0.05–0.35 of the frame.
        #expect(SkinRenderNode.isUsableBodyCoverage(mask(covered: count / 20)))
        // And the boundary itself is where the constant says it is.
        let floor = Int((Double(count) * SkinRenderNode.minimumBodySkinCoverage).rounded())
        #expect(!SkinRenderNode.isUsableBodyCoverage(mask(covered: floor)))
        #expect(SkinRenderNode.isUsableBodyCoverage(mask(covered: floor + 2)))
    }

    @Test("Skin: flag on and zero body coverage says so; real coverage does not")
    func skinNoticeFollowsTheCoverage() throws {
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

        var empty = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        empty.bodySkinMask = BodySkinUnionTests.fullFrameMask(value: 0)
        #expect(node.detectionNotice(for: empty) == SkinRenderNode.noSkinNotice)
        #expect(node.detectionNotice(for: empty) == "Không phát hiện được da.")

        var covered = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        covered.bodySkinMask = BodySkinUnionTests.fullFrameMask()
        #expect(node.detectionNotice(for: covered) == nil)

        // The notice does not depend on the sliders: the user must be told why
        // the group cannot work *before* dragging something that will do
        // nothing. (That is the difference from the "Đầu" group below, whose
        // sliders have to be asking for something first.)
        var untouched = SkinRenderNodeTests.request(SkinSliders())
        untouched.bodySkinMask = BodySkinUnionTests.fullFrameMask(value: 0)
        #expect(!node.isActive(for: untouched))
        #expect(node.detectionNotice(for: untouched) == SkinRenderNode.noSkinNotice)

        // No mask is "not computed" (the flag was off when the shot opened, the
        // classifier threw, or the shot is still opening) — not "found nothing".
        let none = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        #expect(none.bodySkinMask == nil)
        #expect(node.detectionNotice(for: none) == nil)

        // Repeats are memoised, and the memo is per mask: alternating between
        // two different masks must not serve the first one's verdict.
        for _ in 0..<50 {
            #expect(node.detectionNotice(for: empty) == SkinRenderNode.noSkinNotice)
            #expect(node.detectionNotice(for: covered) == nil)
        }
        node.releaseIntermediates()
        #expect(node.detectionNotice(for: empty) == SkinRenderNode.noSkinNotice)
    }

    /// With `bodySkinSync` off — the shipping default — there is no whole-body
    /// detection to have failed, so a zero mask that somehow reached the request
    /// must produce nothing. Otherwise every shipping build would carry a
    /// permanent "Không phát hiện được da." under the Da sliders.
    @Test("Skin: with bodySkinSync off there is no notice, even at zero coverage")
    func skinNoticeIsSilentWithTheFlagOff() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterSkinRenderGraph()
        defer { flags.leave() }
        #expect(RPEngineFeatureFlags.bodySkinSync == false)

        let node = try SkinRenderNode(context: context)
        var request = SkinRenderNodeTests.request(SkinRenderNodeTests.allSliders)
        request.bodySkinMask = BodySkinUnionTests.fullFrameMask(value: 0)
        #expect(node.detectionNotice(for: request) == nil)

        // …and through the graph, which is how the UI sees it.
        let graph = try RenderGraph.standard(context: context)
        let (_, report) = try graph.renderPixels(
            SkinRenderNodeTests.source, width: SkinRenderNodeTests.width,
            height: SkinRenderNodeTests.height, request: request)
        #expect(report.notices.isEmpty)
    }

    // MARK: - WarpRenderNode ("Đầu")

    /// The hat case, in the shape production produces it — the same fixture
    /// `HeadReshapeRenderTests.aHeadOnlyEditWithoutAUsableSilhouetteIsInactive`
    /// uses (a `.hair` mask that is present, correctly placed, and entirely below
    /// `HairBoundary.coverageThreshold`), asserting the notice rather than the
    /// activation. Those two assertions are the same fact seen from both sides:
    /// the node correctly refuses to run, and the user is correctly told why.
    @Test("Head: an unusable hair silhouette says so; a real one does not")
    func headNoticeFollowsTheSilhouette() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let node = try WarpRenderNode(context: context)
        let head = SyntheticHead.make()
        let sliders = HeadReshapeRenderTests.allHead

        // A traceable hairline: nothing to report.
        let good = SyntheticHead.request(sliders, faces: [head.face])
        #expect(node.isActive(for: good))
        #expect(node.detectionNotice(for: good) == nil)

        // A hat / a shaved head / a parsing miss.
        var hatted = SyntheticHead.make()
        let real = try #require(hatted.face.masks[.hair])
        hatted.face.masks[.hair] = RenderMask(
            width: real.width, height: real.height,
            values: [UInt8](
                repeating: HairBoundary.coverageThreshold - 1, count: real.values.count),
            maskToImage: real.maskToImage)
        let hattedRequest = SyntheticHead.request(sliders, faces: [hatted.face])
        #expect(!node.isActive(for: hattedRequest))
        #expect(node.detectionNotice(for: hattedRequest) == WarpRenderNode.noHairBoundaryNotice)
        #expect(node.detectionNotice(for: hattedRequest) == "Không phát hiện được viền tóc.")

        // No `.hair` key at all, and no face at all: both are "nothing to act on".
        var bald = SyntheticHead.make()
        bald.face.masks[.hair] = nil
        #expect(
            node.detectionNotice(for: SyntheticHead.request(sliders, faces: [bald.face]))
                == WarpRenderNode.noHairBoundaryNotice)
        #expect(
            node.detectionNotice(for: SyntheticHead.request(sliders, faces: []))
                == WarpRenderNode.noHairBoundaryNotice)

        // Asking costs no extra trace: it is the same memoised silhouette
        // `isActive` looked at.
        let before = node.debugTraceCount
        for _ in 0..<20 { _ = node.detectionNotice(for: hattedRequest) }
        #expect(node.debugTraceCount == before, "detectionNotice re-traced the mask")
    }

    /// Two silences that are not failures: the sliders at 0 (nothing was asked
    /// for) and a "Mặt"-only edit (the face group needs no hairline at all).
    @Test("Head: sliders at 0 and a Mặt-only edit are quiet")
    func headNoticeNeedsTheSlidersToBeAsking() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let node = try WarpRenderNode(context: context)
        var hatted = SyntheticHead.make()
        let real = try #require(hatted.face.masks[.hair])
        hatted.face.masks[.hair] = RenderMask(
            width: real.width, height: real.height,
            values: [UInt8](
                repeating: HairBoundary.coverageThreshold - 1, count: real.values.count),
            maskToImage: real.maskToImage)

        #expect(
            node.detectionNotice(for: SyntheticHead.request(HeadSliders(), faces: [hatted.face]))
                == nil)
        #expect(
            node.detectionNotice(
                for: SyntheticHead.request(
                    HeadSliders(), face: FaceSliders(slim: 50), faces: [hatted.face])) == nil)
    }

    /// The same failure on a **real a6300 frame**, driven through the product
    /// path the panel reads (2026-09-21, docs/ADR-0022 §UI).
    ///
    /// ``headNoticeFollowsTheSilhouette`` above pins the node's own answer on a
    /// synthetic head; this is the end-to-end statement the wired panel needs,
    /// and it is the head group's counterpart to
    /// `BodySkinSyncTests.deepToneFramePublishesTheNotice`: a real parsing
    /// output, through `RenderGraph.standard`, to the `RenderReport.notices`
    /// dictionary `LivePreviewController` publishes and
    /// `RPUI.GroupAvailability` turns into the sentence on screen.
    ///
    /// **The failing mask is a real parse, not a buffer written by this test.**
    /// BiSeNet keeps `hat` as class 18, separate from `hair` (17), and
    /// `FaceParsingGroup.hair` does not fold it in — so a subject in a hat gets
    /// a `.hair` mask that is present, correctly sized and correctly placed, and
    /// empty. None of the eleven a6300 subjects is wearing one, which is exactly
    /// what makes their class-18 plane the right fixture: it is this model's own
    /// output for a class it found nothing of, on a real photograph, with the
    /// real derotated affine attached. The frame's real class-17 plane is the
    /// **control** — same code, same graph, same sliders, no notice — so a green
    /// assertion below cannot be "the notice is always on".
    @Test("Head: a real frame whose hair class is empty publishes the notice through the graph")
    func aRealFrameWithNoHairPublishesTheNoticeThroughTheGraph() throws {
        guard let context = SpikeS3Support.context else { return }
        guard let frame = HairMaskFixtures.a6300.first else { return }

        let flags = RPEngineTestFlags.enterHeadRenderGraph()
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }
        let graph = try RenderGraph.standard(context: context)
        let sliders = HeadReshapeRenderTests.allHead

        // The control: the frame's real hair mask, which really is traceable.
        let real = HairMaskFixtures.renderInput(frame)
        #expect(real.masks[.hair]?.values.contains(255) == true)
        #expect(graph.detectionNotices(for: SyntheticHead.request(sliders, faces: [real])).isEmpty)

        // The same frame, the same 512² plane and the same affine — read out of
        // the class the model would have filled for a hat.
        var hatted = real
        var hatMask = frame.mask
        hatMask.values = frame.labels.map { $0 == 18 ? 255 : 0 }
        hatted.masks[.hair] = hatMask
        #expect(hatMask.width == frame.mask.width && hatMask.height == frame.mask.height)
        #expect(hatMask.maskToImage == frame.mask.maskToImage)
        // The premise, measured rather than assumed: nothing in this plane
        // reaches the half-coverage isoline the trace binarises at.
        #expect(!hatMask.values.contains { $0 >= HairBoundary.coverageThreshold })

        #expect(
            graph.detectionNotices(for: SyntheticHead.request(sliders, faces: [hatted]))
                == ["warp": "Không phát hiện được viền tóc."])

        // …and with the head sliders back at 0 nothing was asked for, so the
        // same unusable frame says nothing — the notice is about the user's
        // request, not a standing complaint about the photo.
        #expect(
            graph.detectionNotices(for: SyntheticHead.request(HeadSliders(), faces: [hatted]))
                .isEmpty)
    }

    /// The shipping default this UI round did **not** change (docs/ADR-0022
    /// §UI): the panel exists, the effect stays off until there is an iPhone
    /// number. Under the flag lock, so it reads the default rather than another
    /// suite's mid-test value.
    @Test("Head: headSliders is off by default")
    func headSlidersIsOffByDefault() {
        RPEngineTestFlags.exclusive {
            #expect(RPEngineFeatureFlags.headSliders == false)
        }
    }

    /// With `headSliders` off the user cannot have asked for the thing that
    /// failed, so there is nothing to report — the same rule as the skin node's
    /// flag check, and the reason neither notice can appear in a build that does
    /// not ship the feature.
    @Test("Head: with headSliders off there is no notice")
    func headNoticeIsSilentWithTheFlagOff() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter {
            RPEngineFeatureFlags.enableWarpRenderGraph()
            RPEngineFeatureFlags.headSliders = false
        }
        defer { flags.leave { RPEngineTestFlags.disableHeadAndWarp() } }

        let node = try WarpRenderNode(context: context)
        var bald = SyntheticHead.make()
        bald.face.masks[.hair] = nil
        let request = SyntheticHead.request(
            HeadReshapeRenderTests.allHead, faces: [bald.face])
        #expect(node.detectionNotice(for: request) == nil)

        // Through the graph too: a "Mặt" edit renders and reports nothing.
        let graph = try RenderGraph.standard(context: context)
        #expect(graph.detectionNotices(for: request).isEmpty)
    }
}
