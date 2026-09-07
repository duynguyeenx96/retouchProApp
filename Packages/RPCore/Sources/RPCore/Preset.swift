import Foundation

/// A named, reusable look: **`EditState` minus the per-image fields**
/// (docs/PLAN.md §2).
///
/// It is safe to move between images because of what it is allowed to contain:
/// reshape deltas are relative to face width and skin/makeup parameters are
/// mask-driven, so nothing in a preset refers to pixel coordinates of the image
/// it was captured from. Everything that *would* refer to one image lives in
/// ``EditState/perImage``, which is dropped here.
///
/// Stored as one JSON file per preset at `presets/<preset id>.json`.
public struct Preset: Identifiable, Hashable, Sendable {
    /// Schema of the preset envelope. Tracks ``EditState/currentSchemaVersion``.
    public static let currentSchemaVersion = 1

    public let id: PresetID
    public var name: String
    /// Optional grouping for the preset browser ("Da", "Mặt", "Color"…),
    /// Phase 3. `nil` means the preset covers everything it carries.
    public var group: String?
    public var createdAt: Date
    public var schemaVersion: Int
    /// Same namespaces as ``EditState/sections``.
    public var sections: [String: EditSection]
    /// Top-level keys from a future schema, preserved verbatim.
    public var additionalValues: [String: JSONValue]

    public init(
        id: PresetID = .generate(),
        name: String,
        group: String? = nil,
        createdAt: Date = Date(),
        schemaVersion: Int = Preset.currentSchemaVersion,
        sections: [String: EditSection] = [:],
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.sections = sections
        self.additionalValues = additionalValues
    }

    /// Captures a shot's look as a preset.
    ///
    /// `EditState.perImage` is dropped. Unknown top-level keys are carried over,
    /// which is the reason `perImage` exists as a declared namespace: a future
    /// schema that adds image-bound data **must** put it under `perImage`, or it
    /// will leak into presets.
    ///
    /// `sections` may be limited to a subset of namespaces (Phase 3's "preset
    /// theo nhóm"); `nil` keeps all of them.
    public init(
        id: PresetID = .generate(),
        name: String,
        group: String? = nil,
        createdAt: Date = Date(),
        from editState: EditState,
        limitedTo sectionNames: Set<String>? = nil
    ) {
        let kept: [String: EditSection] =
            if let sectionNames {
                editState.sections.filter { sectionNames.contains($0.key) }
            } else {
                editState.sections
            }
        self.init(
            id: id,
            name: name,
            group: group,
            createdAt: createdAt,
            schemaVersion: editState.schemaVersion,
            sections: kept.filter { !$0.value.isEmpty },
            additionalValues: editState.additionalValues
        )
    }

    public var isEmpty: Bool {
        sections.values.allSatisfy(\.isEmpty) && additionalValues.isEmpty
    }
}

/// How a preset combines with the edits already on a shot.
public enum PresetApplyMode: String, Sendable, CaseIterable, Codable {
    /// The preset defines the whole look: sections not in the preset are reset.
    case replace
    /// Only the sections/parameters the preset carries are written; anything
    /// else the user already set stays. Used by grouped presets.
    case merge
}

extension EditState {
    /// Returns this state with `preset` applied. ``perImage`` is never touched —
    /// applying a preset must not move a crop or replay someone else's heal
    /// strokes.
    public func applying(_ preset: Preset, mode: PresetApplyMode = .replace) -> EditState {
        var result = self
        switch mode {
        case .replace:
            result.sections = preset.sections
        case .merge:
            for (name, section) in preset.sections {
                result[section: name] = result[section: name].merging(section)
            }
        }
        result.additionalValues = additionalValues.merging(preset.additionalValues) { _, new in new }
        result.schemaVersion = Swift.max(schemaVersion, preset.schemaVersion)
        return result
    }
}

extension Preset: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, group, createdAt, schemaVersion, sections
    }

    private static let knownKeys: Set<String> = [
        "id", "name", "group", "createdAt", "schemaVersion", "sections",
    ]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PresetID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Preset.currentSchemaVersion
        sections = try container.decodeIfPresent([String: EditSection].self, forKey: .sections) ?? [:]
        additionalValues = try UnknownKeys.collect(from: decoder, known: Preset.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sections, forKey: .sections)
        try UnknownKeys.encode(additionalValues, to: encoder, known: Preset.knownKeys)
    }
}
