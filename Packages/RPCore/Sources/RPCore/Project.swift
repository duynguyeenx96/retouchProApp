import Foundation

/// One shoot / session: an ordered list of shots plus the project-level preset
/// settings. This is the in-memory value; `ProjectStore` persists it as the
/// `manifest.json` of a `.rpproj` bundle.
public struct Project: Identifiable, Hashable, Sendable {
    public let id: ProjectID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Filmstrip order. The array order *is* the display order.
    public var shots: [Shot]
    /// Project-level preset library reference: the preset applied automatically
    /// to every newly imported shot (docs/PLAN.md Phase 3, "auto-apply mọi ảnh
    /// mới"). The presets themselves live in `presets/` inside the bundle;
    /// `ProjectStore.listPresets()` enumerates them.
    public var autoApplyPresetID: PresetID?
    /// Order the preset browser should show `presets/` in. Ids missing from
    /// this list are appended by name; ids that no longer exist are ignored.
    public var presetOrder: [PresetID]
    /// Tombstones: paths under `originals/` whose shot the user removed.
    ///
    /// Removing a shot never deletes the imported file (originals are
    /// immutable), so without this list the next load would re-adopt the
    /// orphaned file and the shot would come back.
    public var removedOriginalPaths: [String]
    /// Top-level manifest keys from a future schema, preserved verbatim.
    public var additionalValues: [String: JSONValue]

    public init(
        id: ProjectID = .generate(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        shots: [Shot] = [],
        autoApplyPresetID: PresetID? = nil,
        presetOrder: [PresetID] = [],
        removedOriginalPaths: [String] = [],
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.shots = shots
        self.autoApplyPresetID = autoApplyPresetID
        self.presetOrder = presetOrder
        self.removedOriginalPaths = removedOriginalPaths
        self.additionalValues = additionalValues
    }

    public func shot(id: ShotID) -> Shot? {
        shots.first { $0.id == id }
    }

    public func index(of id: ShotID) -> Int? {
        shots.firstIndex { $0.id == id }
    }

    /// Applies `transform` to one shot in place. Returns `false` when the shot
    /// is not in the project.
    @discardableResult
    public mutating func updateShot(id: ShotID, _ transform: (inout Shot) -> Void) -> Bool {
        guard let index = index(of: id) else { return false }
        transform(&shots[index])
        return true
    }

    /// Relative paths under `originals/` that the manifest currently claims.
    public var referencedOriginalPaths: Set<String> {
        Set(shots.map(\.originalRelativePath))
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, createdAt, modifiedAt, shots, autoApplyPresetID, presetOrder
        case removedOriginalPaths
    }

    private static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        autoApplyPresetID = try container.decodeIfPresent(
            PresetID.self, forKey: .autoApplyPresetID)
        presetOrder = try container.decodeIfPresent([PresetID].self, forKey: .presetOrder) ?? []
        removedOriginalPaths =
            try container.decodeIfPresent([String].self, forKey: .removedOriginalPaths) ?? []
        additionalValues = try UnknownKeys.collect(from: decoder, known: Project.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(shots, forKey: .shots)
        try container.encodeIfPresent(autoApplyPresetID, forKey: .autoApplyPresetID)
        if !presetOrder.isEmpty {
            try container.encode(presetOrder, forKey: .presetOrder)
        }
        if !removedOriginalPaths.isEmpty {
            try container.encode(removedOriginalPaths.sorted(), forKey: .removedOriginalPaths)
        }
        try UnknownKeys.encode(additionalValues, to: encoder, known: Project.knownKeys)
    }
}

/// The root document of a `.rpproj` bundle, `manifest.json`.
///
/// Wrapping `Project` in an envelope keeps two version numbers apart:
/// `formatVersion` is about the *bundle layout* (where files live, what the
/// manifest looks like); `EditState.schemaVersion` is about the *contents* of
/// an edit document. They move for different reasons.
public struct ProjectManifest: Hashable, Sendable {
    /// Bump when the on-disk layout changes in a way old builds cannot read.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Free-form "who wrote this", useful when a bundle turns up in a bug report.
    public var generator: String
    public var project: Project
    public var additionalValues: [String: JSONValue]

    public init(
        formatVersion: Int = ProjectManifest.currentFormatVersion,
        generator: String = ProjectManifest.defaultGenerator,
        project: Project,
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.formatVersion = formatVersion
        self.generator = generator
        self.project = project
        self.additionalValues = additionalValues
    }

    public static var defaultGenerator: String {
        "RetouchPro/\(RPCoreModule.info.name) \(RPCoreModule.info.version)"
    }
}

extension ProjectManifest: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion, generator, project
    }

    private static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        generator = try container.decodeIfPresent(String.self, forKey: .generator) ?? ""
        project = try container.decode(Project.self, forKey: .project)
        additionalValues = try UnknownKeys.collect(from: decoder, known: ProjectManifest.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(generator, forKey: .generator)
        try container.encode(project, forKey: .project)
        try UnknownKeys.encode(additionalValues, to: encoder, known: ProjectManifest.knownKeys)
    }
}
