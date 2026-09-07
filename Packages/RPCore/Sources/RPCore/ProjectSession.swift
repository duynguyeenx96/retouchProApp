import Foundation

/// Serialised, `inout`-style access to the project a background writer should
/// add to.
///
/// ADR-0002 §10 makes `ProjectStore` a value and hands ownership of the
/// `Project` struct to the caller. That is exactly right for a picker callback
/// (`importFiles(at:into:&project)`), but it does not work for the writers that
/// run on their own schedule — RPImport's `FolderWatcher` and a long MTP
/// download, later Phase 3's batch queue and Phase 4's tether daemon — because
/// they have no `inout` binding to hold and the UI may be mutating its own copy
/// at the same time. Two writers, last save wins, one of them loses shots.
///
/// So those writers do not own a `Project`; they ask whoever does. The app
/// implements this protocol on top of its observable model; tests and headless
/// tools use ``ProjectSession``.
///
/// Lives in RPCore, not RPImport: it is project *ownership*, not importing
/// (ADR-0003 §12, moved in the Phase 1 review). Keeping it in RPImport forced
/// every consumer — RPUI today, the batch queue and the tether daemon later —
/// to link PhotoKit and ImageCaptureCore to get a concurrency primitive.
public protocol ProjectMutating: Sendable {
    /// Runs `body` with exclusive access to the project. The implementation
    /// must serialise concurrent callers.
    func withProject<T: Sendable>(
        _ body: @Sendable (inout Project, ProjectStore) throws -> T
    ) async rethrows -> T
}

/// The reference implementation of ``ProjectMutating``: an actor holding one
/// `Project` and its `ProjectStore`.
///
/// Also usable on its own as the headless project owner (a CLI, a test, the
/// Phase 4 tether daemon).
public actor ProjectSession: ProjectMutating {
    public let store: ProjectStore
    private var project: Project

    public init(store: ProjectStore, project: Project) {
        self.store = store
        self.project = project
    }

    /// Opens an existing bundle, running the load-time reconciliation from
    /// ADR-0002 §9. Orphans in `originals/` — including a file whose import
    /// crashed between the copy and the manifest write — are adopted in memory
    /// and, when `persistAdoptions` is set, saved.
    public init(
        openingBundleAt bundleURL: URL,
        persistAdoptions: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let store = ProjectStore(bundleURL: bundleURL)
        let result = try store.load(fileManager: fileManager)
        var project = result.project
        if persistAdoptions && !result.report.adoptedOriginals.isEmpty {
            project = try store.save(project, touchingModifiedAt: Date())
        }
        self.store = store
        self.project = project
    }

    public func withProject<T: Sendable>(
        _ body: @Sendable (inout Project, ProjectStore) throws -> T
    ) async rethrows -> T {
        try body(&project, store)
    }

    /// A snapshot for the UI. Cheap: `Project` is a value.
    public var current: Project { project }

    /// Replaces the project wholesale, e.g. after the UI edited it. Saves.
    public func replace(with newProject: Project) throws {
        project = try store.save(newProject, touchingModifiedAt: Date())
    }
}
