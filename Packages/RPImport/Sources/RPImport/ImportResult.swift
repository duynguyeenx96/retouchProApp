import Foundation
import RPCore

/// Where an imported file came from. Recorded per item so a future UI can say
/// "3 of 40 from the card failed" rather than "something failed".
public enum ImportSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// A file the user picked in a file picker, or dropped on the window.
    case files
    /// The system Photos library (PhotoKit).
    case photos
    /// A camera or card attached in MTP / PTP mode (ImageCaptureCore).
    case camera
    /// A watched folder or removable volume (``FolderWatcher``).
    case folderWatch
}

/// Why an importer *deliberately* did not import something.
///
/// A skip is not an error: the run is still a success. Kept separate from
/// ``ImportFailure`` so a UI can show "12 imported, 3 already in the project"
/// without a red badge.
public enum ImportSkipReason: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Extension is not in `ProjectBundle.importableExtensions`.
    case unsupportedFileType(pathExtension: String)
    /// The same bytes are already in the project (matched by content hash).
    case duplicateContent(existingShotID: ShotID)
    /// A directory, symlink loop, device node, … where a file was expected.
    case notARegularFile
    /// Named in the input twice, or seen twice in one folder scan.
    case alreadyHandledInThisRun
    /// The file is still being written; ``FolderWatcher`` will retry.
    case stillBeingWritten(observedBytes: Int64)
    /// The caller cancelled before this item was reached.
    case cancelled

    public var description: String {
        switch self {
        case .unsupportedFileType(let ext):
            ext.isEmpty
                ? "no file extension, so the format is unknown"
                : ".\(ext) is not a supported image format"
        case .duplicateContent(let shotID):
            "identical to a shot already in this project (\(shotID.rawValue))"
        case .notARegularFile:
            "not a regular file"
        case .alreadyHandledInThisRun:
            "already handled in this run"
        case .stillBeingWritten(let bytes):
            "still being written (\(bytes) bytes so far); will retry"
        case .cancelled:
            "cancelled"
        }
    }
}

/// Why an item could not be imported.
///
/// Deliberately a closed, `Equatable`, `Sendable`, `Codable` enum rather than
/// `any Error`: an import report is a value that gets stored, compared in tests
/// and (later) written to a log, and `any Error` is none of those things. The
/// original error's text is kept in the associated `message`.
public enum ImportFailure: Sendable, Hashable, Codable, Error, CustomStringConvertible {
    /// The source file/asset vanished, or was never there.
    case sourceUnavailable(String)
    /// Could not read the source (permissions, I/O error, sandbox).
    case unreadable(String)
    /// The copy into `originals/` failed (disk full, I/O error).
    case copyFailed(String)
    /// `ProjectStore` rejected the shot or could not write the manifest.
    case storeRejected(String)
    /// A platform source (Photos, ImageCaptureCore) refused or errored.
    case sourceError(String)
    /// The user has not granted access to the source.
    case permissionDenied(String)
    /// A download or export took longer than the importer's budget.
    case timedOut(String)

    public var description: String {
        switch self {
        case .sourceUnavailable(let m): "source unavailable: \(m)"
        case .unreadable(let m): "could not read: \(m)"
        case .copyFailed(let m): "copy failed: \(m)"
        case .storeRejected(let m): "project rejected it: \(m)"
        case .sourceError(let m): "source error: \(m)"
        case .permissionDenied(let m): "permission denied: \(m)"
        case .timedOut(let m): "timed out: \(m)"
        }
    }

    /// Wraps an arbitrary thrown error, keeping `ProjectStoreError`'s own
    /// wording when that is what failed.
    public static func wrapping(_ error: any Error, as kind: (String) -> ImportFailure)
        -> ImportFailure
    {
        if let storeError = error as? ProjectStoreError {
            return .storeRejected(storeError.description)
        }
        if let failure = error as? ImportFailure {
            return failure
        }
        return kind(String(describing: error))
    }
}

/// What happened to one item.
public enum ImportOutcome: Sendable, Hashable, Codable {
    /// Copied into `originals/` and registered in the manifest.
    case imported(shotID: ShotID, originalRelativePath: String)
    case skipped(ImportSkipReason)
    case failed(ImportFailure)

    public var isImported: Bool { if case .imported = self { true } else { false } }
    public var isSkipped: Bool { if case .skipped = self { true } else { false } }
    public var isFailed: Bool { if case .failed = self { true } else { false } }

    public var shotID: ShotID? {
        if case .imported(let id, _) = self { id } else { nil }
    }

    public var failure: ImportFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    public var skipReason: ImportSkipReason? {
        if case .skipped(let reason) = self { reason } else { nil }
    }
}

/// One line of an ``ImportReport``.
public struct ImportItemResult: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity for a list row: the source identifier.
    public var id: String { sourceIdentifier }

    public var source: ImportSource
    /// What the user would recognise: `"DSC01234.ARW"`.
    public var displayName: String
    /// How the importer names the item internally — a file path, a
    /// `PHAsset.localIdentifier`, an `ICCameraItem` name. Unique within a run.
    public var sourceIdentifier: String
    public var outcome: ImportOutcome

    public init(
        source: ImportSource,
        displayName: String,
        sourceIdentifier: String,
        outcome: ImportOutcome
    ) {
        self.source = source
        self.displayName = displayName
        self.sourceIdentifier = sourceIdentifier
        self.outcome = outcome
    }

    /// One line of human-readable text, e.g.
    /// `"DSC01234.ARW — skipped: identical to a shot already in this project (…)"`.
    public var summaryLine: String {
        switch outcome {
        case .imported(_, let path): "\(displayName) — imported to \(path)"
        case .skipped(let reason): "\(displayName) — skipped: \(reason)"
        case .failed(let failure): "\(displayName) — failed: \(failure)"
        }
    }
}

/// The result of one import run: every item, in the order it was attempted.
///
/// Importers never throw for a single bad file — they record it here and carry
/// on, so one unreadable file on a card cannot abort a 400-shot import.
public struct ImportReport: Sendable, Hashable, Codable {
    public var source: ImportSource
    public var items: [ImportItemResult]
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        source: ImportSource,
        items: [ImportItemResult] = [],
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.source = source
        self.items = items
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var importedShotIDs: [ShotID] { items.compactMap(\.outcome.shotID) }
    public var importedCount: Int { items.count(where: { $0.outcome.isImported }) }
    public var skippedCount: Int { items.count(where: { $0.outcome.isSkipped }) }
    public var failedCount: Int { items.count(where: { $0.outcome.isFailed }) }
    public var isEmpty: Bool { items.isEmpty }
    /// True when nothing failed. Skips are not failures.
    public var succeeded: Bool { failedCount == 0 }

    public var failures: [ImportItemResult] { items.filter { $0.outcome.isFailed } }
    public var skips: [ImportItemResult] { items.filter { $0.outcome.isSkipped } }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// `"12 imported, 3 skipped, 1 failed"` — the string a status bar wants.
    public var summary: String {
        var parts: [String] = ["\(importedCount) imported"]
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: ", ")
    }

    /// Multi-line detail, one line per item. Suitable for the app log.
    public var detailedDescription: String {
        ([summary] + items.map(\.summaryLine)).joined(separator: "\n")
    }

    public mutating func append(_ item: ImportItemResult) {
        items.append(item)
    }

    public mutating func merge(_ other: ImportReport) {
        items.append(contentsOf: other.items)
        startedAt = Swift.min(startedAt, other.startedAt)
        finishedAt = Swift.max(finishedAt, other.finishedAt)
    }
}
