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

    // MARK: - Auto-apply

    @Test("A project with no auto-apply preset gives new shots nothing")
    func noAutoApply() throws {
        let temp = try TemporaryDirectory("auto-apply")
        let (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        #expect(store.autoApplyEditState(for: project) == nil)
    }

    @Test("An armed preset becomes the EditState a new shot starts from")
    func autoApplyResolvesFromTheProjectsOwnFolder() throws {
        let temp = try TemporaryDirectory("auto-apply")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)

        // The library copies the preset into the project before arming it, so
        // that a project moved to another machine keeps applying the same look.
        let preset = BuiltInPresets.templates[0]
        try store.savePreset(preset)
        project.autoApplyPresetID = preset.id

        let state = try #require(store.autoApplyEditState(for: project))
        #expect(state.sections == preset.sections)
        #expect(state.perImage.isEmpty)
    }

    @Test("A deleted preset disarms silently rather than failing the import")
    func autoApplyToleratesAMissingFile() throws {
        let temp = try TemporaryDirectory("auto-apply")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        project.autoApplyPresetID = PresetID.generate()
        #expect(store.autoApplyEditState(for: project) == nil)
    }
}
