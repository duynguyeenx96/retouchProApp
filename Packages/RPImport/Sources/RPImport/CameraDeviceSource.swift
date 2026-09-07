import Foundation
import RPCore

/// A camera or card reader visible to ImageCaptureCore.
public struct CameraDeviceDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// `ICDevice.uuidString` when there is one, otherwise the persistent id.
    public let id: String
    /// `"ILCE-6300"` — what the user sees.
    public var name: String
    /// `"Sony"` when the device reports it.
    public var manufacturer: String?
    /// The device is a mass-storage volume (card reader) rather than a camera.
    public var isMassStorage: Bool

    public init(
        id: String,
        name: String,
        manufacturer: String? = nil,
        isMassStorage: Bool = false
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isMassStorage = isMassStorage
    }
}

/// One file on the camera.
public struct CameraItemDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// Path-ish identity within the device, e.g. `"100MSDCF/DSC01234.ARW"`.
    /// Unique per device and stable for the life of a session.
    public let id: String
    public var name: String
    public var byteSize: Int64?
    public var creationDate: Date?
    public var uniformTypeIdentifier: String?

    public init(
        id: String,
        name: String,
        byteSize: Int64? = nil,
        creationDate: Date? = nil,
        uniformTypeIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.byteSize = byteSize
        self.creationDate = creationDate
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }

    public var pathExtension: String { (name as NSString).pathExtension }
}

/// An open session with one camera.
///
/// **Read-only by construction.** There is no delete, no rename, no format.
/// PLAN Phase 4 states the rule for tethering ("không xoá gì trên máy") and it
/// applies just as much to MTP import: the card is often the only copy of the
/// shoot until export finishes. Anything that would need to erase the camera
/// has to be a new protocol method, added deliberately.
public protocol CameraSession: Sendable {
    var device: CameraDeviceDescriptor { get }
    /// Every media file on the device, in the device's own order.
    func contents() async throws -> [CameraItemDescriptor]
    /// Downloads `item` into `directory` and returns the written file URL.
    /// Must not modify or delete anything on the device.
    func download(_ item: CameraItemDescriptor, to directory: URL) async throws -> URL
    func close() async
}

/// Discovery of cameras. A protocol for the same reason as
/// ``PhotoLibrarySource``: the real implementation needs an a6300 on the end of
/// a cable, which no unit test has.
public protocol CameraDeviceSource: Sendable {
    /// Devices found within `timeout`. ImageCaptureCore discovery is
    /// asynchronous and has no "done" signal, so a deadline is part of the API
    /// rather than a detail.
    func cameras(waitingFor timeout: Duration) async -> [CameraDeviceDescriptor]
    func openSession(with device: CameraDeviceDescriptor) async throws -> any CameraSession
}

public enum CameraImportError: Error, Hashable, Sendable, CustomStringConvertible {
    case noCameraFound
    case deviceNotFound(String)
    case sessionFailed(String)
    case enumerationFailed(String)
    case downloadFailed(item: String, message: String)
    case unavailableOnThisPlatform

    public var description: String {
        switch self {
        case .noCameraFound:
            "No camera is connected. Set the camera's USB mode to Mass Storage / MTP and plug it in."
        case .deviceNotFound(let id):
            "Camera \(id) is no longer connected."
        case .sessionFailed(let message):
            "Could not open a session with the camera: \(message)"
        case .enumerationFailed(let message):
            "Could not list the camera's files: \(message)"
        case .downloadFailed(let item, let message):
            "\(item): \(message)"
        case .unavailableOnThisPlatform:
            "Camera import is not available on this platform."
        }
    }
}
