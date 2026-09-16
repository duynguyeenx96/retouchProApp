import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// docs/ADR-0021 §v2 — the canvas half: who asks for a subject mask, when, and
/// how often.
///
/// The engine half (what the multiply does to the pixels) is
/// `RPEngineTests/BodySkinSubjectMaskTests`; the Vision half is
/// `RPVisionTests/PersonSegmenterTests`. What is left, and what this file pins,
/// is the cost model: the segmentation request is 17 ms and the classifier is
/// another 17.8 ms at a 2048 px preview, so both must run **once per shot** and
/// never on the interaction path — the same rule docs/ADR-0013 records for face
/// analysis — and neither may run at all while
/// `RPEngineFeatureFlags.bodySkinSync` is off, which is the shipping default.
///
/// `.serialized` because `RPEngineFeatureFlags` is a process-global store.
@Suite("Phase 6.2 body skin sync wiring", .serialized)
@MainActor
struct BodySkinSyncWiringTests {

    /// Counts the calls and can answer `nil` ("no subject in this frame"), which
    /// is the case the caller must not confuse with an all-zero mask.
    final class CountingSubjectProvider: SubjectMaskProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _qualities: [SubjectMaskQuality] = []
        let mask: RenderMask?

        init(mask: RenderMask?) { self.mask = mask }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }
        var qualities: [SubjectMaskQuality] {
            lock.lock()
            defer { lock.unlock() }
            return _qualities
        }

        func subjectMask(
            for image: PreviewImage, contentHash: String, quality: SubjectMaskQuality
        ) async throws -> RenderMask? {
            record(quality)
            return mask
        }

        private func record(_ quality: SubjectMaskQuality) {
            lock.lock()
            defer { lock.unlock() }
            _calls += 1
            _qualities.append(quality)
        }
    }

    static func withBodySkinSync(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = RPEngineFeatureFlags.bodySkinSync
        RPEngineFeatureFlags.bodySkinSync = on
        defer { RPEngineFeatureFlags.bodySkinSync = previous }
        try await body()
    }

    static func decodedFixture() throws -> (PreviewImage, URL) {
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-bodyskin-\(UUID().uuidString).png"),
            size: 256)
        return (try ImageDecoder.decode(contentsOf: url, maxPixelSize: 2048), url)
    }

    /// The cost model, as an assertion. With the flag off nothing is asked for
    /// and nothing is computed — not "computed and ignored": that would be ~35 ms
    /// per shot of Vision plus CPU classification thrown away on every launch of
    /// the shipping build.
    @Test("With bodySkinSync off, no subject mask is requested and no body mask exists")
    func flagOffCostsNothing() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withBodySkinSync(false) {
            let provider = CountingSubjectProvider(mask: nil)
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "flag-off", editState: EditState())
            #expect(provider.calls == 0)
            #expect(controller.bodySkinMask == nil)
            #expect(controller.renderRequest.bodySkinMask == nil)
        }
    }

    /// With the flag on: one segmentation per shot, the mask reaches
    /// `RenderRequest`, and a hundred slider changes add nothing.
    @Test("With bodySkinSync on, the mask is computed once per shot and reaches the request")
    func flagOnComputesOncePerShot() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withBodySkinSync(true) {
            let subject = RenderMask(
                width: 32, height: 32, values: [UInt8](repeating: 255, count: 32 * 32),
                maskToImage: CGAffineTransform(scaleX: 8, y: 8))
            let provider = CountingSubjectProvider(mask: subject)
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "flag-on", editState: EditState())
            #expect(provider.calls == 1)
            #expect(provider.qualities == [LivePreviewController.subjectMaskQuality])
            #expect(controller.bodySkinUsedSubjectMask)
            let mask = try #require(controller.bodySkinMask)
            // The working grid follows the frame's aspect, not the subject
            // mask's: 320 px wide capped at the frame's own width.
            #expect(mask.width == min(320, Int(decoded.pixelSize.width)))
            #expect(controller.renderRequest.bodySkinMask?.values == mask.values)
            #expect(controller.bodySkinCoverageFraction != nil)

            for step in 0..<100 {
                var state = EditState()
                state.setSlider(
                    ColorSliders.Key.exposure, in: EditState.SectionKey.color,
                    to: Double(step) + 1)
                controller.update(editState: state)
            }
            #expect(provider.calls == 1, "a slider change must not re-segment")

            await controller.open(decoded, contentHash: "flag-on", editState: EditState())
            #expect(provider.calls == 1, "re-opening the same shot must not re-segment")

            controller.close()
            #expect(controller.bodySkinMask == nil)
            #expect(controller.bodySkinUsedSubjectMask == false)
        }
    }

    /// `nil` from the provider means "no person in this frame", and the classifier
    /// still runs — unmultiplied, i.e. v1's answer. The failure this guards is
    /// the tempting one: reading `nil` as an all-zero mask, which would silently
    /// remove all skin coverage from every landscape and product shot.
    @Test("No subject found is not an empty mask — the v1 coverage is kept")
    func nilSubjectStillProducesCoverage() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withBodySkinSync(true) {
            let provider = CountingSubjectProvider(mask: nil)
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)
            let (decoded, url) = try Self.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "no-subject", editState: EditState())
            #expect(provider.calls == 1)
            #expect(controller.bodySkinUsedSubjectMask == false)
            let mask = try #require(controller.bodySkinMask)
            let reference = try BodySkinMask.make(image: decoded.cgImage)
            #expect(mask.values == reference.mask.values)
        }
    }

    /// The default conformance is the one the app uses on every normal launch,
    /// and it has to be the *honest* no-op rather than an empty mask.
    @Test("NoSubjectMaskProvider answers nil, not an empty mask")
    func defaultProviderIsHonest() async throws {
        let (decoded, url) = try Self.decodedFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let mask = try await NoSubjectMaskProvider().subjectMask(
            for: decoded, contentHash: "x", quality: .balanced)
        #expect(mask == nil)
    }
}
