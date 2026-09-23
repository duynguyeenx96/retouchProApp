import Foundation

/// The on-disk layout of a `.rpproj` bundle (docs/PLAN.md Phase 1, item 2).
///
/// ```
/// Wedding 2026-09-04.rpproj/
///   manifest.json                 project metadata + ordered shot list
///   session.json                  where the user left off: open shot, selection,
///                                 zoom, tab (docs/ADR-0025) — optional
///   originals/                    imported files, immutable, never rewritten
///   previews/                     derived JPEG/HEIF previews, safe to delete
///   edits/<shot id>.json          one EditState per shot (slider document)
///   edits/<shot id>.strokes.json  the shot's brush strokes, normalised
///                                 (docs/ADR-0019 addendum 2026-09-23) — optional
///   history/<shot id>.json        the shot's undo/redo timeline (docs/ADR-0025)
///                                 — optional
///   presets/<preset id>.json
/// ```
///
/// **A project is a self-contained work session** (docs/ADR-0025): the
/// originals, their derived previews, and every shot's editing *metadata* —
/// sliders, brush strokes, history — plus where the user was. Opening it
/// restores that session. Nothing in it is baked pixels: every mask is
/// re-rasterised from metadata at whatever resolution is needed, and anything
/// derived (previews, face/subject analysis) must be recomputable.
///
/// `masks/` (ADR-0019 §8's PNG store) is no longer created or written: the
/// brush is stored as strokes. A `masks/` folder in a bundle written on
/// 2026-09-23 before that change is ignored; ``ProjectStore/removeShot(id:from:fileManager:)``
/// still clears `masks/<shot id>/` when it exists.
///
/// It is a plain directory. Whether Finder shows it as a single opaque document
/// is a *presentation* choice that depends on a document type declared in the
/// app's Info.plist; nothing in RPCore depends on it, and RPCore must keep
/// working when the user has browsed inside the folder.
public enum ProjectBundle {
    public static let pathExtension = "rpproj"
    public static let manifestFileName = "manifest.json"
    public static let originalsDirectory = "originals"
    public static let previewsDirectory = "previews"
    public static let editsDirectory = "edits"
    public static let presetsDirectory = "presets"
    /// Hand-painted mask **PNGs**, one subdirectory per shot — ADR-0019 §8's
    /// storage, **superseded 2026-09-23** by strokes in
    /// ``manualMaskStrokesSuffix`` files. Kept only so a shot removal still
    /// cleans up a bundle written in between; nothing writes here and it is no
    /// longer created with the bundle.
    public static let masksDirectory = "masks"
    /// Per-shot undo/redo timelines, `history/<shot id>.json` (docs/ADR-0025).
    public static let historyDirectory = "history"
    /// `session.json` — where the user left off (docs/ADR-0025).
    public static let sessionFileName = "session.json"
    /// `edits/<shot id>` + this: the shot's brush strokes.
    public static let manualMaskStrokesSuffix = ".strokes.json"

    /// Directories created by ``ProjectStore/create(name:in:)`` and re-created
    /// on load if a user deleted one.
    public static let directories = [
        originalsDirectory, previewsDirectory, editsDirectory, presetsDirectory, historyDirectory,
    ]

    /// File extensions adopted when a file appears in `originals/` without a
    /// manifest entry (dropped in by hand, or copied by a crashed import).
    ///
    /// Chosen from what the plan's workflow can produce: a6300 JPEG/ARW, phone
    /// HEIC, and the common formats Core Image can decode. Anything else is
    /// left alone rather than guessed at.
    public static let importableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp",
        "arw", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
    ]

    public static func isImportableExtension(_ pathExtension: String) -> Bool {
        importableExtensions.contains(pathExtension.lowercased())
    }
}

public enum ProjectStoreError: Error, Equatable, CustomStringConvertible {
    case bundleAlreadyExists(path: String)
    case bundleNotFound(path: String)
    case manifestNotFound(path: String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case shotNotFound(ShotID)
    case presetNotFound(PresetID)
    case sourceFileNotFound(path: String)
    case invalidName(String)

    public var description: String {
        switch self {
        case .bundleAlreadyExists(let path):
            "A project already exists at \(path)."
        case .bundleNotFound(let path):
            "No project bundle at \(path)."
        case .manifestNotFound(let path):
            "\(path) has no \(ProjectBundle.manifestFileName); it is not a Retouch Pro project."
        case .unsupportedFormatVersion(let found, let supported):
            "Project format version \(found) is newer than this build supports (\(supported)). "
                + "Update Retouch Pro rather than opening it, so nothing is overwritten."
        case .shotNotFound(let id):
            "No shot \(id) in this project."
        case .presetNotFound(let id):
            "No preset \(id) in this project."
        case .sourceFileNotFound(let path):
            "Nothing to import at \(path)."
        case .invalidName(let name):
            "\"\(name)\" cannot be used as a project name."
        }
    }
}
