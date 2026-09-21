import Foundation
import Testing

import RPCore
@testable import RPEngine

/// "Sửa da" as a document value plus the one path the UI drives it through
/// (docs/ADR-0021 §UI).
///
/// The suite exists for two separate claims:
///
/// 1. the switch stores and reads back the way ``BackgroundLock``'s does —
///    absent means off, off leaves no trace, a junk value is off;
/// 2. **the notice actually fires on the tone the feature cannot handle.**
///    `DetectionNoticeTests.skinNoticeFollowsTheCoverage` already pins the
///    mechanism with a hand-made all-zero mask; what was missing is the
///    end-to-end statement that a *real* classification of a *deep skin tone*
///    frame is what produces that zero, and therefore that a user who switches
///    "Sửa da" on for such a photo is told rather than left with a silent
///    no-op. That is the condition the reviewer ruling set for this toggle
///    shipping at all (docs/ADR-0021 §UI), so it is asserted, not assumed.
@Suite("Sửa da — the document switch and its notice")
struct BodySkinSyncTests {

    // MARK: - The document value

    @Test("Absent means off, on writes one key, off removes it again")
    func storageRoundTrip() {
        var state = EditState()
        #expect(BodySkinSync(state).isOn == false)
        #expect(state.isDefault)

        BodySkinSync(isOn: true).write(into: &state)
        #expect(BodySkinSync(state).isOn)
        #expect(state[section: BodySkinSync.section][BodySkinSync.key] == .bool(true))
        #expect(!state.isDefault)

        BodySkinSync(isOn: false).write(into: &state)
        #expect(BodySkinSync(state).isOn == false)
        // No `false` left behind: an untouched document is byte-identical to an
        // empty one, the rule every other absent-is-default value follows.
        #expect(state[section: BodySkinSync.section][BodySkinSync.key] == nil)
        #expect(state.isDefault)
    }

    /// The two switches live in one namespace and must not read each other.
    @Test("Sửa da and Khoá nền share the mask namespace without colliding")
    func theTwoMaskSwitchesAreIndependent() {
        #expect(BodySkinSync.section == BackgroundLock.section)
        #expect(BodySkinSync.key != BackgroundLock.key)

        var state = EditState()
        BackgroundLock(isOn: true).write(into: &state)
        #expect(BodySkinSync(state).isOn == false)

        BodySkinSync(isOn: true).write(into: &state)
        #expect(BackgroundLock(state).isOn)

        BodySkinSync(isOn: false).write(into: &state)
        #expect(BackgroundLock(state).isOn, "clearing one switch cleared the other")
    }

    @Test("An unreadable value reads as off rather than widening the mask")
    func junkReadsAsOff() {
        var state = EditState()
        var values = state[section: BodySkinSync.section]
        values[BodySkinSync.key] = .int(1)
        state[section: BodySkinSync.section] = values
        #expect(BodySkinSync(state).isOn == false)
    }

    // MARK: - Request assembly

    /// All three conditions, one at a time. The default — flag off, switch off —
    /// must carry no mask, which is what keeps the shipping build's skin render
    /// byte-identical to ADR-0009's.
    @Test("The mask reaches the request only with the flag on and the switch on")
    func maskNeedsBothTheFlagAndTheSwitch() {
        let mask = BodySkinUnionTests.fullFrameMask()
        var on = EditState()
        BodySkinSync(isOn: true).write(into: &on)
        let off = EditState()

        RPEngineTestFlags.exclusive {
            #expect(RPEngineFeatureFlags.bodySkinSync == false, "the shipping default moved")
            #expect(BodySkinSync.mask(for: on, bodySkinMask: mask) == nil)
            #expect(BodySkinSync.mask(for: off, bodySkinMask: mask) == nil)

            RPEngineFeatureFlags.bodySkinSync = true
            defer { RPEngineFeatureFlags.bodySkinSync = false }
            #expect(BodySkinSync.mask(for: off, bodySkinMask: mask) == nil)
            #expect(BodySkinSync.mask(for: on, bodySkinMask: mask) == mask)
            // "Not computed" stays "not computed": the switch cannot conjure a
            // mask the shot never produced.
            #expect(BodySkinSync.mask(for: on, bodySkinMask: nil) == nil)
        }
    }

    // MARK: - The notice, on a real classification

    /// The measured failure of docs/ADR-0021 §5, driven through the product
    /// path: classify a deep-tone frame, hand the result to a request the way
    /// `LivePreviewController.renderRequest` does, and ask the graph what it
    /// would tell the user.
    ///
    /// The tone-III frame is the **control**: same code, same switch, same
    /// graph, and no notice — so a green assertion below cannot be "the notice
    /// is always on".
    @Test("A deep-tone frame classifies to ~0 coverage and the graph says so")
    func deepToneFramePublishesTheNotice() throws {
        guard let context = SpikeS3Support.context else { return }

        // Tone VI (91,60,17) — rejected by SkinCore.skinScore's Kovac `R <= 95`
        // line before any per-image learning, so the whole frame comes back
        // empty. Tone III (224,172,105) is the same fixture at a tone the
        // classifier handles.
        let deep = SyntheticSkinFrame(skin: (91, 60, 17), clutter: false)
        let mid = SyntheticSkinFrame(skin: (224, 172, 105), clutter: false)
        func classify(_ frame: SyntheticSkinFrame) -> BodySkinMask.Result {
            BodySkinMask.make(
                rgb: frame.rgb, componentsPerPixel: 3, width: frame.width, height: frame.height)
        }
        let deepResult = classify(deep)
        let midResult = classify(mid)

        // The premise of the notice, measured rather than assumed.
        #expect(deepResult.coverageFraction < SkinRenderNode.minimumBodySkinCoverage)
        #expect(midResult.coverageFraction > 0.05)
        #expect(!SkinRenderNode.isUsableBodyCoverage(deepResult.mask))
        #expect(SkinRenderNode.isUsableBodyCoverage(midResult.mask))

        var document = EditState()
        SkinRenderNodeTests.allSliders.write(into: &document)
        BodySkinSync(isOn: true).write(into: &document)

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
        let graph = try RenderGraph.standard(context: context)

        func request(_ result: BodySkinMask.Result, document: EditState) -> RenderRequest {
            var request = RenderRequest(
                editState: document, faces: [SkinRenderNodeTests.face], quality: .preview)
            // Exactly what `LivePreviewController.renderRequest` does.
            request.bodySkinMask = BodySkinSync.mask(
                for: document, bodySkinMask: result.mask)
            return request
        }

        #expect(
            graph.detectionNotices(for: request(deepResult, document: document))
                == ["skin": "Không phát hiện được da."])
        #expect(graph.detectionNotices(for: request(midResult, document: document)).isEmpty)

        // …and with the switch off the user is told nothing, because nothing was
        // asked for: the same deep-tone photo, the same flag, no notice.
        var untouched = EditState()
        SkinRenderNodeTests.allSliders.write(into: &untouched)
        #expect(BodySkinSync(untouched).isOn == false)
        #expect(graph.detectionNotices(for: request(deepResult, document: untouched)).isEmpty)
    }
}
