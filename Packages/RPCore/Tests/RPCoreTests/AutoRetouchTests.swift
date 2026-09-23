import Foundation
import Testing

@testable import RPCore

/// "Tự động v1" (docs/PLAN.md §6.5): the fixed recipe, its overall strength,
/// and what applying it leaves alone.
@Suite("Auto retouch v1 recipe")
struct AutoRetouchTests {
    private let skin = EditState.SectionKey.skin
    private let eyes = EditState.SectionKey.eyesTeeth
    private let color = EditState.SectionKey.color

    @Test("The recipe is Mịn da 30, Đều màu da 20, Sáng mắt 15, Auto D&B 40 — and no Mặt")
    func recipeMapping() {
        #expect(
            AutoRetouch.recipe.map { "\($0.section).\($0.key)=\(Int($0.value))" } == [
                "skin.smooth=30", "skin.evenTone=20", "eyesTeeth.eyeBrighten=15",
                "color.autoDodgeBurn=40",
            ])
        #expect(!AutoRetouch.sectionNames.contains(EditState.SectionKey.face))
        let full = EditState().applyingAutoRetouch(strength: 1)
        #expect(full.slider("smooth", in: skin) == 30)
        #expect(full.slider("evenTone", in: skin) == 20)
        #expect(full.slider("eyeBrighten", in: eyes) == 15)
        #expect(full.slider("autoDodgeBurn", in: color) == 40)
        #expect(Set(full.sections.keys) == AutoRetouch.sectionNames)
    }

    @Test("Strength scales every value: 0, 0.5, 1", arguments: [0.0, 0.5, 1.0])
    func strengthScales(strength: Double) {
        let state = EditState().applyingAutoRetouch(strength: strength)
        for ingredient in AutoRetouch.recipe {
            #expect(
                state.slider(ingredient.key, in: ingredient.section)
                    == ingredient.value * strength)
        }
        #expect(AutoRetouch.strength(in: state) == strength)
        // Strength 0 is "no auto": the four keys are removed, not stored as 0,
        // so an otherwise untouched photo is untouched again.
        if strength == 0 { #expect(state.isDefault) }
    }

    @Test("Out-of-range strength clamps into 0...1")
    func strengthClamps() {
        #expect(EditState().applyingAutoRetouch(strength: 3) == EditState().applyingAutoRetouch(strength: 1))
        #expect(EditState().applyingAutoRetouch(strength: -1).isDefault)
        #expect(EditState().applyingAutoRetouch(strength: .nan).isDefault)
    }

    @Test("Only the four recipe keys change; every other slider and perImage survive")
    func keyScoping() {
        var state = EditState()
        state.setSlider("redness", in: skin, to: 55)  // same section, other key
        state.setSlider("exposure", in: color, to: -30)  // same section, signed
        state.setSlider("scleraWhiten", in: eyes, to: 10)
        state.setSlider("slim", in: EditState.SectionKey.face, to: 25)  // Mặt
        state.setSlider("smooth", in: skin, to: 80)  // a recipe key, replaced
        state.perImage["selectedFace"] = 1

        let applied = state.applyingAutoRetouch(strength: 0.5)

        #expect(applied.slider("redness", in: skin) == 55)
        #expect(applied.slider("exposure", in: color) == -30)
        #expect(applied.slider("scleraWhiten", in: eyes) == 10)
        #expect(applied.slider("slim", in: EditState.SectionKey.face) == 25)
        #expect(applied.perImage == state.perImage)
        #expect(applied.slider("smooth", in: skin) == 15)

        // At strength 0 the recipe keys go to neutral, the rest still stay.
        let zero = state.applyingAutoRetouch(strength: 0)
        #expect(zero.slider("smooth", in: skin) == 0)
        #expect(zero[section: skin].values["smooth"] == nil)
        #expect(zero.slider("redness", in: skin) == 55)
        #expect(zero[section: EditState.SectionKey.face] == state[section: EditState.SectionKey.face])
    }

    @Test("Strength reads back as nil once a recipe slider is moved by hand")
    func strengthReadBack() {
        #expect(AutoRetouch.strength(in: EditState()) == 0)
        var state = EditState().applyingAutoRetouch(strength: 0.8)
        #expect(abs((AutoRetouch.strength(in: state) ?? -1) - 0.8) < 1e-9)
        state.setSlider("smooth", in: skin, to: 90)
        #expect(AutoRetouch.strength(in: state) == nil)
        // …but the estimate still lands somewhere sensible, in range.
        let estimate = AutoRetouch.estimatedStrength(in: state)
        #expect(estimate > 0.8 && estimate <= 1)
    }

    @Test("It goes through the Preset type, and the preset carries no face and no perImage")
    func presetShape() {
        let preset = AutoRetouch.preset(strength: 1)
        #expect(preset.carriedSectionNames == AutoRetouch.sectionNames)
        #expect(preset == AutoRetouch.preset(strength: 1))
        #expect(AutoRetouch.preset(strength: 0).isEmpty)
    }
}
