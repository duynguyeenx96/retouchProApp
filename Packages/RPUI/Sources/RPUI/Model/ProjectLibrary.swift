import Foundation
import RPCore

/// One row of the projects list, read from a bundle's `manifest.json`.
public struct ProjectEntry: Identifiable, Hashable, Sendable {
    public var bundleURL: URL
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var shotCount: Int
    /// Bundle-relative path of the first shot's original, for a cover thumbnail.
    public var coverRelativePath: String?
    /// Non-nil when the manifest could not be read. The row is still listed —
    /// hiding a project because this build cannot parse it would look like data
    /// loss to the user.
    public var problem: String?

    public var id: URL { bundleURL }

    public init(
        bundleURL: URL,
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        shotCount: Int = 0,
        coverRelativePath: String? = nil,
        problem: String? = nil
    ) {
        self.bundleURL = bundleURL
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.shotCount = shotCount
        self.coverRelativePath = coverRelativePath
        self.problem = problem
    }

    /// Absolute URL of the cover image, if there is one.
    public var coverURL: URL? {
        coverRelativePath.map { bundleURL.appendingPathComponent($0) }
    }
}

/// A folder of `.rpproj` bundles.
///
/// Deliberately a plain value with no state: listing is a directory scan, so
/// there is no cache to invalidate and a project created by a different process
/// (or dropped in by the user) shows up on the next scan.
public struct ProjectLibrary: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// `<app Documents>/Retouch Pro Projects`.
    ///
    /// On sandboxed macOS this is inside the app container, and on iOS it is the
    /// app's Documents directory — one path expression that works on both, and
    /// no security-scoped bookmark needed to reach it. Opening a bundle from
    /// anywhere else (item 3's Files import territory) will need one; that is
    /// Phase 1 item 3's `NSOpenPanel` / document-picker path, not this.
    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Retouch Pro Projects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    public static func `default`(fileManager: FileManager = .default) throws -> ProjectLibrary {
        ProjectLibrary(rootURL: try defaultRoot(fileManager: fileManager))
    }

    /// Every `.rpproj` directly inside `rootURL`, newest change first.
    public func entries(fileManager: FileManager = .default) throws -> [ProjectEntry] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return
            contents
            .filter { $0.pathExtension.lowercased() == ProjectBundle.pathExtension }
            .map { entry(forBundleAt: $0, fileManager: fileManager) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Reads one bundle's manifest into an entry. Never throws: an unreadable
    /// project becomes a row carrying `problem`.
    public func entry(forBundleAt bundleURL: URL, fileManager: FileManager = .default)
        -> ProjectEntry
    {
        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let store = ProjectStore(bundleURL: bundleURL)
        do {
            let data = try Data(contentsOf: store.manifestURL)
            let manifest = try RPJSON.decoder.decode(ProjectManifest.self, from: data)
            let project = manifest.project
            return ProjectEntry(
                bundleURL: bundleURL,
                name: project.name,
                createdAt: project.createdAt,
                modifiedAt: project.modifiedAt,
                shotCount: project.shots.count,
                coverRelativePath: project.shots.first?.originalRelativePath
            )
        } catch {
            let modified =
                (try? fileManager.attributesOfItem(atPath: bundleURL.path)[.modificationDate]
                    as? Date) ?? nil
            return ProjectEntry(
                bundleURL: bundleURL,
                name: fallbackName,
                modifiedAt: modified ?? .distantPast,
                problem: String(describing: error)
            )
        }
    }

    /// Creates `<root>/<name>.rpproj`. Appends " 2", " 3"… when the name is
    /// taken, rather than failing — a photographer creating "Studio" twice in a
    /// day should not have to think of a new word.
    @discardableResult
    public func createProject(
        named name: String,
        fileManager: FileManager = .default
    ) throws -> (store: ProjectStore, project: Project) {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectStoreError.invalidName(name) }

        var attempt = 1
        while attempt < 1000 {
            let candidate = attempt == 1 ? trimmed : "\(trimmed) \(attempt)"
            do {
                return try ProjectStore.create(
                    name: candidate, in: rootURL, fileManager: fileManager)
            } catch ProjectStoreError.bundleAlreadyExists {
                attempt += 1
            }
        }
        throw ProjectStoreError.invalidName(name)
    }

    /// A default name for the "New project" button: the date, as a shoot is
    /// usually a day (docs/PLAN.md: "Project cho mỗi buổi chụp").
    public static func suggestedProjectName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Shoot \(formatter.string(from: date))"
    }
}
