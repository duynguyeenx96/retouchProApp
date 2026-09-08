import Foundation
import Testing

@testable import RPCore

/// Shared helpers for the document tests.
enum Fixture {
    /// A date with exact millisecond precision, so a round trip through the
    /// ISO-8601-with-fractional-seconds encoder is loss-free and `==` works.
    static func date(_ seconds: Double = 1_757_000_000.5) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    static func string(_ value: some Encodable) throws -> String {
        String(decoding: try RPJSON.encoder.encode(value), as: UTF8.self)
    }
}

@Suite("EditState — envelope and forward compatibility")
struct EditStateTests {
    @Test("A default EditState is empty and versioned")
    func defaultState() {
        let state = EditState()
        #expect(state.schemaVersion == EditState.currentSchemaVersion)
        #expect(state.isDefault)
        #expect(state.slider("smooth", in: EditState.SectionKey.skin) == 0)
    }

    @Test("Sliders default to 0, clamp to 0–100, and 0 removes the key")
    func sliderSemantics() {
        var state = EditState()
        #expect(state.slider("smooth", in: "skin") == 0)

        state.setSlider("smooth", in: "skin", to: 40)
        #expect(state.slider("smooth", in: "skin") == 40)

        state.setSlider("smooth", in: "skin", to: 250)
        #expect(state.slider("smooth", in: "skin") == 100)

        state.setSlider("smooth", in: "skin", to: -20)
        #expect(state.slider("smooth", in: "skin") == 0)
        // Back at the default → the key is gone, and so is the empty section.
        #expect(state.sections["skin"] == nil)
        #expect(state.isDefault)

        state.setSlider("nan", in: "skin", to: .nan)
        #expect(state.slider("nan", in: "skin") == 0)
    }

    @Test("EditState round-trips through JSON")
    func roundTrip() throws {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 42.5)
        state.setSlider("evenTone", in: EditState.SectionKey.skin, to: 10)
        state.setSlider("jawWidth", in: EditState.SectionKey.face, to: 33)
        state.perImage["crop"] = ["x": 0.1, "y": 0.2, "w": 0.8, "h": 0.8]

        let data = try RPJSON.encoder.encode(state)
        let decoded = try RPJSON.decoder.decode(EditState.self, from: data)
        #expect(decoded == state)
    }

    @Test("Encoding is deterministic")
    func deterministicEncoding() throws {
        var state = EditState()
        state.setSlider("smooth", in: "skin", to: 42)
        state.setSlider("aaa", in: "color", to: 1)
        let first = try RPJSON.encoder.encode(state)
        let second = try RPJSON.encoder.encode(state)
        #expect(first == second)
    }

    // MARK: Forward compatibility

    @Test("An unknown top-level key decodes without error and survives re-encoding")
    func unknownTopLevelKeyIsPreserved() throws {
        let future = Fixture.json(
            """
            {
              "schemaVersion": 7,
              "sections": { "skin": { "smooth": 40 } },
              "aiRelight": { "strength": 0.5, "enabled": true },
              "futureScalar": 12
            }
            """)

        let decoded = try RPJSON.decoder.decode(EditState.self, from: future)
        #expect(decoded.schemaVersion == 7)
        #expect(decoded.slider("smooth", in: "skin") == 40)
        #expect(decoded.additionalValues["futureScalar"] == .int(12))
        #expect(
            decoded.additionalValues["aiRelight"]?.objectValue?["strength"] == .double(0.5))

        // Re-encode as an older build would after the user moved one slider.
        var edited = decoded
        edited.setSlider("smooth", in: "skin", to: 55)
        let reDecoded = try RPJSON.decoder.decode(
            EditState.self, from: try RPJSON.encoder.encode(edited))
        #expect(reDecoded.slider("smooth", in: "skin") == 55)
        #expect(reDecoded.additionalValues == decoded.additionalValues)
        #expect(reDecoded.schemaVersion == 7)
    }

    @Test("An unknown parameter inside a known section survives")
    func unknownSectionParameterIsPreserved() throws {
        let future = Fixture.json(
            """
            {
              "schemaVersion": 1,
              "sections": {
                "skin": { "smooth": 40, "poreRecovery": 61, "lutName": "warm" }
              }
            }
            """)
        let decoded = try RPJSON.decoder.decode(EditState.self, from: future)
        #expect(decoded.slider("poreRecovery", in: "skin") == 61)
        #expect(decoded.sections["skin"]?["lutName"] == .string("warm"))

        let reDecoded = try RPJSON.decoder.decode(
            EditState.self, from: try RPJSON.encoder.encode(decoded))
        #expect(reDecoded == decoded)
    }

    @Test("A whole unknown section survives")
    func unknownSectionIsPreserved() throws {
        let future = Fixture.json(
            """
            {"schemaVersion": 2, "sections": {"backgroundClean": {"strength": 80}}}
            """)
        let decoded = try RPJSON.decoder.decode(EditState.self, from: future)
        #expect(decoded.slider("strength", in: "backgroundClean") == 80)
        let text = try Fixture.string(decoded)
        #expect(text.contains("backgroundClean"))
    }

    @Test("Missing optional keys decode to defaults")
    func missingKeysDecodeToDefaults() throws {
        let minimal = Fixture.json("{}")
        let decoded = try RPJSON.decoder.decode(EditState.self, from: minimal)
        #expect(decoded.schemaVersion == EditState.currentSchemaVersion)
        #expect(decoded.isDefault)
    }

    @Test("Per-image values are not written when empty")
    func emptyPerImageIsOmitted() throws {
        var state = EditState()
        state.setSlider("smooth", in: "skin", to: 5)
        #expect(!(try Fixture.string(state).contains("perImage")))
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Every case round-trips, and Int does not become Double")
    func roundTrip() throws {
        let value: JSONValue = [
            "null": nil,
            "bool": true,
            "int": 3,
            "double": 3.5,
            "string": "hello",
            "array": [1, "two", false],
            "object": ["nested": 1],
        ]
        let data = try RPJSON.encoder.encode(value)
        let decoded = try RPJSON.decoder.decode(JSONValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded.objectValue?["int"] == .int(3))
        #expect(decoded.objectValue?["double"] == .double(3.5))
        #expect(String(decoding: data, as: UTF8.self).contains("\"int\" : 3,"))
    }

    @Test("Accessors return nil for the wrong case")
    func accessors() {
        #expect(JSONValue.string("x").numberValue == nil)
        #expect(JSONValue.int(4).numberValue == 4)
        #expect(JSONValue.double(4.5).numberValue == 4.5)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.array([1]).arrayValue?.count == 1)
    }
}

@Suite("Identifier")
struct IdentifierTests {
    @Test("Generated identifiers are valid file-name components")
    func generated() {
        let id = ShotID.generate()
        #expect(ShotID.isValid(id.rawValue))
        #expect(!id.rawValue.contains("/"))
    }

    @Test(
        "Path-unsafe raw values are rejected",
        arguments: ["", "..", ".", "../escape", "a/b", ".hidden", "with space", "sym*bol"])
    func rejectsUnsafe(candidate: String) {
        #expect(ShotID(candidate) == nil)
    }

    @Test("Decoding a path-unsafe identifier throws instead of writing outside the bundle")
    func decodeRejectsUnsafe() {
        #expect(throws: (any Error).self) {
            try RPJSON.decoder.decode(ShotID.self, from: Fixture.json("\"../../etc/passwd\""))
        }
    }

    @Test("Identifiers encode as bare strings")
    func encodesAsString() throws {
        let id = try #require(ShotID("abc-123"))
        #expect(try Fixture.string(id) == "\"abc-123\"")
    }
}

/// docs/ADR-0016 widened the **"Color" group only** to −100…100. These are the
/// tests that say the widening is scoped: a "Da" / "Mặt" / "Mắt & Răng" slider
/// still refuses a negative value, and the two "Color" sliders that stayed
/// one-directional still refuse one too.
@Suite("Slider range scope")
struct SliderRangeScopeTests {
    /// The three face groups. Named here rather than derived, so widening a
    /// range in RPCore cannot quietly widen them as well.
    static let oneDirectionalSections = [
        EditState.SectionKey.skin, EditState.SectionKey.face, EditState.SectionKey.eyesTeeth,
        EditState.SectionKey.makeup, EditState.SectionKey.hair,
    ]

    @Test("The project default is still 0…100 with default 0")
    func defaultsUnchanged() {
        #expect(Slider.range == 0...100)
        #expect(Slider.defaultValue == 0)
        #expect(Slider.signedRange == -100...100)
        #expect(Slider.clamp(-20) == 0)
        #expect(Slider.clamp(250) == 100)
        #expect(Slider.clamp(.nan) == 0)
    }

    @Test(
        "Every group except Color still clamps to 0…100",
        arguments: oneDirectionalSections)
    func otherGroupsStayOneDirectional(section: String) {
        for parameter in ["smooth", "chin", "eyeBrighten", "exposure", "anything"] {
            #expect(Slider.range(for: parameter, in: section) == 0...100)
        }
        var state = EditState()
        state.setSlider("smooth", in: section, to: -60)
        // −60 clamps to 0, which is the default, which removes the key.
        #expect(state.slider("smooth", in: section) == 0)
        #expect(state.sections[section] == nil)
        state.setSlider("smooth", in: section, to: 40)
        #expect(state.slider("smooth", in: section) == 40)
        state.setSlider("smooth", in: section, to: 400)
        #expect(state.slider("smooth", in: section) == 100)
    }

    @Test("Color sliders take −100…100 and keep the key on the negative side")
    func colorIsBidirectional() {
        var state = EditState()
        state.setSlider("exposure", in: EditState.SectionKey.color, to: -40)
        #expect(state.slider("exposure", in: EditState.SectionKey.color) == -40)
        #expect(!state.isDefault)
        state.setSlider("exposure", in: EditState.SectionKey.color, to: -400)
        #expect(state.slider("exposure", in: EditState.SectionKey.color) == -100)
        // …and 0 is still the one value that removes the key.
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 0)
        #expect(state.isDefault)
    }

    @Test("Curves and Auto D&B stay one-directional inside the Color group")
    func colorExceptions() {
        let color = EditState.SectionKey.color
        #expect(Slider.range(for: "curves", in: color) == 0...100)
        #expect(Slider.range(for: "autoDodgeBurn", in: color) == 0...100)
        #expect(Slider.range(for: "exposure", in: color) == -100...100)
        // An unknown key in the Color section gets the section's rule, not the
        // exception list's.
        #expect(Slider.range(for: "somethingNew", in: color) == -100...100)

        var state = EditState()
        state.setSlider("curves", in: color, to: -50)
        state.setSlider("autoDodgeBurn", in: color, to: -50)
        #expect(state.isDefault)
    }

    @Test("EditSection(sliders:in:) follows the same rule")
    func bagInitFollowsTheSection() {
        let color = EditSection(sliders: ["exposure": -40, "curves": -40], in: "color")
        #expect(color.slider("exposure") == -40)
        #expect(color["curves"] == nil)
        // Without a section, the safe one-directional rule.
        let anonymous = EditSection(sliders: ["exposure": -40])
        #expect(anonymous.isEmpty)
        let skin = EditSection(sliders: ["smooth": -40, "evenTone": 30], in: "skin")
        #expect(skin["smooth"] == nil)
        #expect(skin.slider("evenTone") == 30)
    }
}
