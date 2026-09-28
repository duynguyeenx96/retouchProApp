import Foundation
import Testing

@testable import RPCore

/// `applying(_:replacingSections:)` and the auto-apply hook every importer goes
/// through (docs/PLAN.md §Phase 3).
@Suite("Applying a preset to named sections")
struct PresetApplyTests {
    private func edited() -> EditState {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 12)
        state.perImage["selectedFace"] = 1
        return state
    }

    @Test("A colour-only Look leaves skin work alone")
    func replacesOnlyNamedSections() {
        let look = BuiltInPresets.looks[1]  // "Tự nhiên"
        let result = edited().applying(look, replacingSections: [EditState.SectionKey.color])

        #expect(result.slider("smooth", in: EditState.SectionKey.skin) == 40)
        #expect(
            result[section: EditState.SectionKey.color]
                == look.sections[EditState.SectionKey.color])
    }

    @Test("An empty preset resets exactly its own sections — that is what 'Gốc' means")
    func emptyPresetResetsNamedSections() {
        let goc = BuiltInPresets.looks[0]
        #expect(goc.isEmpty)

        let result = edited().applying(goc, replacingSections: [EditState.SectionKey.color])

        #expect(result[section: EditState.SectionKey.color].isEmpty)
        #expect(result.slider("smooth", in: EditState.SectionKey.skin) == 40)
    }

    @Test("Per-image data survives, so applying a preset cannot retarget the face")
    func keepsPerImage() {
        let result = edited().applying(
            BuiltInPresets.templates[0], replacingSections: Set(EditState.SectionKey.all))
        #expect(result.perImage["selectedFace"] == 1)
    }

    @Test("carriedSectionNames ignores empty sections")
    func carriedSectionNames() {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 10)
        let preset = Preset(name: "Da", from: state)
        #expect(preset.carriedSectionNames == [EditState.SectionKey.skin])
        #expect(Preset(name: "Rỗng").carriedSectionNames.isEmpty)
    }

    // MARK: - Auto-apply (retired 2026-09-28)

    @Test("A project written with the retired auto-apply key opens, and the key is dropped")
    func retiredAutoApplyKeyIsDropped() throws {
        let project = Project(name: "Shoot")
        var json = try #require(
            JSONSerialization.jsonObject(with: RPJSON.compactEncoder.encode(project))
                as? [String: Any])
        json["autoApplyPresetID"] = PresetID.generate().rawValue
        let old = try JSONSerialization.data(withJSONObject: json)

        let decoded = try RPJSON.decoder.decode(Project.self, from: old)
        #expect(decoded.additionalValues["autoApplyPresetID"] == nil)
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: RPJSON.compactEncoder.encode(decoded))
                as? [String: Any])
        #expect(rewritten["autoApplyPresetID"] == nil)
    }
}
