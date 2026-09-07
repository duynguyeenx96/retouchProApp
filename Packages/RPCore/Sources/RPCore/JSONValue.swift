import Foundation

/// A decoded JSON value.
///
/// This exists for one reason: **forward compatibility**. `EditState` and
/// `Preset` are long-lived documents on the user's disk. A build that predates
/// a slider group must be able to open a document written by a build that has
/// it, edit something else, save, and *not* destroy the fields it did not
/// understand. Swift's synthesised `Codable` ignores unknown keys on decode and
/// then silently drops them on encode; `JSONValue` lets us keep them verbatim.
///
/// `.int` and `.double` are separate cases so a value larger than 2^53 keeps its
/// precision. JSON itself has only one number type, so the two cases compare and
/// hash as equal when they hold the same number: `40` written by the encoder
/// comes back as `.int(40)` even if it was stored as `.double(40)`, and a
/// document must not be considered changed because of that.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Hashable {
    /// Numbers compare by value across `.int` / `.double`; everything else
    /// compares structurally.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case (.bool(let a), .bool(let b)):
            a == b
        case (.int(let a), .int(let b)):
            a == b
        case (.double(let a), .double(let b)):
            a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)):
            Double(a) == b
        case (.string(let a), .string(let b)):
            a == b
        case (.array(let a), .array(let b)):
            a == b
        case (.object(let a), .object(let b)):
            a == b
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .int(let value):
            // Must match `.double`'s hash for equal numbers.
            hasher.combine(2)
            hasher.combine(Double(value))
        case .double(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .array(let value):
            hasher.combine(4)
            hasher.combine(value)
        case .object(let value):
            hasher.combine(5)
            hasher.combine(value)
        }
    }
}

extension JSONValue {
    /// A number, stored as `.int` when it is integral so the in-memory value
    /// matches what a reload produces and debug output stays readable.
    public static func number(_ value: Double) -> JSONValue {
        if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return .int(Int(value))
        }
        return .double(value)
    }

    /// Numeric payload of `.int` / `.double`, `nil` for every other case.
    public var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// A `CodingKey` for any string, so a decoder can enumerate keys it was not
/// compiled to know about.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Decode/encode support for keys a type does not declare.
///
/// Every persisted RPCore type follows the same recipe: decode its own fields
/// with its own `CodingKeys`, then call ``collect(from:known:)`` to sweep up the
/// rest, and on encode write its own fields then call ``encode(_:to:known:)``.
enum UnknownKeys {
    /// All top-level keys of `decoder`'s keyed container that are not in `known`.
    static func collect(from decoder: any Decoder, known: Set<String>) throws -> [String: JSONValue]
    {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }

    /// Writes `extras` back out, skipping anything that collides with a declared
    /// key (a declared key always wins, so stale data can never shadow a real field).
    static func encode(
        _ extras: [String: JSONValue],
        to encoder: any Encoder,
        known: Set<String>
    ) throws {
        guard !extras.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for key in extras.keys.sorted() where !known.contains(key) {
            try container.encode(extras[key]!, forKey: AnyCodingKey(key))
        }
    }
}
