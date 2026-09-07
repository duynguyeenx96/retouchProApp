import Foundation
import RPCore

/// Imports files the user picked in a file picker or dropped on the window
/// (PLAN Phase 1 item 3: "Import: Files … drag-drop Mac").
///
/// Synchronous on purpose. The caller — a document picker callback or a drop
/// handler — already knows whether it is on the main actor and whether it wants
/// to hop off it; a copy of a 24 MP ARW is I/O, not CPU, and wrapping it in an
/// executor here would just hide the decision. `FilesImporter` is `Sendable`,
/// so `Task.detached { importer.importFiles(…) }` is the one-liner for the UI.
public struct FilesImporter: Sendable {
    public var ingestor: ShotIngestor

    public init(
        options: ImportOptions = .default,
        metadataExtractor: any CaptureMetadataExtracting = ImageIOMetadataExtractor()
    ) {
        self.ingestor = ShotIngestor(options: options, metadataExtractor: metadataExtractor)
    }

    public init(ingestor: ShotIngestor) {
        self.ingestor = ingestor
    }

    public var options: ImportOptions { ingestor.options }

    /// Copies each file into `project`'s bundle and registers it.
    ///
    /// Never throws and never stops early: every input produces exactly one
    /// ``ImportItemResult``, so the caller can show precisely which of 400
    /// files did not make it and why. RAW files are copied verbatim — there is
    /// no decode step anywhere in this path.
    ///
    /// `project` is `inout` and is left consistent with the manifest on disk
    /// after every successful item, because `ProjectStore.addShot` saves.
    /// If the run is interrupted, the shots imported so far are already
    /// persisted.
    @discardableResult
    public func importFiles(
        at urls: [URL],
        into project: inout Project,
        using store: ProjectStore,
        fileManager: FileManager = .default,
        progress: (@Sendable (ImportItemResult, Int, Int) -> Void)? = nil
    ) -> ImportReport {
        let startedAt = Date()
        var report = ImportReport(source: .files, startedAt: startedAt, finishedAt: startedAt)

        let (files, duplicates) = ingestor.expand(urls, fileManager: fileManager)
        let total = files.count + duplicates.count

        for (index, url) in files.enumerated() {
            let item = ingestor.ingest(
                fileAt: url,
                source: .files,
                into: &project,
                using: store,
                fileManager: fileManager
            )
            report.append(item)
            progress?(item, index + 1, total)
        }

        for (offset, url) in duplicates.enumerated() {
            let item = ImportItemResult(
                source: .files,
                displayName: url.lastPathComponent,
                sourceIdentifier: url.standardizedFileURL.path,
                outcome: .skipped(.alreadyHandledInThisRun)
            )
            report.append(item)
            progress?(item, files.count + offset + 1, total)
        }

        report.finishedAt = Date()
        return report
    }

    /// Convenience for a single file.
    @discardableResult
    public func importFile(
        at url: URL,
        into project: inout Project,
        using store: ProjectStore,
        fileManager: FileManager = .default
    ) -> ImportItemResult {
        // `expand` is still worth going through: it is what turns a dropped
        // folder into files, and a single-URL drop is the common Mac gesture.
        let report = importFiles(at: [url], into: &project, using: store, fileManager: fileManager)
        return report.items.first
            ?? ImportItemResult(
                source: .files,
                displayName: url.lastPathComponent,
                sourceIdentifier: url.standardizedFileURL.path,
                outcome: .failed(.sourceUnavailable(url.path))
            )
    }
}
