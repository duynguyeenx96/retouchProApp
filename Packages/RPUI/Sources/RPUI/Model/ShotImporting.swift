import Foundation
import RPCore
import UniformTypeIdentifiers

/// How the UI asks for photos to be brought into the open project.
///
/// **Why a protocol and not `import RPImport`.** The importers themselves live
/// in `RPImport` (docs/PLAN.md §2), which links PhotoKit and ImageCaptureCore.
/// `LayeringAuditTests.noUpwardImports` asserts that RPUI does *not* import
/// RPImport, and docs/ADR-0004's amendment removed that edge on purpose. Rather
/// than put it back, the import UI follows the seam pattern this codebase
/// already uses twice — `PreviewRendering` (ADR-0004 §2) and `FaceInputProviding`
/// (ADR-0013) — where RPUI declares a protocol over plain values and the **app
/// target**, which links everything, supplies the conformance
/// (`App/RPImportShotImporter.swift`). See docs/ADR-0014.
///
/// The picker UI (`.fileImporter`, `.photosPicker`) is SwiftUI and stays here;
/// only the part that touches PhotoKit and `ProjectStore.addShot` is behind the
/// seam.
///
/// Both methods take the project owner rather than a `Project`: an import is
/// exactly the "asynchronous writer that does not own the project" case
/// `ProjectMutating` exists for (docs/ADR-0003 §12). `EditorModel` conforms, so
/// the UI hands the importer itself.
public protocol ShotImporting: Sendable {
    /// Files the user picked in a document picker / `NSOpenPanel`.
    ///
    /// The URLs are security-scoped on both platforms; the conformance is
    /// responsible for bracketing access (RPImport's `ImportOptions
    /// .usesSecurityScopedAccess` does it per file).
    func importFiles(at urls: [URL], into host: any ProjectMutating) async -> ShotImportSummary

    /// Assets the user picked in `PhotosPicker`, by `PHAsset.localIdentifier`.
    ///
    /// Identifiers rather than pickers' own item type, because that is what
    /// RPImport's `PhotosImporter` takes and it keeps PhotoKit out of this
    /// package.
    func importPhotos(
        withLocalIdentifiers identifiers: [String],
        into host: any ProjectMutating
    ) async -> ShotImportSummary
}

/// What one import run did, flattened to the few things the UI shows.
///
/// A deliberate narrowing of RPImport's `ImportReport` (docs/ADR-0003 §2): the
/// per-item outcomes stay in the report, which the adapter writes to the app
/// log, and only the counts plus two strings cross the seam. `message` and
/// `detail` are passed through verbatim from `ImportReport.summary` /
/// `detailedDescription`, so the banner and the log cannot drift from each
/// other.
public struct ShotImportSummary: Sendable, Hashable {
    public var importedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    /// Shots added, in import order. Phase 3's "auto-apply a preset to every new
    /// shot" hangs off this.
    public var importedShotIDs: [ShotID]
    /// One line for the status bar, e.g. `"12 imported, 3 skipped, 1 failed"`.
    public var message: String
    /// One line per item, for the app log.
    public var detail: String

    public init(
        importedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        importedShotIDs: [ShotID] = [],
        message: String,
        detail: String = ""
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.importedShotIDs = importedShotIDs
        self.message = message
        self.detail = detail
    }

    /// Nothing was attempted — the user cancelled the picker, or picked nothing.
    public static let empty = ShotImportSummary(message: "Nothing to import")

    public var isEmpty: Bool {
        importedCount == 0 && skippedCount == 0 && failedCount == 0
    }
}

/// The content types the file picker offers.
///
/// Derived from `ProjectBundle.importableExtensions` rather than hard-coded, so
/// a format added to RPCore's allow-list becomes selectable without anybody
/// remembering to edit a second list. `public.image` is included as the
/// catch-all: a RAW flavour with no registered `UTType` on this machine would
/// otherwise be greyed out in the panel even though `ShotIngestor` would accept
/// it by extension.
public enum ImportFileTypes {
    public static let allowed: [UTType] = {
        var seen: Set<UTType> = [.image]
        var types: [UTType] = [.image]
        for ext in ProjectBundle.importableExtensions.sorted() {
            guard let type = UTType(filenameExtension: ext) else { continue }
            if seen.insert(type).inserted { types.append(type) }
        }
        return types
    }()

    /// Extensions in `ProjectBundle.importableExtensions` that this machine has
    /// no `UTType` for. They are still importable — `.image` lets the panel show
    /// them and `ShotIngestor` gates on the extension — this exists so a test
    /// can report the gap instead of it being invisible.
    public static var extensionsWithoutUTType: [String] {
        ProjectBundle.importableExtensions.sorted().filter {
            UTType(filenameExtension: $0) == nil
        }
    }
}
