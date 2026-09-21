import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// docs/PLAN.md §6.1 / docs/ADR-0018 — the canvas half of "Khoá nền": who
/// rasterises the subject mask into a gate, when, and what reaches
/// `RenderRequest.gateMasks`.
///
/// The decision table itself is `RPEngineTests/BackgroundLockTests`; the
/// rasteriser is `RPEngineTests/BackgroundLockMaskTests`; the Vision request is
/// `RPVisionTests/PersonSegmenterTests`. What is left, and what this file pins,
/// is the two things only the controller can be wrong about:
///
/// 1. **One segmentation per shot for two features.** "Sửa da" already asks for
///    a whole-frame subject mask (ADR-0021 §v2) and "Khoá nền" wants the same
///    pixels. At 17 ms per request (`.balanced`) asking twice would double the
///    per-shot cost for nothing, so the mask is computed once and published as
///    `LivePreviewController.subjectMask`.
/// 2. **With the flag off, nothing happens at all** — no request, no texture, no
///    gate, and `gateMasks` stays empty, which `RenderGateMask` defines as "the
///    pre-6.1 render". That is the whole of "the rail control ships locked", in
///    the engine rather than in the UI.
///
/// `.serialized` because `RPEngineFeatureFlags` is a process-global store.
@Suite("Phase 6.1 background lock wiring", .serialized)
@MainActor
struct BackgroundLockWiringTests {

    typealias CountingSubjectProvider = BodySkinSyncWiringTests.CountingSubjectProvider

    /// Takes ``RPUIMaskFlagLock`` for the same reason
    /// `BodySkinSyncWiringTests.withBodySkinSync` does: both suites drive both
    /// of these process-global flags across an `await`, and `.serialized` does
    /// not order one suite against another.
    static func withFlags(
        backgroundLock: Bool, bodySkinSync: Bool = false, _ body: () async throws -> Void
    ) async throws {
        try await RPUIMaskFlagLock.exclusive {
            let previousLock = RPEngineFeatureFlags.backgroundLock
            let previousSync = RPEngineFeatureFlags.bodySkinSync
            RPEngineFeatureFlags.backgroundLock = backgroundLock
            RPEngineFeatureFlags.bodySkinSync = bodySkinSync
            defer {
                RPEngineFeatureFlags.backgroundLock = previousLock
                RPEngineFeatureFlags.bodySkinSync = previousSync
            }
            try await body()
        }
    }

    /// A full-coverage subject mask at a quarter of the fixture's size, so the
    /// rasteriser has a real affine to apply rather than an identity.
    static func subject(for image: PreviewImage) -> RenderMask {
        let width = max(1, Int(image.pixelSize.width) / 4)
        let height = max(1, Int(image.pixelSize.height) / 4)
        return RenderMask(
            width: width, height: height,
            values: [UInt8](repeating: 255, count: width * height),
            maskToImage: CGAffineTransform(scaleX: 4, y: 4))
    }

    static func lockedOn() -> EditState {
        var state = EditState()
        BackgroundLock(isOn: true).write(into: &state)
        return state
    }

    // MARK: - The flag off: the shipping build

    /// The cost model and the lock, in one assertion. This is what "Khoá nền is
    /// wired but not on" has to mean: the document may say `true` and the app
    /// still does nothing, because the ADR's blocker (no iPhone measurement) is
    /// unresolved.
    @Test("With backgroundLock off nothing is segmented, rasterised or gated")
    func flagOffCostsNothingAndGatesNothing() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(backgroundLock: false) {
            let provider = CountingSubjectProvider(mask: nil)
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)
            let (decoded, url) = try BodySkinSyncWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "lock-off", editState: Self.lockedOn())
            #expect(provider.calls == 0)
            #expect(controller.subjectMask == nil)
            #expect(controller.backgroundLockGate == nil)
            #expect(controller.renderRequest.gateMasks.isEmpty)
        }
    }

    // MARK: - The flag on

    /// One request, one texture, and the gate reaches the request — but only
    /// while the document's own toggle says so.
    @Test("With the flag on, the gate is built once per shot and follows the toggle")
    func flagOnBuildsTheGateOncePerShot() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(backgroundLock: true) {
            let (decoded, url) = try BodySkinSyncWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let provider = CountingSubjectProvider(mask: Self.subject(for: decoded))
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)

            await controller.open(decoded, contentHash: "lock-on", editState: Self.lockedOn())
            #expect(provider.calls == 1)
            #expect(provider.qualities == [LivePreviewController.subjectMaskQuality])
            #expect(controller.subjectMask != nil)

            let gate = try #require(controller.backgroundLockGate)
            // Full resolution, in the grid the graph renders in — which is what
            // makes the identity transform correct.
            #expect(gate.gateWidth == Int(decoded.pixelSize.width))
            #expect(gate.gateHeight == Int(decoded.pixelSize.height))
            #expect(gate.gateMaskToImage == .identity)

            let gates = controller.renderRequest.gateMasks
            #expect(gates.count == 1)
            #expect(gates.first === gate)

            // A slider drag must not re-segment or rebuild the texture.
            for step in 0..<50 {
                var state = Self.lockedOn()
                state.setSlider(
                    ColorSliders.Key.exposure, in: EditState.SectionKey.color,
                    to: Double(step) + 1)
                controller.update(editState: state)
            }
            #expect(provider.calls == 1)
            #expect(controller.backgroundLockGate === gate)

            // Toggling the document off stops the gating with no recomputation:
            // the condition is read when the request is assembled.
            controller.update(editState: EditState())
            #expect(controller.renderRequest.gateMasks.isEmpty)
            #expect(controller.backgroundLockGate === gate)
            #expect(provider.calls == 1)

            controller.close()
            #expect(controller.subjectMask == nil)
            #expect(controller.backgroundLockGate == nil)
        }
    }

    /// `nil` from the provider is "no person in this frame" — a landscape, a
    /// product shot. The failure this guards is the tempting one: manufacturing
    /// an all-zero gate, which would multiply every mask-driven slider to zero
    /// on exactly the photos where the feature has nothing to do.
    @Test("No subject found means no gate, not an empty one")
    func noSubjectMeansNoGate() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(backgroundLock: true) {
            let provider = CountingSubjectProvider(mask: nil)
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)
            let (decoded, url) = try BodySkinSyncWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }

            await controller.open(decoded, contentHash: "no-subject", editState: Self.lockedOn())
            #expect(provider.calls == 1)
            #expect(controller.subjectMask == nil)
            #expect(controller.backgroundLockGate == nil)
            #expect(controller.renderRequest.gateMasks.isEmpty)
        }
    }

    /// The point of publishing `subjectMask` rather than keeping it inside the
    /// body-skin step: with both features on there is still exactly **one**
    /// `VNGeneratePersonSegmentationRequest` per shot, and both consume it.
    @Test("Both features on still means one segmentation per shot")
    func bothFeaturesShareOneRequest() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(backgroundLock: true, bodySkinSync: true) {
            let (decoded, url) = try BodySkinSyncWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let provider = CountingSubjectProvider(mask: Self.subject(for: decoded))
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)

            // Both document switches on: they share the `mask` namespace and
            // must not read each other (docs/ADR-0021 §UI).
            var document = Self.lockedOn()
            BodySkinSync(isOn: true).write(into: &document)
            await controller.open(decoded, contentHash: "both", editState: document)
            #expect(provider.calls == 1)
            #expect(controller.subjectMask != nil)
            #expect(controller.bodySkinUsedSubjectMask)
            #expect(controller.bodySkinMask != nil)
            #expect(controller.backgroundLockGate != nil)

            let request = controller.renderRequest
            #expect(request.bodySkinMask != nil)
            #expect(request.gateMasks.count == 1)
        }
    }

    /// The other half of the sharing claim: "Sửa da" on its own behaves exactly
    /// as it did before this wiring landed — one request, a body mask, and **no**
    /// gate, so `SkinRenderNode`'s measured coverage is unchanged.
    @Test("bodySkinSync alone adds no gate")
    func bodySkinSyncAloneAddsNoGate() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(backgroundLock: false, bodySkinSync: true) {
            let (decoded, url) = try BodySkinSyncWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let provider = CountingSubjectProvider(mask: Self.subject(for: decoded))
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context), subjectProvider: provider)

            await controller.open(decoded, contentHash: "sync-only", editState: Self.lockedOn())
            #expect(provider.calls == 1)
            #expect(controller.bodySkinMask != nil)
            #expect(controller.backgroundLockGate == nil)
            #expect(controller.renderRequest.gateMasks.isEmpty)
        }
    }
}
