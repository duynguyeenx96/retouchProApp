import Foundation

/// A stable, phantom-typed string identifier.
///
/// Identifiers double as **file names** inside a `.rpproj` bundle
/// (`edits/<shot id>.json`, `presets/<preset id>.json`), so the raw value is
/// validated: it must be a safe single path component. That makes a malicious
/// or corrupt manifest unable to steer a write outside the bundle.
public struct Identifier<Tag: Sendable>: Sendable, Hashable, Codable,
    CustomStringConvertible, Comparable
{
    public let rawValue: String

    /// Fails when `rawValue` is not a safe file-name component.
    public init?(_ rawValue: String) {
        guard Identifier.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// A fresh random identifier (lowercased UUID).
    public static func generate() -> Identifier {
        Identifier(UUID().uuidString.lowercased())!
    }

    /// Allowed: 1–128 characters of `A–Z a–z 0–9 - _ .`, not starting with `.`,
    /// and not `.` or `..`. No slashes, no path traversal, no spaces.
    public static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 128 else { return false }
        guard candidate != ".", candidate != ".." else { return false }
        guard !candidate.hasPrefix(".") else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return candidate.allSatisfy { allowed.contains($0) }
    }

    public var description: String { rawValue }

    public static func < (lhs: Identifier, rhs: Identifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Identifier(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "\"\(raw)\" is not a valid identifier: it must be a safe file-name component."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ProjectIDTag: Sendable {}
public enum ShotIDTag: Sendable {}
public enum PresetIDTag: Sendable {}

public typealias ProjectID = Identifier<ProjectIDTag>
public typealias ShotID = Identifier<ShotIDTag>
public typealias PresetID = Identifier<PresetIDTag>
