import Foundation
import RPCore

@testable import RPImport

/// A throwaway directory that cleans itself up when the test's `defer` runs.
struct TempDirectory {
    let url: URL

    init(_ label: String = "rpimport") {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func writeFile(_ name: String, bytes: Data) throws -> URL {
        let destination = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        return destination
    }

    @discardableResult
    func writeFile(_ name: String, contents: String = "pixels") throws -> URL {
        try writeFile(name, bytes: Data(contents.utf8))
    }

    /// Appends to an existing file without rewriting it, which is what a slow
    /// card copy looks like from outside.
    func append(_ name: String, bytes: Data) throws {
        let destination = url.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }
}

/// A project bundle in a temp directory, with a real `ProjectStore`.
struct TestProject {
    let directory: TempDirectory
    let store: ProjectStore
    var project: Project

    init(name: String = "Shoot") throws {
        directory = TempDirectory("rpimport-project")
        let created = try ProjectStore.create(name: name, in: directory.url)
        store = created.store
        project = created.project
    }

    func remove() { directory.remove() }

    /// Re-reads the manifest from disk, so a test can assert that the file
    /// system agrees with the in-memory `Project`.
    func reload() throws -> ProjectStore.LoadResult {
        try store.load()
    }
}

/// Deterministic clock for the ``FolderWatcher`` stability rule: tests move
/// time by hand instead of sleeping.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// A `FileManager` that reports one file that is not really on disk.
///
/// It exists to reproduce exactly one thing: the window between
/// ``FolderWatcher``'s `stat` and `ShotIngestor`'s re-check, where a file the
/// scan just saw has already gone away. Both sides use a real file system, so
/// without this the race cannot be driven deterministically.
///
/// The haunting stops by itself once a real file exists at the ghost's path,
/// so a test can let "the copy finally finished" happen simply by writing the
/// file — no mutable state to poke at from outside the actor that owns this.
final class GhostFileManager: FileManager, @unchecked Sendable {
    /// The file that appears in directory listings and stats but cannot be read.
    let ghost: URL

    init(ghost: URL) {
        self.ghost = ghost
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isHaunting: Bool { !super.fileExists(atPath: ghost.path) }

    private var ghostParent: String {
        ghost.deletingLastPathComponent().standardizedFileURL.path
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        var contents = try super.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: mask)
        if isHaunting, url.standardizedFileURL.path == ghostParent,
            !contents.contains(where: { $0.lastPathComponent == ghost.lastPathComponent })
        {
            contents.append(ghost)
        }
        return contents
    }

    override func fileExists(
        atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?
    ) -> Bool {
        if isHaunting, path == ghost.path {
            isDirectory?.pointee = false
            return true
        }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if isHaunting, path == ghost.path {
            return [
                .size: NSNumber(value: 4096),
                .modificationDate: Date(timeIntervalSince1970: 1_800_000_000),
            ]
        }
        return try super.attributesOfItem(atPath: path)
    }
}

// MARK: - Fake Photos library

/// A ``PhotoLibrarySource`` backed by files in a temp directory.
///
/// The point of the fake is not to imitate PhotoKit — it is to let the tests
/// assert what ``PhotosImporter`` does with whatever PhotoKit returns: that the
/// exported file lands in `originals/`, that the asset's own file name (not the
/// staging temp name) is what the manifest records, and that a failing export
/// produces a failure line rather than an exception.
final class FakePhotoLibrary: PhotoLibrarySource, @unchecked Sendable {
    struct Entry {
        var descriptor: PhotoAssetDescriptor
        var bytes: Data
        var exportError: PhotoLibraryError?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    var status: PhotoAuthorization
    private(set) var requestAuthorizationCallCount = 0
    private(set) var exportedAssetIDs: [String] = []

    init(status: PhotoAuthorization = .authorized) {
        self.status = status
    }

    func add(
        id: String,
        fileName: String,
        bytes: Data = Data("raw-bytes".utf8),
        creationDate: Date? = nil,
        hasRAWResource: Bool = false,
        exportError: PhotoLibraryError? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = Entry(
            descriptor: PhotoAssetDescriptor(
                id: id,
                originalFileName: fileName,
                creationDate: creationDate,
                pixelWidth: 6000,
                pixelHeight: 4000,
                hasRAWResource: hasRAWResource
            ),
            bytes: bytes,
            exportError: exportError
        )
        order.append(id)
    }

    func authorizationStatus() async -> PhotoAuthorization {
        lock.withLock { status }
    }

    func requestAuthorization() async -> PhotoAuthorization {
        lock.withLock {
            requestAuthorizationCallCount += 1
            return status
        }
    }

    func assets(withLocalIdentifiers identifiers: [String]) async throws -> [PhotoAssetDescriptor] {
        lock.withLock { identifiers.compactMap { entries[$0]?.descriptor } }
    }

    func exportOriginal(_ asset: PhotoAssetDescriptor, to directory: URL) async throws -> URL {
        let entry = lock.withLock { () -> Entry? in
            exportedAssetIDs.append(asset.id)
            return entries[asset.id]
        }

        guard let entry else { throw PhotoLibraryError.assetNotFound(asset.id) }
        if let error = entry.exportError { throw error }

        // Mirror the real source: a per-export subdirectory, and a *machine*
        // file name is deliberately NOT used — PhotoKit writes the resource's
        // own name, and the importer must not depend on that either way.
        let destination =
            directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(entry.descriptor.originalFileName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try entry.bytes.write(to: destination)
        return destination
    }
}

// MARK: - Fake camera

/// A ``CameraDeviceSource`` backed by files in a temp directory.
final class FakeCameraSource: CameraDeviceSource, @unchecked Sendable {
    let device: CameraDeviceDescriptor
    let session: FakeCameraSession
    private let lock = NSLock()
    private var openError: (any Error)?

    init(
        device: CameraDeviceDescriptor = CameraDeviceDescriptor(
            id: "cam-1", name: "ILCE-6300", manufacturer: "Sony"),
        session: FakeCameraSession,
        openError: (any Error)? = nil
    ) {
        self.device = device
        self.session = session
        self.openError = openError
    }

    func cameras(waitingFor timeout: Duration) async -> [CameraDeviceDescriptor] { [device] }

    func openSession(with device: CameraDeviceDescriptor) async throws -> any CameraSession {
        if let openError { throw openError }
        guard device.id == self.device.id else {
            throw CameraImportError.deviceNotFound(device.id)
        }
        return session
    }
}

final class FakeCameraSession: CameraSession, @unchecked Sendable {
    struct File {
        var descriptor: CameraItemDescriptor
        var bytes: Data
        var downloadError: (any Error)?
    }

    let device: CameraDeviceDescriptor
    private let lock = NSLock()
    private var files: [File] = []
    private var contentsError: (any Error)?
    private(set) var downloadedItemIDs: [String] = []
    private(set) var closeCount = 0
    /// Proof that nothing deletes: the fake has no delete API at all, and this
    /// counter exists so a test can assert the file list is unchanged.
    private(set) var contentsCallCount = 0

    init(
        device: CameraDeviceDescriptor = CameraDeviceDescriptor(
            id: "cam-1", name: "ILCE-6300", manufacturer: "Sony"),
        contentsError: (any Error)? = nil
    ) {
        self.device = device
        self.contentsError = contentsError
    }

    func add(
        name: String,
        folder: String = "100MSDCF",
        bytes: Data = Data("camera-bytes".utf8),
        downloadError: (any Error)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        files.append(
            File(
                descriptor: CameraItemDescriptor(
                    id: "\(folder)/\(name)",
                    name: name,
                    byteSize: Int64(bytes.count),
                    creationDate: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                bytes: bytes,
                downloadError: downloadError
            ))
    }

    var remainingFileNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return files.map(\.descriptor.name)
    }

    func contents() async throws -> [CameraItemDescriptor] {
        let (error, snapshot) = lock.withLock {
            contentsCallCount += 1
            return (contentsError, files.map(\.descriptor))
        }
        if let error { throw error }
        return snapshot
    }

    func download(_ item: CameraItemDescriptor, to directory: URL) async throws -> URL {
        let file = lock.withLock { () -> File? in
            downloadedItemIDs.append(item.id)
            return files.first { $0.descriptor.id == item.id }
        }

        guard let file else {
            throw CameraImportError.downloadFailed(item: item.name, message: "not on the camera")
        }
        if let error = file.downloadError { throw error }

        let destination =
            directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.bytes.write(to: destination)
        return destination
    }

    func close() async {
        lock.withLock { closeCount += 1 }
    }
}
