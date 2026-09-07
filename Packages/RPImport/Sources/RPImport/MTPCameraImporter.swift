import Foundation
import RPCore

/// Imports JPEG/ARW off a camera or card reader attached in MTP / mass-storage
/// mode (PLAN Phase 1 item 3, and PLAN §1.1: MTP import is the stand-in for
/// tethering until Phase 4 — it needs no vendor PTP command, so it works on
/// both macOS and iPadOS).
///
/// Never deletes anything on the camera. ``CameraSession`` has no delete method
/// to call, and the ImageCaptureCore implementation explicitly clears
/// `ICDownloadOptionDeleteAfterSuccessfulDownload`.
public struct MTPCameraImporter: Sendable {
    public var source: any CameraDeviceSource
    public var ingestor: ShotIngestor
    public var stagingDirectory: URL?
    /// How long to wait for device discovery before giving up.
    public var discoveryTimeout: Duration

    public init(
        source: any CameraDeviceSource,
        options: ImportOptions = .default,
        metadataExtractor: any CaptureMetadataExtracting = ImageIOMetadataExtractor(),
        stagingDirectory: URL? = nil,
        discoveryTimeout: Duration = .seconds(5)
    ) {
        self.source = source
        var options = options
        options.usesSecurityScopedAccess = false
        self.ingestor = ShotIngestor(options: options, metadataExtractor: metadataExtractor)
        self.stagingDirectory = stagingDirectory
        self.discoveryTimeout = discoveryTimeout
    }

    /// Cameras currently attached.
    public func availableCameras() async -> [CameraDeviceDescriptor] {
        await source.cameras(waitingFor: discoveryTimeout)
    }

    /// Files on `device`, without importing anything, so a UI can offer a
    /// selection. Opens and closes a session.
    public func listContents(of device: CameraDeviceDescriptor) async throws
        -> [CameraItemDescriptor]
    {
        let session = try await source.openSession(with: device)
        do {
            let items = try await session.contents()
            await session.close()
            return items
        } catch {
            // `defer` cannot `await`, and leaving the session open would hold
            // the camera against the next attempt, so the close is written out
            // on both paths.
            await session.close()
            throw error
        }
    }

    /// Imports files from `device`.
    ///
    /// - Parameter itemIDs: which files to take. `nil` means every importable
    ///   file on the device — with de-duplication on (the default), running
    ///   this twice on the same card is idempotent, which is the behaviour the
    ///   plan's "cắm → đổ vào project" workflow needs.
    @discardableResult
    public func importItems(
        from device: CameraDeviceDescriptor,
        itemIDs: [String]? = nil,
        into host: any ProjectMutating,
        fileManager: FileManager = .default,
        progress: (@Sendable (ImportItemResult, Int, Int) -> Void)? = nil
    ) async -> ImportReport {
        var report = await run(
            from: device, itemIDs: itemIDs, into: host, fileManager: fileManager,
            progress: progress)
        report.finishedAt = Date()
        return report
    }

    private func run(
        from device: CameraDeviceDescriptor,
        itemIDs: [String]?,
        into host: any ProjectMutating,
        fileManager: FileManager,
        progress: (@Sendable (ImportItemResult, Int, Int) -> Void)?
    ) async -> ImportReport {
        let startedAt = Date()
        var report = ImportReport(source: .camera, startedAt: startedAt, finishedAt: startedAt)

        func fail(_ failure: ImportFailure, name: String) {
            report.append(
                ImportItemResult(
                    source: .camera,
                    displayName: name,
                    sourceIdentifier: device.id,
                    outcome: .failed(failure)
                ))
        }

        let session: any CameraSession
        do {
            session = try await source.openSession(with: device)
        } catch {
            fail(.wrapping(error) { .sourceError($0) }, name: device.name)
            return report
        }

        let allItems: [CameraItemDescriptor]
        do {
            allItems = try await session.contents()
        } catch {
            fail(.wrapping(error) { .sourceError($0) }, name: device.name)
            await session.close()
            return report
        }

        var items = allItems
        if let itemIDs {
            let byID = Dictionary(
                allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            items = itemIDs.compactMap { byID[$0] }
            for missing in itemIDs where byID[missing] == nil {
                report.append(
                    ImportItemResult(
                        source: .camera,
                        displayName: missing,
                        sourceIdentifier: missing,
                        outcome: .failed(
                            .sourceUnavailable("\(missing) is not on \(device.name) any more"))
                    ))
            }
        }

        let staging = stagingDirectory ?? Self.defaultStagingDirectory()
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if stagingDirectory == nil { try? fileManager.removeItem(at: staging) } }

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                report.append(
                    ImportItemResult(
                        source: .camera,
                        displayName: item.name,
                        sourceIdentifier: item.id,
                        outcome: .skipped(.cancelled)
                    ))
                continue
            }
            let result = await importOne(
                item, session: session, staging: staging, into: host, fileManager: fileManager)
            report.append(result)
            progress?(result, index + 1, items.count)
        }

        // Always closed, on every path, before the report is returned: an
        // ImageCaptureCore session left open holds the camera against the next
        // attempt, and `defer` cannot `await`.
        await session.close()
        return report
    }

    private func importOne(
        _ item: CameraItemDescriptor,
        session: any CameraSession,
        staging: URL,
        into host: any ProjectMutating,
        fileManager: FileManager
    ) async -> ImportItemResult {
        func result(_ outcome: ImportOutcome) -> ImportItemResult {
            ImportItemResult(
                source: .camera,
                displayName: item.name,
                sourceIdentifier: item.id,
                outcome: outcome
            )
        }

        // Filter before downloading: pulling a 1 GB movie off the card only to
        // reject it by extension would waste minutes of USB time.
        guard ProjectBundle.isImportableExtension(item.pathExtension) else {
            return result(.skipped(.unsupportedFileType(pathExtension: item.pathExtension)))
        }

        let downloaded: URL
        do {
            downloaded = try await session.download(item, to: staging)
        } catch let error as CameraImportError {
            return result(.failed(.sourceError(error.description)))
        } catch {
            return result(.failed(.wrapping(error) { .sourceError($0) }))
        }
        // Only the staged copy is removed. Nothing on the camera is touched.
        defer { try? fileManager.removeItem(at: downloaded) }

        let ingestor = self.ingestor
        let name = item.name
        // A fresh `FileManager` inside the closure: `FileManager` is not
        // `Sendable` and must not be captured across the actor hop.
        var outcome = await host.withProject { project, store in
            ingestor.ingest(
                fileAt: downloaded,
                displayName: name,
                source: .camera,
                into: &project,
                using: store,
                fileManager: FileManager()
            )
        }
        outcome.sourceIdentifier = item.id
        outcome.displayName = name
        return outcome
    }

    static func defaultStagingDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RetouchPro-camera-\(UUID().uuidString)", isDirectory: true)
    }
}
