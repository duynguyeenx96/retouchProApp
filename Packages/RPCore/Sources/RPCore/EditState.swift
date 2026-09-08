import Foundation

/// The fixed contract for every retouch slider (docs/PLAN.md §3, Phase 2):
/// **default 0**, and 0 is always neutral. "Default 0" is why an absent key and a
/// key set to 0 mean the same thing — see ``EditSection/setSlider(_:to:)``.
///
/// ## Two ranges, scoped per (section, parameter)
///
/// * ``range`` — `0...100`, one direction. Every "Da", "Mặt" and "Mắt / Răng"
///   slider, and two of the "Color" ones. Unchanged since Phase 1.
/// * ``signedRange`` — `-100...100`, centred on 0. The "Color" group only
///   (docs/ADR-0016): a photograph arriving already over-processed needs
///   *less* exposure / contrast / saturation than it has, not only more.
///
/// Widening the range does **not** touch the "absent == neutral" contract that
/// makes an empty `EditState` a bit-exact passthrough: 0 is still the default and
/// still the identity, it simply now has values on both sides of it. What would
/// break the contract is a slider whose *neutral* is not its default — a
/// temperature centred at 50 — and that is still not allowed anywhere.
///
/// The lookup is deliberately per **(section, parameter)** rather than global:
/// widening ``range`` itself would silently let a "Mặt" reshape slider take
/// −100, which has no meaning in `FaceReshape` (`SliderRangeScopeTests`).
public enum Slider {
    /// The one-directional range: the project default, and what every group
    /// except "Color" uses.
    public static let range: ClosedRange<Double> = 0...100
    /// The bidirectional range, used by the "Color" group.
    public static let signedRange: ClosedRange<Double> = -100...100
    public static let defaultValue: Double = 0

    /// Sections whose sliders are bidirectional by default.
    ///
    /// Exactly one, and adding a second is a plan-level decision, not a tidy-up:
    /// a signed value has to *mean* something in the node that reads it
    /// (docs/ADR-0016).
    public static let bidirectionalSections: Set<String> = [EditState.SectionKey.color]

    /// Parameters that stay `0...100` even inside a bidirectional section,
    /// keyed by section.
    ///
    /// Both of the "Color" exceptions are argued in docs/ADR-0016 rather than
    /// left as an omission: `curves` is the *amount* of one fixed film look and
    /// the opposite of a look is not a look (and extrapolating past 0 clips both
    /// ends of the curve); `autoDodgeBurn` is a *correction* of this frame's
    /// local luminance error, and "make the blotches worse" is not what a user
    /// dragging it left is asking for.
    ///
    /// The strings are RPEngine's `ColorSliders.Key` values. RPCore cannot import
    /// RPEngine, so `ColorRenderNodeTests.rangesAreScopedToTheColorGroup` pins
    /// the two lists together.
    public static let oneDirectionalParameters: [String: Set<String>] = [
        EditState.SectionKey.color: ["curves", "autoDodgeBurn"]
    ]

    /// The range one parameter of one section accepts.
    public static func range(for parameter: String, in section: String) -> ClosedRange<Double> {
        guard bidirectionalSections.contains(section) else { return range }
        guard oneDirectionalParameters[section]?.contains(parameter) != true else { return range }
        return signedRange
    }

    public static func clamp(_ value: Double, to range: ClosedRange<Double> = Slider.range)
        -> Double
    {
        guard value.isFinite else { return defaultValue }
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }

    /// Clamps to whatever range this parameter of this section accepts.
    public static func clamp(_ value: Double, for parameter: String, in section: String) -> Double {
        clamp(value, to: range(for: parameter, in: section))
    }
}

/// One namespace of edit parameters, e.g. everything under `"skin"`.
///
/// Phase 1 deliberately does **not** declare the individual sliders: Phase 2
/// owns that list (docs/PLAN.md Phase 2). A section is therefore a plain
/// JSON object with typed accessors on top, so Phase 2 can add
/// `skin.smooth`, `skin.evenTone`, … without a file-format migration and
/// without this file changing at all.
///
/// It serialises *transparently* — an `EditSection` is written as the bare JSON
/// object, not wrapped in another level.
public struct EditSection: Hashable, Sendable {
    /// Raw parameter values keyed by parameter name.
    public var values: [String: JSONValue]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// Convenience for the common "a bag of sliders" case.
    ///
    /// `section` picks the clamping rule: without it every value is clamped to
    /// the one-directional `0...100`, which is what a caller that does not know
    /// which namespace it is filling should get.
    public init(sliders: [String: Double], in section: String? = nil) {
        self.values = sliders.reduce(into: [:]) { values, entry in
            let clamped =
                section.map { Slider.clamp(entry.value, for: entry.key, in: $0) }
                ?? Slider.clamp(entry.value)
            guard clamped != Slider.defaultValue else { return }
            values[entry.key] = .number(clamped)
        }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// The slider value, or `0` when unset or not a number.
    public func slider(_ name: String) -> Double {
        values[name]?.numberValue ?? Slider.defaultValue
    }

    /// Sets a slider, clamped to `range` (0–100 unless the caller says
    /// otherwise — ``EditState/setSlider(_:in:to:)`` passes the section's rule).
    /// Setting it back to the default (0) *removes* the key, so a saved document
    /// only lists what the user changed.
    public mutating func setSlider(
        _ name: String, to value: Double, range: ClosedRange<Double> = Slider.range
    ) {
        let clamped = Slider.clamp(value, to: range)
        if clamped == Slider.defaultValue {
            values[name] = nil
        } else {
            values[name] = .number(clamped)
        }
    }

    public subscript(name: String) -> JSONValue? {
        get { values[name] }
        set { values[name] = newValue }
    }

    /// `self` with `other`'s keys written over it.
    public func merging(_ other: EditSection) -> EditSection {
        EditSection(values: values.merging(other.values) { _, new in new })
    }
}

extension EditSection: Codable {
    public init(from decoder: any Decoder) throws {
        values = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

/// Edits that are meaningful only for the image they were made on and must
/// **not** travel in a `Preset` — this is the "minus per-image fields" line from
/// docs/PLAN.md §2.
///
/// Nothing is declared yet on purpose. The owners land later: crop / straighten
/// (Phase 2 canvas), heal & clone strokes (Phase 5), per-face-instance bindings
/// when an image has several faces. What Phase 1 fixes is the *boundary*:
/// anything a future schema stores here is stripped when a `Preset` is made,
/// and anything stored outside here is assumed transferable between images.
public struct PerImageState: Hashable, Sendable {
    public var values: [String: JSONValue]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    public subscript(name: String) -> JSONValue? {
        get { values[name] }
        set { values[name] = newValue }
    }
}

extension PerImageState: Codable {
    public init(from decoder: any Decoder) throws {
        values = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

/// Everything the renderer needs to reproduce one shot's look, stored as one
/// JSON file per shot at `edits/<shot id>.json` inside the bundle.
///
/// Shape (Phase 1):
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "sections": { "skin": { "smooth": 40 }, "color": { "exposure": 12 } },
///   "perImage": { }
/// }
/// ```
///
/// The envelope is versioned and open: unknown top-level keys and unknown
/// section parameters survive a decode/encode round trip untouched, so an older
/// build cannot silently delete a newer build's edits.
public struct EditState: Hashable, Sendable {
    /// Schema of the *envelope*, not of the slider set. Bump only when the
    /// envelope's own shape changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Transferable adjustments, keyed by section name (see ``SectionKey``).
    public var sections: [String: EditSection]
    /// Adjustments bound to this specific image; stripped when making a preset.
    public var perImage: PerImageState
    /// Top-level keys written by a future schema version, preserved verbatim.
    public var additionalValues: [String: JSONValue]

    public init(
        schemaVersion: Int = EditState.currentSchemaVersion,
        sections: [String: EditSection] = [:],
        perImage: PerImageState = PerImageState(),
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sections = sections
        self.perImage = perImage
        self.additionalValues = additionalValues
    }

    /// `true` when the shot is untouched (all sliders at their default 0).
    public var isDefault: Bool {
        sections.values.allSatisfy(\.isEmpty) && perImage.isEmpty && additionalValues.isEmpty
    }

    /// Section names used by the render graph. The *parameters* inside each
    /// section are Phase 2's to define; only the namespaces are fixed here so
    /// presets can be filtered by group (docs/PLAN.md Phase 3).
    public enum SectionKey {
        /// "Da" — smoothing, texture, even tone, redness, shine, dark circles.
        public static let skin = "skin"
        /// "Mặt" — MLS reshape deltas, stored relative to face width.
        public static let face = "face"
        /// "Mắt / Răng" — eye brightening, sclera, teeth whitening.
        public static let eyesTeeth = "eyesTeeth"
        /// "Color" — exposure, contrast, WB, curves, HSL, D&B.
        public static let color = "color"
        /// Phase 5 makeup.
        public static let makeup = "makeup"
        /// Phase 5 hair.
        public static let hair = "hair"

        public static let all = [skin, face, eyesTeeth, color, makeup, hair]
    }

    public subscript(section name: String) -> EditSection {
        get { sections[name] ?? EditSection() }
        set {
            if newValue.isEmpty {
                sections[name] = nil
            } else {
                sections[name] = newValue
            }
        }
    }

    /// Reads one slider, e.g. `state.slider("smooth", in: EditState.SectionKey.skin)`.
    public func slider(_ name: String, in section: String) -> Double {
        sections[section]?.slider(name) ?? Slider.defaultValue
    }

    /// Writes one slider, creating the section on demand and dropping it again
    /// when it becomes empty.
    ///
    /// The clamping range comes from ``Slider/range(for:in:)``, so a "Color"
    /// slider takes −100…100 and every other group still takes 0…100.
    public mutating func setSlider(_ name: String, in section: String, to value: Double) {
        var edited = sections[section] ?? EditSection()
        edited.setSlider(name, to: value, range: Slider.range(for: name, in: section))
        self[section: section] = edited
    }
}

extension EditState: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, perImage
    }

    private static let knownKeys: Set<String> = ["schemaVersion", "sections", "perImage"]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? EditState.currentSchemaVersion
        sections = try container.decodeIfPresent([String: EditSection].self, forKey: .sections) ?? [:]
        perImage = try container.decodeIfPresent(PerImageState.self, forKey: .perImage)
            ?? PerImageState()
        additionalValues = try UnknownKeys.collect(from: decoder, known: EditState.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sections, forKey: .sections)
        if !perImage.isEmpty {
            try container.encode(perImage, forKey: .perImage)
        }
        try UnknownKeys.encode(additionalValues, to: encoder, known: EditState.knownKeys)
    }
}
