import Foundation
import RPCore

/// Photo library access state, mirroring `PHAuthorizationStatus` without
/// dragging PhotoKit into code that only wants to branch on it.
public enum PhotoAuthorization: String, Sendable, Hashable, Codable {
    case notDetermined
    case restricted
    case denied
    /// Full library access.
    case authorized
    /// The user picked a subset of photos (iOS 14+ limited library).
    case limited

    public var allowsReading: Bool { self == .authorized || self == .limited }
}

/// One asset in the Photos library, flattened to plain values.
public struct PhotoAssetDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// `PHAsset.localIdentifier`.
    public let id: String
    /// The file name of the resource that will actually be exported, e.g.
    /// `"IMG_0042.DNG"`. Used as `Shot.originalFileName`.
    public var originalFileName: String
    public var creationDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// True when the asset has a RAW resource, so the import will be RAW.
    public var hasRAWResource: Bool
    /// UTI of the resource that will be exported, e.g. `"com.adobe.raw-image"`.
    public var uniformTypeIdentifier: String?
    /// Byte size when known; `nil` for an asset still in iCloud.
    public var byteSize: Int64?

    public init(
        id: String,
        originalFileName: String,
        creationDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        hasRAWResource: Bool = false,
        uniformTypeIdentifier: String? = nil,
        byteSize: Int64? = nil
    ) {
        self.id = id
        self.originalFileName = originalFileName
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasRAWResource = hasRAWResource
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteSize = byteSize
    }
}

/// The Photos library, as much of it as importing needs.
///
/// A protocol because the real thing cannot be exercised by a unit test: it
/// needs a signed app bundle, an `NSPhotoLibraryUsageDescription`, a user
/// tapping "Allow", and assets in the library. The wiring between "the library
/// produced a file" and "the file is a shot in the project" is the part that
/// can break silently, so that part is tested against a fake and the platform
/// half is kept as thin as possible (see ``PhotoKitLibrarySource``).
public protocol PhotoLibrarySource: Sendable {
    func authorizationStatus() async -> PhotoAuthorization
    /// Prompts if undetermined; returns the resulting status.
    func requestAuthorization() async -> PhotoAuthorization

    /// Assets the user selected, or the whole library, newest last.
    func assets(withLocalIdentifiers identifiers: [String]) async throws -> [PhotoAssetDescriptor]

    /// Writes the asset's **original** bytes into `directory` and returns the
    /// file URL.
    ///
    /// Contract every implementation must keep, because it is what "giữ RAW"
    /// in PLAN Phase 1 means: the bytes written are the resource as stored, not
    /// a re-encode and not a rendered JPEG. When the asset has both a RAW and a
    /// JPEG resource, the RAW is the one written.
    func exportOriginal(
        _ asset: PhotoAssetDescriptor,
        to directory: URL
    ) async throws -> URL
}

/// Errors an implementation of ``PhotoLibrarySource`` may throw. Importers
/// translate these into ``ImportFailure`` values.
public enum PhotoLibraryError: Error, Hashable, Sendable, CustomStringConvertible {
    case notAuthorized(PhotoAuthorization)
    case assetNotFound(String)
    case noExportableResource(String)
    case exportFailed(String)
    case unavailableOnThisPlatform

    public var description: String {
        switch self {
        case .notAuthorized(let status):
            "Photos access is \(status.rawValue)."
        case .assetNotFound(let id):
            "No asset \(id) in the library."
        case .noExportableResource(let id):
            "Asset \(id) has no resource that can be exported."
        case .exportFailed(let message):
            message
        case .unavailableOnThisPlatform:
            "The Photos library is not available on this platform."
        }
    }
}
