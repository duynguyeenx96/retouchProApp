import Foundation
import RPCore
import RPImport
import RPUI

/// The app-target half of RPUI's ``ShotImporting`` seam: RPUI asks for photos,
/// this runs RPImport (docs/ADR-0014).
///
/// It lives here for the same reason `FaceAnalysisRenderBridge` does — the two
/// packages it joins must not import each other. RPUI has no `RPImport` edge
/// (docs/ADR-0004 amendment, asserted by `LayeringAuditTests.noUpwardImports`),
/// and the app target is the one place that links both.
///
/// Everything below is wiring: no import *policy* is decided here. De-duplication
/// by content hash, the extension allow-list, RAW preservation, per-file results
/// and the "never write into `originals/` directly" rule all stay in RPImport
/// (docs/ADR-0003). The only thing this type adds is the narrowing of
/// `ImportReport` to `ShotImportSummary` and a line in the app log.
struct RPImportShotImporter: ShotImporting {
    var files: FilesImporter
    var photos: PhotosImporter
    /// Where a finished run is written in full. Defaults to `AppLog`, replaced
    /// in tests so nothing is asserted about a global.
    var log: @Sendable (String) -> Void

    init(
        options: ImportOptions = .default,
        photoLibrary: any PhotoLibrarySource = PhotoKitLibrarySource(),
        log: @escaping @Sendable (String) -> Void = { AppLog.write($0) }
    ) {
        self.files = FilesImporter(options: options)
        self.photos = PhotosImporter(library: photoLibrary, options: options)
        self.log = log
    }

    func importFiles(at urls: [URL], into host: any ProjectMutating) async -> ShotImportSummary {
        let importer = files
        // `FilesImporter` takes `inout Project` because a picker callback
        // genuinely has one (ADR-0003 §12); `withProject` is how we get it
        // without becoming a second writer. The whole run is one turn of the
        // actor, so a `FolderWatcher` or the filmstrip cannot interleave a save
        // in the middle of it.
        let report = await host.withProject { project, store in
            importer.importFiles(
                at: urls, into: &project, using: store, fileManager: FileManager())
        }
        return finish(report)
    }

    func importPhotos(
        withLocalIdentifiers identifiers: [String],
        into host: any ProjectMutating
    ) async -> ShotImportSummary {
        // Ask first, so the system prompt appears once, before any work — and so
        // a denial comes back as `ImportFailure.permissionDenied` per asset
        // rather than as an empty success (`PhotosImporter.importAssets` checks
        // the status itself and reports it that way).
        await photos.ensureAuthorization()
        let report = await photos.importAssets(withLocalIdentifiers: identifiers, into: host)
        return finish(report)
    }

    private func finish(_ report: ImportReport) -> ShotImportSummary {
        log("import(\(report.source.rawValue)): \(report.detailedDescription)")
        return ShotImportSummary(
            importedCount: report.importedCount,
            skippedCount: report.skippedCount,
            failedCount: report.failedCount,
            importedShotIDs: report.importedShotIDs,
            message: report.summary,
            detail: report.detailedDescription
        )
    }
}
