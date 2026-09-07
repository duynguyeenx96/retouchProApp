import Foundation

/// Filmstrip flag (docs/PLAN.md Phase 1: "filmstrip (rating/flag)").
public enum ShotFlag: String, Codable, Sendable, CaseIterable {
    case unflagged
    case pick
    case reject
}

/// Capture information about a shot.
///
/// Every field is optional and nothing here parses EXIF yet — that belongs to
/// `RPImport` (Phase 1 item 3) and to `CIRAWFilter` for ARW. This type exists
/// now so the manifest has a stable place to put it, and so unknown EXIF-ish
/// keys written by a later importer survive a round trip.
public struct CaptureMetadata: Hashable, Sendable {
    public var capturedAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    public var shutterSpeedSeconds: Double?
    public var aperture: Double?
    public var focalLengthMillimetres: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// EXIF orientation, 1–8.
    public var orientation: Int?
    public var additionalValues: [String: JSONValue]

    public init(
        capturedAt: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lens: String? = nil,
        iso: Int? = nil,
        shutterSpeedSeconds: Double? = nil,
        aperture: Double? = nil,
        focalLengthMillimetres: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        orientation: Int? = nil,
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.capturedAt = capturedAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.shutterSpeedSeconds = shutterSpeedSeconds
        self.aperture = aperture
        self.focalLengthMillimetres = focalLengthMillimetres
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.additionalValues = additionalValues
    }

    public var isEmpty: Bool {
        capturedAt == nil && cameraMake == nil && cameraModel == nil && lens == nil && iso == nil
            && shutterSpeedSeconds == nil && aperture == nil && focalLengthMillimetres == nil
            && pixelWidth == nil && pixelHeight == nil && orientation == nil
            && additionalValues.isEmpty
    }
}

extension CaptureMetadata: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case capturedAt, cameraMake, cameraModel, lens, iso, shutterSpeedSeconds, aperture
        case focalLengthMillimetres, pixelWidth, pixelHeight, orientation
    }

    private static let knownKeys: Set<String> = Set(
        CodingKeys.allCases.map(\.rawValue)
    )

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        cameraMake = try container.decodeIfPresent(String.self, forKey: .cameraMake)
        cameraModel = try container.decodeIfPresent(String.self, forKey: .cameraModel)
        lens = try container.decodeIfPresent(String.self, forKey: .lens)
        iso = try container.decodeIfPresent(Int.self, forKey: .iso)
        shutterSpeedSeconds = try container.decodeIfPresent(
            Double.self, forKey: .shutterSpeedSeconds)
        aperture = try container.decodeIfPresent(Double.self, forKey: .aperture)
        focalLengthMillimetres = try container.decodeIfPresent(
            Double.self, forKey: .focalLengthMillimetres)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        orientation = try container.decodeIfPresent(Int.self, forKey: .orientation)
        additionalValues = try UnknownKeys.collect(
            from: decoder, known: CaptureMetadata.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(cameraMake, forKey: .cameraMake)
        try container.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try container.encodeIfPresent(lens, forKey: .lens)
        try container.encodeIfPresent(iso, forKey: .iso)
        try container.encodeIfPresent(shutterSpeedSeconds, forKey: .shutterSpeedSeconds)
        try container.encodeIfPresent(aperture, forKey: .aperture)
        try container.encodeIfPresent(focalLengthMillimetres, forKey: .focalLengthMillimetres)
        try container.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try container.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try container.encodeIfPresent(orientation, forKey: .orientation)
        try UnknownKeys.encode(
            additionalValues, to: encoder, known: CaptureMetadata.knownKeys)
    }
}

/// One imported image inside a project.
///
/// A `Shot` never owns pixels: it points at an immutable file under
/// `originals/` and at a JSON file under `edits/`. Rendering is
/// non-destructive, so removing a shot or changing its edits can never damage
/// the imported file.
public struct Shot: Identifiable, Hashable, Sendable {
    public let id: ShotID
    /// The file name as it was imported, e.g. `"DSC01234.ARW"`. Kept separate
    /// from the stored path so the UI and export naming templates can show the
    /// camera's name even after a collision rename.
    public var originalFileName: String
    /// Path of the imported file **relative to the bundle root**, e.g.
    /// `"originals/DSC01234.ARW"`. Files under `originals/` are immutable.
    public var originalRelativePath: String
    /// Cached preview, relative to the bundle root; `nil` until one is rendered.
    public var previewRelativePath: String?
    public var importedAt: Date
    public var capture: CaptureMetadata
    /// Filmstrip rating, 0–5. Assignments outside the range are clamped.
    public var rating: Int {
        didSet { rating = Swift.min(5, Swift.max(0, rating)) }
    }
    public var flag: ShotFlag
    /// Hook for content-addressed caching (docs/PLAN.md §2: FaceAnalysis
    /// "cache theo hash") and import de-duplication. Filled by `RPImport`.
    public var contentHash: String?
    public var additionalValues: [String: JSONValue]

    public init(
        id: ShotID = .generate(),
        originalFileName: String,
        originalRelativePath: String,
        previewRelativePath: String? = nil,
        importedAt: Date = Date(),
        capture: CaptureMetadata = CaptureMetadata(),
        rating: Int = 0,
        flag: ShotFlag = .unflagged,
        contentHash: String? = nil,
        additionalValues: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.originalFileName = originalFileName
        self.originalRelativePath = originalRelativePath
        self.previewRelativePath = previewRelativePath
        self.importedAt = importedAt
        self.capture = capture
        self.rating = Swift.min(5, Swift.max(0, rating))
        self.flag = flag
        self.contentHash = contentHash
        self.additionalValues = additionalValues
    }

    /// Where this shot's `EditState` lives, relative to the bundle root.
    /// Derived from the id, never stored, so it cannot go stale.
    public var editsRelativePath: String {
        "\(ProjectBundle.editsDirectory)/\(id.rawValue).json"
    }
}

extension Shot: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, originalFileName, originalRelativePath, previewRelativePath, importedAt
        case capture, rating, flag, contentHash
    }

    private static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ShotID.self, forKey: .id)
        originalFileName = try container.decode(String.self, forKey: .originalFileName)
        originalRelativePath = try container.decode(String.self, forKey: .originalRelativePath)
        previewRelativePath = try container.decodeIfPresent(
            String.self, forKey: .previewRelativePath)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        capture =
            try container.decodeIfPresent(CaptureMetadata.self, forKey: .capture)
            ?? CaptureMetadata()
        rating = Swift.min(5, Swift.max(0, try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0))
        flag = try container.decodeIfPresent(ShotFlag.self, forKey: .flag) ?? .unflagged
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        additionalValues = try UnknownKeys.collect(from: decoder, known: Shot.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(originalFileName, forKey: .originalFileName)
        try container.encode(originalRelativePath, forKey: .originalRelativePath)
        try container.encodeIfPresent(previewRelativePath, forKey: .previewRelativePath)
        try container.encode(importedAt, forKey: .importedAt)
        if !capture.isEmpty {
            try container.encode(capture, forKey: .capture)
        }
        try container.encode(rating, forKey: .rating)
        try container.encode(flag, forKey: .flag)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try UnknownKeys.encode(additionalValues, to: encoder, known: Shot.knownKeys)
    }
}
