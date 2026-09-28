import Foundation
import RPCore

/// The one place in RPImport that turns a file on disk into a `Shot`.
///
/// Every importer — Files, Photos, MTP camera, FolderWatcher — funnels through
/// ``ingest(fileAt:displayName:source:into:using:fileManager:)``. That keeps
/// three contracts in a single spot instead of four:
///
/// 1. **`ProjectStore.addShot(copyingOriginalAt:into:)` is the only way in.**
///    RPImport never writes into `originals/` itself, so the non-atomic seam
///    documented in ADR-0002 §Consequences (copy done, manifest not yet
///    written → `load()` adopts the orphan) stays owned by RPCore.
/// 2. **Bytes are copied, never re-encoded.** `addShot` does `copyItem`; there
///    is no image pipeline anywhere in this file, which is what preserves an
///    `.ARW` byte-for-byte.
/// 3. **A bad file is a result, not a thrown error.** One unreadable frame on a
///    card must not abort the other 399.
public struct ShotIngestor: Sendable {
    public var options: ImportOptions
    public var metadataExtractor: any CaptureMetadataExtracting

    public init(
        options: ImportOptions = .default,
        metadataExtractor: any CaptureMetadataExtracting = ImageIOMetadataExtractor()
    ) {
        self.options = options
        self.metadataExtractor = metadataExtractor
    }

    /// Imports one file. Returns the outcome; never throws.
    ///
    /// - Parameters:
    ///   - url: the file to copy. Left untouched — importing never moves or
    ///     deletes the source.
    ///   - displayName: what the user should see. Defaults to the last path
    ///     component; Photos and MTP pass the asset's own name because their
    ///     staged temp file has a machine-generated one.
    public func ingest(
        fileAt url: URL,
        displayName: String? = nil,
        source: ImportSource,
        into project: inout Project,
        using store: ProjectStore,
        fileManager: FileManager = .default
    ) -> ImportItemResult {
        let name = displayName ?? url.lastPathComponent
        func result(_ outcome: ImportOutcome) -> ImportItemResult {
            ImportItemResult(
                source: source,
                displayName: name,
                sourceIdentifier: url.standardizedFileURL.path,
                outcome: outcome
            )
        }

        // Security-scoped access must bracket *everything*, including the copy
        // that happens inside addShot.
        let scoped = options.usesSecurityScopedAccess && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return result(.failed(.sourceUnavailable(url.path)))
        }
        guard !isDirectory.boolValue else {
            return result(.skipped(.notARegularFile))
        }
        // The extension gate is `ProjectBundle`'s allow-list, deliberately the
        // same one `load()` uses to adopt orphans (ADR-0002 §9): a file this
        // importer accepts is a file a reopened project would also accept.
        guard ProjectBundle.isImportableExtension(url.pathExtension) else {
            return result(.skipped(.unsupportedFileType(pathExtension: url.pathExtension)))
        }

        var contentHash: String?
        if options.wantsContentHash {
            do {
                contentHash = try ContentHash.of(fileAt: url)
            } catch {
                return result(.failed(.unreadable("\(url.lastPathComponent): \(error)")))
            }
            if options.wantsDeduplication, let contentHash,
                let existing = project.shots.first(where: { $0.contentHash == contentHash })
            {
                return result(.skipped(.duplicateContent(existingShotID: existing.id)))
            }
        }

        let capture =
            options.readCaptureMetadata
            ? metadataExtractor.metadata(forFileAt: url)
            : CaptureMetadata()

        do {
            let shot = try store.addShot(
                copyingOriginalAt: url,
                into: &project,
                capture: capture,
                contentHash: contentHash,
                fileManager: fileManager
            )
            // `addShot` keeps the *source's* last path component as
            // `originalFileName`. For a staged Photos/MTP download that is a
            // temp name, so restore the name the user knows.
            if let displayName, displayName != shot.originalFileName {
                project.updateShot(id: shot.id) { $0.originalFileName = displayName }
                // Persist the corrected name; a crash here leaves the temp
                // name in the manifest, which is cosmetic, not lossy.
                //
                // The `try?` is deliberate — do not turn it into a `try`. The
                // photo is already copied into `originals/` and registered; if
                // this save fails, the in-memory `project` carries the nice
                // name and the manifest on disk still carries the temp one,
                // and the next successful save reconciles them. Throwing here
                // would report a fully imported file as a failure and abort the
                // rest of the run over a display string.
                try? store.save(project)
            }
            return result(
                .imported(shotID: shot.id, originalRelativePath: shot.originalRelativePath))
        } catch {
            return result(.failed(.wrapping(error) { .copyFailed($0) }))
        }
    }

    /// Expands the caller's picks into a flat, deterministic list of candidate
    /// files.
    ///
    /// Directories are walked breadth-first and each level is sorted by name,
    /// so a `DCIM/100MSDCF` card imports in shot order and two runs over the
    /// same tree produce the same report. Duplicates in the input (the same
    /// file picked twice, or a file plus its parent folder) are reported as
    /// ``ImportSkipReason/alreadyHandledInThisRun`` rather than imported twice.
    public func expand(
        _ urls: [URL],
        fileManager: FileManager = .default
    ) -> (files: [URL], duplicates: [URL]) {
        var files: [URL] = []
        var duplicates: [URL] = []
        var seen: Set<String> = []

        func add(_ url: URL) {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(key).inserted {
                files.append(url)
            } else {
                duplicates.append(url)
            }
        }

        func walk(_ directory: URL, depth: Int) {
            guard depth <= options.maximumDirectoryDepth else { return }
            let contents =
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )) ?? []
            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in sorted {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else {
                    continue
                }
                if isDirectory.boolValue {
                    walk(child, depth: depth + 1)
                } else if ProjectBundle.isImportableExtension(child.pathExtension) {
                    add(child)
                }
                // Non-importable files found *inside* a directory the user
                // dropped are silently ignored: they were never picked, so
                // reporting ".txt was skipped" for every sidecar on a card
                // would bury the real messages.
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue && options.expandDirectories {
                let scoped =
                    options.usesSecurityScopedAccess && url.startAccessingSecurityScopedResource()
                walk(url, depth: 1)
                if scoped { url.stopAccessingSecurityScopedResource() }
            } else {
                // Explicitly picked files go through even when unreadable or
                // unsupported, so `ingest` can report *why*.
                add(url)
            }
        }
        return (files, duplicates)
    }
}
