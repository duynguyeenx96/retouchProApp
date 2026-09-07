import Foundation
import Testing

@testable import RPCore

@Suite("Preset — EditState minus per-image fields")
struct PresetTests {
    private func editedState() -> EditState {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        state.setSlider("evenTone", in: EditState.SectionKey.skin, to: 25)
        state.setSlider("jawWidth", in: EditState.SectionKey.face, to: 30)
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 12)
        state.perImage["crop"] = ["x": 0.1, "y": 0.0, "w": 0.9, "h": 1.0]
        state.perImage["healStrokes"] = [["x": 0.5, "y": 0.5, "r": 0.01]]
        return state
    }

    @Test("Making a preset drops per-image state and keeps the transferable sections")
    func stripsPerImage() throws {
        let state = editedState()
        let preset = Preset(name: "Studio soft", from: state)

        #expect(preset.sections == state.sections)
        #expect(preset.schemaVersion == state.schemaVersion)

        let text = try Fixture.string(preset)
        #expect(!text.contains("perImage"))
        #expect(!text.contains("healStrokes"))
        #expect(!text.contains("crop"))
        #expect(text.contains("jawWidth"))
    }

    @Test("A preset can be limited to a group of sections")
    func limitedToSections() {
        let preset = Preset(
            name: "Skin only",
            group: "Da",
            from: editedState(),
            limitedTo: [EditState.SectionKey.skin]
        )
        #expect(Set(preset.sections.keys) == [EditState.SectionKey.skin])
        #expect(preset.group == "Da")
    }

    @Test("Preset round-trips through JSON")
    func roundTrip() throws {
        let preset = Preset(
            id: .generate(),
            name: "Studio soft",
            group: "Da",
            createdAt: Fixture.date(),
            from: editedState()
        )
        let decoded = try RPJSON.decoder.decode(
            Preset.self, from: try RPJSON.encoder.encode(preset))
        #expect(decoded == preset)
    }

    @Test("An unknown key in a preset file survives a round trip")
    func forwardCompatible() throws {
        let future = Fixture.json(
            """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "From a newer build",
              "schemaVersion": 9,
              "sections": { "skin": { "smooth": 30 } },
              "thumbnail": "preview.jpg",
              "authoredOn": {"device": "iPad"}
            }
            """)
        let decoded = try RPJSON.decoder.decode(Preset.self, from: future)
        #expect(decoded.name == "From a newer build")
        #expect(decoded.schemaVersion == 9)
        #expect(decoded.additionalValues["thumbnail"] == .string("preview.jpg"))

        let reDecoded = try RPJSON.decoder.decode(
            Preset.self, from: try RPJSON.encoder.encode(decoded))
        #expect(reDecoded.additionalValues == decoded.additionalValues)
    }

    @Test("Applying a preset replaces the sections and leaves per-image state alone")
    func applyReplace() {
        var target = EditState()
        target.setSlider("smooth", in: "skin", to: 90)
        target.setSlider("exposure", in: "color", to: 5)
        target.perImage["crop"] = ["x": 0.25]

        let preset = Preset(name: "P", sections: ["skin": EditSection(sliders: ["smooth": 20])])
        let result = target.applying(preset)

        #expect(result.slider("smooth", in: "skin") == 20)
        #expect(result.slider("exposure", in: "color") == 0, "replace resets untouched sections")
        #expect(result.perImage["crop"] == ["x": 0.25], "a preset must never move the crop")
    }

    @Test("Merging a grouped preset keeps the sections it does not carry")
    func applyMerge() {
        var target = EditState()
        target.setSlider("smooth", in: "skin", to: 90)
        target.setSlider("exposure", in: "color", to: 5)

        let preset = Preset(
            name: "Skin only", sections: ["skin": EditSection(sliders: ["evenTone": 30])])
        let result = target.applying(preset, mode: .merge)

        #expect(result.slider("evenTone", in: "skin") == 30)
        #expect(result.slider("smooth", in: "skin") == 90)
        #expect(result.slider("exposure", in: "color") == 5)
    }

    @Test("The same preset applied to two shots produces the same sections")
    func transfersBetweenShots() {
        let preset = Preset(name: "Look", from: editedState())
        var a = EditState()
        a.perImage["crop"] = ["x": 0.1]
        var b = EditState()
        b.perImage["crop"] = ["x": 0.9]

        let resultA = a.applying(preset)
        let resultB = b.applying(preset)
        #expect(resultA.sections == resultB.sections)
        #expect(resultA.perImage != resultB.perImage)
    }

    @Test("EditSection(sliders:) clamps and drops defaults")
    func sectionFromSliders() {
        let section = EditSection(sliders: ["a": 150, "b": 0, "c": -5, "d": 50])
        #expect(section.slider("a") == 100)
        #expect(section["b"] == nil)
        #expect(section["c"] == nil)
        #expect(section.slider("d") == 50)
    }
}
