import Foundation
import RPCore

/// What a ``FolderWatcher`` reports to whoever is listening.
public enum FolderWatcherEvent: Sendable {
    case started(URL)
    /// One scan that actually did something. Scans that find nothing are not
    /// reported, so a UI listening to this stream is quiet on an idle folder.
    case imported(ImportReport)
    /// The folder went away — card ejected, volume unmounted, folder deleted.
    /// Watching continues; the folder may come back.
    case becameUnavailable(URL)
    /// The folder is back (card re-inserted, volume remounted).
    case becameAvailable(URL)
    case stopped(URL)
}

/// Watches a folder — a local directory, or the mount point of a card reader —
/// and imports new files into the project as they finish being written
/// (PLAN Phase 1 item 3: "FolderWatcher (chọn thư mục/card → ảnh mới tự vào
/// project)"; also the receiving half of PLAN Phase 4's "Mac làm cầu").
///
/// ## Why polling and not FSEvents
///
/// `FSEventStream` is macOS-only, and RPImport has to build for iPadOS too, so
/// it cannot be the mechanism. `DispatchSource.makeFileSystemObjectSource`
/// (kqueue) exists on both, but a kqueue on a directory only fires for changes
/// to that directory's own entries — not to a subdirectory — and on some
/// removable and network volumes it does not fire reliably at all. A card
/// reader is exactly that case.
///
/// So the watcher **polls** on a fixed interval and additionally arms a kqueue
/// on the folder as a *latency* optimisation: when it fires, the next scan
/// happens immediately instead of up to `pollInterval` later. Correctness never
/// depends on the kqueue.
///
/// ## Why a file is not imported the moment it appears
///
/// A 24 MP ARW copied off a slow card takes seconds, and the file exists — at
/// its final path, with a growing size — for all of them. Importing on
/// appearance would copy a truncated RAW into `originals/`, and because
/// `originals/` is immutable (ADR-0002) that damage would be permanent.
///
/// A file is therefore imported only once two consecutive observations at least
/// ``Configuration/stabilityInterval`` apart report the **same size and the
/// same modification date**. Anything else is reported as
/// ``ImportSkipReason/stillBeingWritten(observedBytes:)`` and retried on the
/// next scan.
public actor FolderWatcher {
    public struct Configuration: Sendable {
        /// The folder or volume mount point to watch.
        public var url: URL
        /// How long a file's size and mtime must hold still before it counts as
        /// finished. 1.5 s covers a stalled USB 2.0 card read (~20 MB/s in
        /// bursts) without making a normal import feel slow.
        public var stabilityInterval: TimeInterval
        /// Scan cadence when the kqueue says nothing. 2 s is well under the
        /// time it takes a user to notice, and a scan of a 1000-file DCIM
        /// folder is a `stat` per file.
        public var pollInterval: TimeInterval
        /// Descend into subdirectories. On by default: a card is
        /// `DCIM/100MSDCF/…`, so watching the volume root with recursion off
        /// would see nothing.
        public var recursive: Bool
        public var maximumDepth: Int
        /// Import files that were already in the folder when watching started.
        ///
        /// Default **false**: the user picked a card that already holds 800
        /// shots from last week, and "watch this folder" should mean "tell me
        /// about new ones". Set it for the card-dump workflow, or call
        /// ``importExistingContents()`` explicitly.
        public var importsPreexistingFiles: Bool
        /// Injected clock, so tests can drive the stability rule without
        /// sleeping.
        public var now: @Sendable () -> Date

        public init(
            url: URL,
            stabilityInterval: TimeInterval = 1.5,
            pollInterval: TimeInterval = 2.0,
            recursive: Bool = true,
            maximumDepth: Int = 8,
            importsPreexistingFiles: Bool = false,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.url = url
            self.stabilityInterval = stabilityInterval
            self.pollInterval = pollInterval
            self.recursive = recursive
            self.maximumDepth = maximumDepth
            self.importsPreexistingFiles = importsPreexistingFiles
            self.now = now
        }
    }

    /// What a `stat` says about a file's *contents*, as far as a watcher can
    /// tell without reading them.
    ///
    /// This is the identity used for both the stability rule and the handled
    /// set. Path alone is not an identity: a card reader hands the next card
    /// the same mount point when both volumes carry the same generic label
    /// (`/Volumes/NO NAME`), and a camera whose counter was reset writes
    /// `DSC00001.ARW` again — so "this exact path was already handled" would
    /// silently drop a whole second card. Size and mtime together separate two
    /// different frames that happen to share a path; if they somehow do not,
    /// `ShotIngestor`'s content hash still refuses the duplicate, and that
    /// costs a skip line instead of a lost photo.
    struct FileSignature: Sendable, Hashable {
        var byteSize: Int64
        var modifiedAt: Date?
    }

    /// One `stat` of a candidate file, remembered between scans.
    struct Observation: Sendable, Hashable {
        var signature: FileSignature
        /// When this signature was first seen. The file is stable once
        /// `now - unchangedSince >= stabilityInterval`.
        var unchangedSince: Date
    }

    public let configuration: Configuration
    private let host: any ProjectMutating
    private let ingestor: ShotIngestor
    private let fileManager: FileManager

    /// Files already imported, or skipped/failed for a reason that cannot
    /// change on its own — keyed by resolved path **and** signature, so the
    /// entry stops applying the moment the bytes behind that path are not the
    /// bytes that were handled (see ``FileSignature``).
    private var handled: [String: FileSignature] = [:]
    private var observations: [String: Observation] = [:]
    private var isAvailable = true
    private var isRunning = false
    private var loopTask: Task<Void, Never>?
    private var kqueueSource: (any DispatchSourceFileSystemObject)?
    private var continuations: [UUID: AsyncStream<FolderWatcherEvent>.Continuation] = [:]
    /// Set by the kqueue callback to make the loop skip its remaining sleep.
    private var wakeUp = false

    public init(
        configuration: Configuration,
        host: any ProjectMutating,
        options: ImportOptions = .default,
        metadataExtractor: any CaptureMetadataExtracting = ImageIOMetadataExtractor(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.host = host
        var options = options
        // The watched folder is either a user-picked location (the app holds
        // the scope for as long as the watcher lives, which is the caller's
        // job) or a mounted volume. Re-entering the scope per file would be
        // wrong for the former and pointless for the latter.
        options.usesSecurityScopedAccess = false
        self.ingestor = ShotIngestor(options: options, metadataExtractor: metadataExtractor)
        self.fileManager = fileManager
    }

    // MARK: - Events

    /// A stream of ``FolderWatcherEvent``. Multiple listeners are supported;
    /// each gets its own stream.
    public func events() -> AsyncStream<FolderWatcherEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: FolderWatcherEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - Lifecycle

    /// Starts watching. Returns immediately; scanning happens on a detached
    /// task until ``stop()``.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Baseline: unless the caller asked for them, everything already in the
        // folder is marked handled without being imported, so "new" means
        // "arrived after start".
        //
        // Baselined by signature, like everything else in `handled`: a file
        // that was still being written when watching started is *not* a
        // pre-existing file, and once its size moves it stops matching and is
        // imported normally.
        if !configuration.importsPreexistingFiles {
            for url in candidateFiles() {
                guard let signature = signature(of: url) else { continue }
                handled[key(for: url)] = signature
            }
        }

        armKqueue()
        emit(.started(configuration.url))

        loopTask = Task { [weak self] in
            guard let self else { return }
            while await self.isRunningNow() {
                _ = await self.scanOnce()
                await self.sleepUntilNextScan()
            }
        }
    }

    /// Stops the loop and **ends every event stream**.
    ///
    /// Terminating the streams is unconditional, not gated on `isRunning`: a
    /// caller that observed ``events()`` and then used only ``scanOnce()``
    /// would otherwise be left iterating a stream that never finishes.
    public func stop() {
        if isRunning {
            isRunning = false
            kqueueSource?.cancel()
            kqueueSource = nil
            loopTask?.cancel()
            loopTask = nil
        }
        emit(.stopped(configuration.url))
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    private func isRunningNow() -> Bool { isRunning && !Task.isCancelled }

    private func sleepUntilNextScan() async {
        // Wake early if the kqueue fired, but never spin: check at 100 ms
        // granularity up to `pollInterval`.
        let slice = Duration.milliseconds(100)
        var elapsed: TimeInterval = 0
        while elapsed < configuration.pollInterval, isRunning {
            if wakeUp {
                wakeUp = false
                return
            }
            try? await Task.sleep(for: slice)
            elapsed += 0.1
        }
    }

    private func armKqueue() {
        let descriptor = open(configuration.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.noteExternalChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        kqueueSource = source
    }

    private func noteExternalChange() {
        wakeUp = true
    }

    // MARK: - Scanning

    /// Runs exactly one scan and returns what it did.
    ///
    /// Public and synchronous-in-effect so tests (and a "Check now" button) can
    /// drive the watcher deterministically, with no timers involved.
    @discardableResult
    public func scanOnce() async -> ImportReport {
        let startedAt = configuration.now()
        var report = ImportReport(
            source: .folderWatch, startedAt: startedAt, finishedAt: startedAt)

        guard directoryExists() else {
            if isAvailable {
                isAvailable = false
                // Forget the in-flight stability observations: a file that was
                // half-written when the card was pulled must be re-observed
                // from scratch, not resumed at its old size.
                observations.removeAll()
                emit(.becameUnavailable(configuration.url))
            }
            report.finishedAt = configuration.now()
            return report
        }
        if !isAvailable {
            isAvailable = true
            emit(.becameAvailable(configuration.url))
        }

        let bundlePath = await host.withProject { _, store in store.bundleURL.path }

        for url in candidateFiles() {
            let path = key(for: url)
            // Never import a project's own files back into itself: a user who
            // watches the folder that holds the .rpproj would otherwise create
            // an infinite copy loop through `originals/`. Checked before the
            // stat because it is a pure path test and true forever.
            guard !path.hasPrefix(bundlePath + "/") else { continue }

            guard let current = signature(of: url) else {
                continue  // Vanished between listing and stat; try again later.
            }
            // Handled applies only to the exact bytes that were handled. A new
            // card mounted at the old path, or the same name rewritten, does
            // not match and is processed from scratch.
            guard handled[path] != current else { continue }

            let size = current.byteSize
            let now = configuration.now()

            let previous = observations[path]
            if previous?.signature == current,
                let unchangedSince = previous?.unchangedSince,
                now.timeIntervalSince(unchangedSince) >= configuration.stabilityInterval
            {
                let ingestor = self.ingestor
                // A fresh `FileManager` inside the closure: `FileManager` is
                // not `Sendable` and cannot cross the actor hop.
                let item = await host.withProject { project, store in
                    ingestor.ingest(
                        fileAt: url,
                        source: .folderWatch,
                        into: &project,
                        using: store,
                        fileManager: FileManager()
                    )
                }
                // Only outcomes that cannot change by themselves are permanent.
                // A permanently unreadable frame on a card must not produce an
                // error line every 2 s until the app quits; a file that merely
                // vanished between this scan's stat and the ingestor's re-check
                // is a race, not a defect, and has to stay eligible.
                if Self.isFinal(item.outcome) {
                    handled[path] = current
                }
                // Either way the stability window restarts: a retry re-observes
                // the file from scratch rather than firing again next scan.
                observations[path] = nil
                report.append(item)
            } else {
                if previous?.signature != current {
                    observations[path] = Observation(signature: current, unchangedSince: now)
                }
                report.append(
                    ImportItemResult(
                        source: .folderWatch,
                        displayName: url.lastPathComponent,
                        sourceIdentifier: path,
                        outcome: .skipped(.stillBeingWritten(observedBytes: size))
                    ))
            }
        }

        report.finishedAt = configuration.now()
        if report.items.contains(where: { !$0.outcome.isSkipped }) {
            emit(.imported(report))
        }
        return report
    }

    /// Imports everything currently in the folder that is already stable,
    /// ignoring ``Configuration/importsPreexistingFiles``. This is the
    /// "dump the card into the project" button.
    @discardableResult
    public func importExistingContents() async -> ImportReport {
        for url in candidateFiles() {
            handled[key(for: url)] = nil
            // Pre-date the observation so the very next scan treats a file that
            // is not currently changing as stable, instead of costing one extra
            // poll interval.
            if let signature = signature(of: url) {
                observations[key(for: url)] = Observation(
                    signature: signature,
                    unchangedSince: configuration.now()
                        .addingTimeInterval(-configuration.stabilityInterval)
                )
            }
        }
        return await scanOnce()
    }

    /// Test/diagnostic hook: paths the watcher will not look at again *as long
    /// as their size and mtime are unchanged*.
    public var handledPaths: Set<String> { Set(handled.keys) }

    /// Whether an outcome settles a file for good.
    ///
    /// "Final" means: repeating the attempt on the same bytes would give the
    /// same answer, so remembering it saves work and stops report spam.
    /// Everything else — above all `.failed(.sourceUnavailable)`, which is what
    /// a file disappearing mid-scan looks like — is left retryable.
    static func isFinal(_ outcome: ImportOutcome) -> Bool {
        switch outcome {
        case .imported:
            return true
        case .skipped(let reason):
            switch reason {
            case .unsupportedFileType, .duplicateContent, .notARegularFile:
                return true
            case .stillBeingWritten, .alreadyHandledInThisRun, .cancelled:
                return false
            }
        case .failed(let failure):
            switch failure {
            // The file is not there *now*. It may be a moment later — a card
            // being written to, or a copy that moved the file — so this must
            // not blacklist the path.
            case .sourceUnavailable, .timedOut:
                return false
            // These say something about the file or the destination that will
            // still be true on the next poll: a corrupt frame, a full disk, a
            // manifest the store rejects.
            case .unreadable, .copyFailed, .storeRejected, .sourceError, .permissionDenied:
                return true
            }
        }
    }

    // MARK: - File system

    /// `stat` reduced to the pair the watcher reasons about. `nil` when the
    /// file is gone.
    private func signature(of url: URL) -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return FileSignature(
            byteSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private func directoryExists() -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: configuration.url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Importable files under the watched folder, sorted, deepest-last.
    private func candidateFiles() -> [URL] {
        var results: [URL] = []

        func walk(_ directory: URL, depth: Int) {
            guard depth <= configuration.maximumDepth else { return }
            let contents =
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )) ?? []
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory) else {
                    continue
                }
                if isDirectory.boolValue {
                    // A `.rpproj` is a directory. Never walk into one — that is
                    // the copy loop again, and `previews/` would look like new
                    // photos.
                    guard configuration.recursive,
                        child.pathExtension != ProjectBundle.pathExtension
                    else { continue }
                    walk(child, depth: depth + 1)
                } else if ProjectBundle.isImportableExtension(child.pathExtension) {
                    results.append(child)
                }
            }
        }

        walk(configuration.url, depth: 1)
        return results
    }
}
