import Foundation
import RPCore

/// Imports assets from the system Photos library into a project, keeping RAW
/// (PLAN Phase 1 item 3: "Photos (giữ RAW)").
///
/// The route is deliberately indirect: export the asset's original resource to
/// a staging directory, then hand that file to
/// `ProjectStore.addShot(copyingOriginalAt:)`. It costs one extra copy, and it
/// buys the guarantee ADR-0002 asks for — RPImport never writes into
/// `originals/` itself, so the orphan-adoption seam stays in RPCore, and a
/// crash mid-import leaves either a clean project or an orphan that `load()`
/// picks up.
public struct PhotosImporter: Sendable {
    public var library: any PhotoLibrarySource
    public var ingestor: ShotIngestor
    /// Where assets are staged before being copied into the bundle. Defaults to
    /// a fresh subdirectory of the temp directory per run.
    public var stagingDirectory: URL?

    public init(
        library: any PhotoLibrarySource,
        options: ImportOptions = .default,
        metadataExtractor: any CaptureMetadataExtracting = ImageIOMetadataExtractor(),
        stagingDirectory: URL? = nil
    ) {
        self.library = library
        // Photos hands us a file we just wrote, so there is nothing
        // security-scoped about it.
        var options = options
        options.usesSecurityScopedAccess = false
        self.ingestor = ShotIngestor(options: options, metadataExtractor: metadataExtractor)
        self.stagingDirectory = stagingDirectory
    }

    /// Asks for access if it has not been asked for yet.
    ///
    /// Split out from ``importAssets`` so a UI can decide *when* the system
    /// prompt appears rather than having it fire in the middle of a batch.
    @discardableResult
    public func ensureAuthorization() async -> PhotoAuthorization {
        let status = await library.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await library.requestAuthorization()
    }

    /// Imports the assets with the given `PHAsset.localIdentifier`s.
    ///
    /// Identifiers, not `PHAsset`s, because that is what `PHPickerViewController`
    /// returns and it keeps this signature free of PhotoKit.
    @discardableResult
    public func importAssets(
        withLocalIdentifiers identifiers: [String],
        into host: any ProjectMutating,
        fileManager: FileManager = .default,
        progress: (@Sendable (ImportItemResult, Int, Int) -> Void)? = nil
    ) async -> ImportReport {
        let startedAt = Date()
        var report = ImportReport(source: .photos, startedAt: startedAt, finishedAt: startedAt)

        let status = await library.authorizationStatus()
        guard status.allowsReading else {
            for identifier in identifiers {
                report.append(
                    ImportItemResult(
                        source: .photos,
                        displayName: identifier,
                        sourceIdentifier: identifier,
                        outcome: .failed(
                            .permissionDenied(PhotoLibraryError.notAuthorized(status).description))
                    ))
            }
            report.finishedAt = Date()
            return report
        }

        let assets: [PhotoAssetDescriptor]
        do {
            assets = try await library.assets(withLocalIdentifiers: identifiers)
        } catch {
            for identifier in identifiers {
                report.append(
                    ImportItemResult(
                        source: .photos,
                        displayName: identifier,
                        sourceIdentifier: identifier,
                        outcome: .failed(.wrapping(error) { .sourceError($0) })
                    ))
            }
            report.finishedAt = Date()
            return report
        }

        // An identifier the library did not return is a real failure — the user
        // asked for a photo and did not get it — so report it rather than
        // shrinking the list silently.
        let returned = Set(assets.map(\.id))
        for identifier in identifiers where !returned.contains(identifier) {
            report.append(
                ImportItemResult(
                    source: .photos,
                    displayName: identifier,
                    sourceIdentifier: identifier,
                    outcome: .failed(
                        .sourceUnavailable(PhotoLibraryError.assetNotFound(identifier).description))
                ))
        }

        let staging = stagingDirectory ?? Self.defaultStagingDirectory()
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if stagingDirectory == nil { try? fileManager.removeItem(at: staging) } }

        for (index, asset) in assets.enumerated() {
            let item = await importOne(
                asset, staging: staging, into: host, fileManager: fileManager)
            report.append(item)
            progress?(item, index + 1, assets.count)
        }

        report.finishedAt = Date()
        return report
    }

    private func importOne(
        _ asset: PhotoAssetDescriptor,
        staging: URL,
        into host: any ProjectMutating,
        fileManager: FileManager
    ) async -> ImportItemResult {
        func result(_ outcome: ImportOutcome) -> ImportItemResult {
            ImportItemResult(
                source: .photos,
                displayName: asset.originalFileName,
                sourceIdentifier: asset.id,
                outcome: outcome
            )
        }

        let exported: URL
        do {
            exported = try await library.exportOriginal(asset, to: staging)
        } catch let error as PhotoLibraryError {
            return result(.failed(.sourceError(error.description)))
        } catch {
            return result(.failed(.wrapping(error) { .sourceError($0) }))
        }
        // The staged copy is ours; remove it whatever happens next. The
        // library's own asset is never touched.
        defer { try? fileManager.removeItem(at: exported) }

        let ingestor = self.ingestor
        let fileName = asset.originalFileName
        // A fresh `FileManager` inside the closure, not the captured one:
        // `FileManager` is not `Sendable`, and Apple's own guidance is one
        // instance per thread. It is a thin wrapper; creating it is free.
        var item = await host.withProject { project, store in
            ingestor.ingest(
                fileAt: exported,
                displayName: fileName,
                source: .photos,
                into: &project,
                using: store,
                fileManager: FileManager()
            )
        }
        // Keep the report keyed by the asset identifier, not by the staging
        // path, so a caller can correlate it back to what the picker returned.
        item.sourceIdentifier = asset.id
        item.displayName = fileName

        // Photos knows the capture date even when the exported resource's EXIF
        // does not (screenshots, edited assets), so fill the gap.
        if case .imported(let shotID, _) = item.outcome, let creationDate = asset.creationDate {
            let width = asset.pixelWidth
            let height = asset.pixelHeight
            await host.withProject { project, store in
                var didChange = false
                project.updateShot(id: shotID) { shot in
                    if shot.capture.capturedAt == nil {
                        shot.capture.capturedAt = creationDate
                        didChange = true
                    }
                    if shot.capture.pixelWidth == nil, let width {
                        shot.capture.pixelWidth = width
                        didChange = true
                    }
                    if shot.capture.pixelHeight == nil, let height {
                        shot.capture.pixelHeight = height
                        didChange = true
                    }
                }
                if didChange { try? store.save(project) }
            }
        }
        return item
    }

    static func defaultStagingDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RetouchPro-photos-\(UUID().uuidString)", isDirectory: true)
    }
}
