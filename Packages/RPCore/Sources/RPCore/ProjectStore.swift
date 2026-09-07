import Foundation

/// Owns one `.rpproj` bundle on disk.
///
/// `ProjectStore` is a **value**: it holds a URL and a writer, no cached
/// project state. The caller keeps the `Project` (a plain `Sendable` struct)
/// and hands it back for saving. That keeps the store trivially `Sendable`, and
/// keeps "what the user sees" and "what is on disk" in two places that can be
/// compared instead of one place that can silently drift.
///
/// Invariants:
/// - Nothing under `originals/` is ever written, moved or deleted after import.
///   Removing a shot leaves the file and records a tombstone.
/// - Every JSON write goes through ``AtomicFileWriter``.
public struct ProjectStore: Sendable {
    public let bundleURL: URL
    public var writer: AtomicFileWriter

    public init(bundleURL: URL, writer: AtomicFileWriter = AtomicFileWriter()) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.writer = writer
    }

    // MARK: - Paths

    public var manifestURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.manifestFileName)
    }

    public var originalsURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.originalsDirectory)
    }

    public var previewsURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.previewsDirectory)
    }

    public var editsURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.editsDirectory)
    }

    public var presetsURL: URL {
        bundleURL.appendingPathComponent(ProjectBundle.presetsDirectory)
    }

    /// Absolute URL for a bundle-relative path such as `"originals/DSC01234.ARW"`.
    public func url(forRelativePath relativePath: String) -> URL {
        bundleURL.appendingPathComponent(relativePath)
    }

    public func originalURL(for shot: Shot) -> URL {
        url(forRelativePath: shot.originalRelativePath)
    }

    public func editsURL(for shotID: ShotID) -> URL {
        editsURL.appendingPathComponent("\(shotID.rawValue).json")
    }

    public func presetURL(for presetID: PresetID) -> URL {
        presetsURL.appendingPathComponent("\(presetID.rawValue).json")
    }

    /// Where a preview for `shotID` should be written. `RPEngine` owns making it.
    public func previewURL(for shotID: ShotID, pathExtension: String = "jpg") -> URL {
        previewsURL.appendingPathComponent("\(shotID.rawValue).\(pathExtension)")
    }

    // MARK: - Create

    /// Creates `<directory>/<name>.rpproj` with its four subdirectories and a
    /// manifest, and returns the store plus the empty project.
    ///
    /// Fails rather than merging if something is already at that path.
    @discardableResult
    public static func create(
        name: String,
        in directory: URL,
        fileManager: FileManager = .default,
        writer: AtomicFileWriter = AtomicFileWriter()
    ) throws -> (store: ProjectStore, project: Project) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectStoreError.invalidName(name) }

        let bundleURL =
            directory
            .appendingPathComponent(sanitizedFileName(trimmed))
            .appendingPathExtension(ProjectBundle.pathExtension)
        guard !fileManager.fileExists(atPath: bundleURL.path) else {
            throw ProjectStoreError.bundleAlreadyExists(path: bundleURL.path)
        }

        let store = ProjectStore(bundleURL: bundleURL, writer: writer)
        try store.createDirectories(fileManager: fileManager)

        let now = Date()
        let project = Project(name: trimmed, createdAt: now, modifiedAt: now)
        try store.save(project)
        return (store, project)
    }

    /// Creates any missing bundle directory. Called on create and on load, so a
    /// user who deleted `previews/` to reclaim space still gets a working bundle.
    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        for directory in ProjectBundle.directories {
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
    }

    /// Replaces path separators and other awkward characters in a user-supplied
    /// project name. Only affects the folder name; `Project.name` keeps the
    /// text the user typed.
    public static func sanitizedFileName(_ name: String) -> String {
        var result = name
        for character in ["/", "\\", ":", "\0"] {
            result = result.replacingOccurrences(of: character, with: "-")
        }
        if result.hasPrefix(".") { result = "_" + result.dropFirst() }
        return String(result.prefix(180))
    }

    // MARK: - Load

    /// What ``load(options:fileManager:)`` had to reconcile between the manifest
    /// and the files actually present. Empty in the normal case.
    public struct LoadReport: Hashable, Sendable {
        /// Files found in `originals/` with no manifest entry, adopted as shots.
        public var adoptedOriginals: [String] = []
        /// Shots whose imported file is gone (ejected volume, user deletion).
        /// The shots are kept — losing edits because a file was moved would be
        /// worse than showing a broken thumbnail.
        public var missingOriginals: [ShotID] = []

        public var isClean: Bool {
            adoptedOriginals.isEmpty && missingOriginals.isEmpty
        }
    }

    public struct LoadOptions: Sendable {
        /// Adopt unreferenced files in `originals/` as new shots.
        public var adoptOrphanOriginals: Bool
        /// Create missing bundle directories while loading.
        public var repairDirectories: Bool

        public init(adoptOrphanOriginals: Bool = true, repairDirectories: Bool = true) {
            self.adoptOrphanOriginals = adoptOrphanOriginals
            self.repairDirectories = repairDirectories
        }

        public static let `default` = LoadOptions()
    }

    public struct LoadResult: Sendable {
        public var project: Project
        public var report: LoadReport
    }

    /// Reads the manifest and reconciles it with the files on disk.
    ///
    /// **Reads only.** Adopted shots exist in the returned `Project` but are not
    /// persisted until the caller saves, so opening a project can never damage
    /// it.
    public func load(
        options: LoadOptions = .default,
        fileManager: FileManager = .default
    ) throws -> LoadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ProjectStoreError.bundleNotFound(path: bundleURL.path)
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.manifestNotFound(path: bundleURL.path)
        }
        if options.repairDirectories {
            try createDirectories(fileManager: fileManager)
        }

        let manifest = try RPJSON.decoder.decode(
            ProjectManifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        guard manifest.formatVersion <= ProjectManifest.currentFormatVersion else {
            throw ProjectStoreError.unsupportedFormatVersion(
                found: manifest.formatVersion,
                supported: ProjectManifest.currentFormatVersion
            )
        }

        var project = manifest.project
        var report = LoadReport()

        // A missing `edits/<id>.json` is not an anomaly: an untouched shot has
        // no file, because every slider defaults to 0. Only a missing *original*
        // is worth reporting.
        for shot in project.shots
        where !fileManager.fileExists(atPath: originalURL(for: shot).path) {
            report.missingOriginals.append(shot.id)
        }

        if options.adoptOrphanOriginals {
            let referenced = project.referencedOriginalPaths
            let tombstoned = Set(project.removedOriginalPaths)
            for relativePath in try originalFileRelativePaths(fileManager: fileManager)
            where !referenced.contains(relativePath) && !tombstoned.contains(relativePath) {
                let fileName = (relativePath as NSString).lastPathComponent
                project.shots.append(
                    Shot(originalFileName: fileName, originalRelativePath: relativePath)
                )
                report.adoptedOriginals.append(relativePath)
            }
        }

        return LoadResult(project: project, report: report)
    }

    /// Sorted `originals/…` relative paths of importable files, ignoring
    /// dot-files and the writer's temp debris.
    public func originalFileRelativePaths(fileManager: FileManager = .default) throws -> [String] {
        guard fileManager.fileExists(atPath: originalsURL.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: originalsURL, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { url in
                let name = url.lastPathComponent
                guard !name.hasPrefix(".") else { return false }
                return ProjectBundle.isImportableExtension(url.pathExtension)
            }
            .map { "\(ProjectBundle.originalsDirectory)/\($0.lastPathComponent)" }
            .sorted()
    }

    // MARK: - Save

    /// Writes `manifest.json` atomically. Does **not** touch `modifiedAt`; use
    /// ``save(_:touchingModifiedAt:)`` when the change came from the user.
    public func save(_ project: Project) throws {
        try writer.writeJSON(ProjectManifest(project: project), to: manifestURL)
    }

    /// Writes the manifest and stamps `modifiedAt`, returning the stamped value
    /// so the caller's copy stays in sync with the file.
    @discardableResult
    public func save(_ project: Project, touchingModifiedAt date: Date) throws -> Project {
        var stamped = project
        stamped.modifiedAt = date
        try save(stamped)
        return stamped
    }

    // MARK: - Edit states

    /// The shot's `EditState`, or a default one when the file does not exist —
    /// an untouched shot has no file, so "missing" and "all sliders at 0" are
    /// the same thing.
    public func loadEditState(for shotID: ShotID, fileManager: FileManager = .default) throws
        -> EditState
    {
        let url = editsURL(for: shotID)
        guard fileManager.fileExists(atPath: url.path) else { return EditState() }
        return try RPJSON.decoder.decode(EditState.self, from: try Data(contentsOf: url))
    }

    /// Atomically writes one shot's `EditState`.
    ///
    /// This is the write that happens most often — once per slider release —
    /// so it must never be able to leave a truncated JSON file behind.
    public func saveEditState(
        _ state: EditState,
        for shotID: ShotID,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: editsURL, withIntermediateDirectories: true)
        try writer.writeJSON(state, to: editsURL(for: shotID))
    }

    public func deleteEditState(for shotID: ShotID, fileManager: FileManager = .default) throws {
        let url = editsURL(for: shotID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Shots

    /// Copies `sourceURL` into `originals/`, registers it in `project`, and
    /// saves the manifest.
    ///
    /// The source file is copied, never moved: the card or the Photos library
    /// entry the user imported from stays intact. On a name collision the copy
    /// is suffixed (`DSC01234-2.ARW`) and `Shot.originalFileName` keeps the
    /// camera's original name.
    @discardableResult
    public func addShot(
        copyingOriginalAt sourceURL: URL,
        into project: inout Project,
        id: ShotID = .generate(),
        capture: CaptureMetadata = CaptureMetadata(),
        contentHash: String? = nil,
        editState: EditState? = nil,
        fileManager: FileManager = .default
    ) throws -> Shot {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ProjectStoreError.sourceFileNotFound(path: sourceURL.path)
        }
        try createDirectories(fileManager: fileManager)

        let fileName = try uniqueOriginalFileName(
            for: sourceURL.lastPathComponent, in: project, fileManager: fileManager)
        let destination = originalsURL.appendingPathComponent(fileName)
        try fileManager.copyItem(at: sourceURL, to: destination)

        let relativePath = "\(ProjectBundle.originalsDirectory)/\(fileName)"
        let shot = Shot(
            id: id,
            originalFileName: sourceURL.lastPathComponent,
            originalRelativePath: relativePath,
            capture: capture,
            contentHash: contentHash
        )

        if let editState {
            try saveEditState(editState, for: shot.id, fileManager: fileManager)
        }
        project.shots.append(shot)
        project.removedOriginalPaths.removeAll { $0 == relativePath }
        project = try save(project, touchingModifiedAt: Date())
        return shot
    }

    /// Registers a file that is *already* inside `originals/` (e.g. adopted by
    /// ``load(options:fileManager:)``) without copying anything.
    @discardableResult
    public func addShot(
        existingOriginalRelativePath relativePath: String,
        into project: inout Project,
        id: ShotID = .generate(),
        fileManager: FileManager = .default
    ) throws -> Shot {
        let absolute = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: absolute.path) else {
            throw ProjectStoreError.sourceFileNotFound(path: absolute.path)
        }
        let shot = Shot(
            id: id,
            originalFileName: absolute.lastPathComponent,
            originalRelativePath: relativePath
        )
        project.shots.append(shot)
        project.removedOriginalPaths.removeAll { $0 == relativePath }
        project = try save(project, touchingModifiedAt: Date())
        return shot
    }

    /// Removes a shot from the project.
    ///
    /// Deletes its `edits/` document and cached preview, records a tombstone so
    /// the next load does not re-adopt the file, and **leaves the imported file
    /// in `originals/` untouched**. Reclaiming that space is a separate,
    /// explicit action (``deleteOriginalFile(at:fileManager:)``) so an
    /// accidental click in the filmstrip can never destroy a RAW.
    @discardableResult
    public func removeShot(
        id shotID: ShotID,
        from project: inout Project,
        fileManager: FileManager = .default
    ) throws -> Shot {
        guard let index = project.index(of: shotID) else {
            throw ProjectStoreError.shotNotFound(shotID)
        }
        let shot = project.shots.remove(at: index)

        try deleteEditState(for: shotID, fileManager: fileManager)
        if let preview = shot.previewRelativePath {
            let previewURL = url(forRelativePath: preview)
            if fileManager.fileExists(atPath: previewURL.path) {
                try? fileManager.removeItem(at: previewURL)
            }
        }
        if !project.shots.contains(where: { $0.originalRelativePath == shot.originalRelativePath }),
            !project.removedOriginalPaths.contains(shot.originalRelativePath)
        {
            project.removedOriginalPaths.append(shot.originalRelativePath)
        }
        project = try save(project, touchingModifiedAt: Date())
        return shot
    }

    /// Deletes a file under `originals/`. Deliberately separate from
    /// ``removeShot(id:from:fileManager:)``: this is the only method in RPCore
    /// that destroys an imported file, and callers have to ask for it by name.
    public func deleteOriginalFile(
        at relativePath: String,
        fileManager: FileManager = .default
    ) throws {
        let url = url(forRelativePath: relativePath)
        guard url.standardizedFileURL.path.hasPrefix(originalsURL.path + "/") else {
            throw ProjectStoreError.sourceFileNotFound(path: url.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// A file name not already used in `originals/` or claimed by the manifest.
    func uniqueOriginalFileName(
        for requested: String,
        in project: Project,
        fileManager: FileManager = .default
    ) throws -> String {
        let base = (requested as NSString).deletingPathExtension
        let ext = (requested as NSString).pathExtension
        let claimed = project.referencedOriginalPaths

        func candidate(_ index: Int) -> String {
            let stem = index == 1 ? base : "\(base)-\(index)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }

        var index = 1
        while index < 10_000 {
            let name = candidate(index)
            let relativePath = "\(ProjectBundle.originalsDirectory)/\(name)"
            let exists = fileManager.fileExists(
                atPath: originalsURL.appendingPathComponent(name).path)
            if !exists && !claimed.contains(relativePath) { return name }
            index += 1
        }
        // Practically unreachable; a UUID stem is still a valid, unique name.
        return ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
    }

    // MARK: - Presets

    /// Every preset in `presets/`, sorted by name then id so the order is stable
    /// across machines. Unreadable files are skipped rather than failing the
    /// whole library — one corrupt preset must not make the app unusable.
    public func listPresets(fileManager: FileManager = .default) throws -> [Preset] {
        guard fileManager.fileExists(atPath: presetsURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: presetsURL, includingPropertiesForKeys: nil)
        let presets: [Preset] = files
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? RPJSON.decoder.decode(Preset.self, from: data)
            }
        return presets.sorted {
            ($0.name.localizedStandardCompare($1.name) == .orderedSame)
                ? $0.id < $1.id
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func loadPreset(id: PresetID, fileManager: FileManager = .default) throws -> Preset {
        let url = presetURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.presetNotFound(id)
        }
        return try RPJSON.decoder.decode(Preset.self, from: try Data(contentsOf: url))
    }

    public func savePreset(_ preset: Preset, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: presetsURL, withIntermediateDirectories: true)
        try writer.writeJSON(preset, to: presetURL(for: preset.id))
    }

    public func deletePreset(id: PresetID, fileManager: FileManager = .default) throws {
        let url = presetURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.presetNotFound(id)
        }
        try fileManager.removeItem(at: url)
    }
}
