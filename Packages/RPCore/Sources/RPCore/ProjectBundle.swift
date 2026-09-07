import Foundation

/// The on-disk layout of a `.rpproj` bundle (docs/PLAN.md Phase 1, item 2).
///
/// ```
/// Wedding 2026-09-04.rpproj/
///   manifest.json          project metadata + ordered shot list
///   originals/             imported files, immutable, never rewritten
///   previews/              derived JPEG/HEIF previews, safe to delete
///   edits/<shot id>.json   one EditState per shot
///   presets/<preset id>.json
/// ```
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

    /// Directories created by ``ProjectStore/create(name:in:)`` and re-created
    /// on load if a user deleted one.
    public static let directories = [
        originalsDirectory, previewsDirectory, editsDirectory, presetsDirectory,
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
