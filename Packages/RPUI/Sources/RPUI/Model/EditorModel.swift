import CoreGraphics
import Foundation
import Observation
import RPCore
import RPEngine

/// Everything one open project needs on screen, and the **only** thing in RPUI
/// that writes to disk.
///
/// Ownership follows docs/ADR-0003 §12 rather than inventing a second model:
/// the authoritative `Project` lives in RPCore's `ProjectSession` actor, every
/// mutation goes through `withProject`, and this class keeps a `project`
/// snapshot for SwiftUI to observe. That means the Phase 1 item 3 importers
/// (`FolderWatcher`, `MTPCameraImporter`), which take a `ProjectMutating` and
/// run on their own schedule, can be pointed at ``session`` — or at `self`,
/// since this type conforms too — and cannot race the UI's edits. RPUI does
/// not link RPImport to say that: `ProjectMutating` is an RPCore type, and the
/// app target is what owns the importers.
///
/// It is `@MainActor` and `@Observable`, but every method that matters is
/// testable without SwiftUI: nothing here touches a view.
@MainActor
@Observable
public final class EditorModel {
    /// Snapshot of the project. Read-only to the UI; write through the methods
    /// below so the actor and the disk stay in step.
    public private(set) var project: Project
    public private(set) var presets: [Preset] = []
    /// `EditState` of the active shot, loaded from `edits/<id>.json`.
    /// Phase 2's sliders mutate this; Phase 1 only reads it.
    public private(set) var activeEditState: EditState = EditState()

    public var selection = FilmstripSelection()
    public var viewport = CanvasViewport()
    public var beforeAfter = BeforeAfterState()
    /// True while ``mutate(_:)`` has a write in flight, for a progress
    /// indicator.
    ///
    /// **Not a lock, and nothing gates on it.** Two fast taps on a star do
    /// issue two `mutate` calls, and that is safe: both go through the
    /// `ProjectSession` actor, so they are serialised and the second one's
    /// save wins. It also cannot be used as a lock — with two writes in flight
    /// the first one to finish clears the flag while the second is still
    /// running.
    public private(set) var isWriting = false
    /// Last thing that went wrong, for a banner. Cleared by ``dismissError()``.
    public private(set) var lastErrorMessage: String?

    /// True while an import is running, for a progress indicator and to keep the
    /// import controls from being tapped twice.
    public private(set) var isImporting = false
    /// `ImportReport.summary` of the last import, for the status line. Cleared by
    /// ``dismissImportMessage()``.
    public private(set) var lastImportMessage: String?

    /// The render seam (docs/ADR-0004 §2), used for the **original** side of the
    /// canvas and for filmstrip thumbnails.
    ///
    /// It stays `PassthroughPreviewRenderer` on purpose now that the live
    /// preview exists: "decode the file under `originals/` and ignore
    /// `EditState`" is *exactly* what the before/after "before" side and a
    /// thumbnail want. Making it apply edits instead would re-decode and
    /// re-render every thumbnail on every slider tick — `PreviewImageCache` keys
    /// on the `EditState` fingerprint as soon as `appliesEditState` is true.
    /// The edited pixels come from ``live`` (docs/ADR-0013).
    public let renderer: any PreviewRendering

    /// The GPU canvas. `nil` on a machine with no Metal device, or when the
    /// render graph refuses to build — the canvas then falls back to the decoded
    /// original and says so.
    public let live: LivePreviewController?
    /// Serialised project ownership (ADR-0003 §12).
    public let session: ProjectSession
    /// The same bundle the session writes to.
    ///
    /// Held here rather than read from `session.store`, because an actor's
    /// stored properties are isolated under Swift 6 and the views need paths
    /// synchronously. That is safe precisely because `ProjectStore` is a
    /// *value* holding a URL and a writer (ADR-0002 §10): two equal stores are
    /// interchangeable, and mutations still go through the session.
    public let store: ProjectStore

    /// The import seam (docs/ADR-0014). `nil` on a build that wires no
    /// importer — the import controls are then hidden rather than failing when
    /// tapped, which is what ``canImport`` is for.
    public let importer: (any ShotImporting)?

    public init(
        session: ProjectSession,
        store: ProjectStore,
        project: Project,
        renderer: any PreviewRendering = PassthroughPreviewRenderer(),
        live: LivePreviewController? = nil,
        importer: (any ShotImporting)? = nil
    ) {
        self.session = session
        self.store = store
        self.project = project
        self.renderer = renderer
        self.live = live
        self.importer = importer
        selection.synchronize(with: project.shots)
    }

    /// Opens a `.rpproj` bundle, running ADR-0002 §9 reconciliation: shots
    /// whose original is gone are kept, orphans in `originals/` are adopted and
    /// — only if there were any — persisted.
    public static func open(
        bundleURL: URL,
        renderer: any PreviewRendering = PassthroughPreviewRenderer(),
        live: LivePreviewController? = nil,
        importer: (any ShotImporting)? = nil
    ) async throws -> EditorModel {
        let opened = try await Task.detached { () -> (ProjectStore, Project) in
            let store = ProjectStore(bundleURL: bundleURL)
            let result = try store.load()
            var project = result.project
            if !result.report.adoptedOriginals.isEmpty {
                project = try store.save(project, touchingModifiedAt: Date())
            }
            return (store, project)
        }.value

        let session = ProjectSession(store: opened.0, project: opened.1)
        let model = EditorModel(
            session: session, store: opened.0, project: opened.1, renderer: renderer, live: live,
            importer: importer)
        await model.loadActiveEditState()
        await model.reloadPresets()
        return model
    }

    // MARK: - Derived state

    public var shots: [Shot] { project.shots }

    public var activeShot: Shot? { selection.activeShot(in: project.shots) }

    /// Absolute URL of the active shot's file under `originals/`.
    public var activeOriginalURL: URL? {
        activeShot.map { store.originalURL(for: $0) }
    }

    public func originalURL(for shot: Shot) -> URL {
        store.originalURL(for: shot)
    }

    /// Cached preview if RPEngine has written one, otherwise the original.
    ///
    /// **Placeholder.** `previews/` is written by nobody yet (ADR-0002
    /// §Consequences), so today this is always the original file, decoded by
    /// `ImageDecoder`. When RPEngine's PreviewRenderer starts writing previews
    /// this starts preferring them, and the call sites do not change.
    public func thumbnailURL(for shot: Shot) -> URL {
        if let preview = shot.previewRelativePath {
            let url = store.url(forRelativePath: preview)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return store.originalURL(for: shot)
    }

    /// The two requests the canvas needs: the current edit and the untouched
    /// original. With a passthrough renderer they produce identical pixels;
    /// see ``BeforeAfterState``.
    public func previewRequest(maxPixelSize: Int) -> PreviewRequest? {
        guard let url = activeOriginalURL else { return nil }
        return PreviewRequest(
            originalURL: url, editState: activeEditState, maxPixelSize: maxPixelSize)
    }

    // MARK: - Selection

    /// Every shot change writes the outgoing shot's edits first: a drag that was
    /// never committed (the pointer was released outside the control, or the
    /// user hit ↓ mid-drag) must not be lost by leaving the shot.
    public func select(shotID: ShotID?) async {
        await commitEditState()
        selection.select(shotID, in: project.shots)
        viewport = CanvasViewport()
        await loadActiveEditState()
    }

    public func selectNextShot() async {
        await commitEditState()
        guard selection.selectNext(in: project.shots) else { return }
        viewport = CanvasViewport()
        await loadActiveEditState()
    }

    public func selectPreviousShot() async {
        await commitEditState()
        guard selection.selectPrevious(in: project.shots) else { return }
        viewport = CanvasViewport()
        await loadActiveEditState()
    }

    // MARK: - Sliders (Phase 2)

    /// Reads one slider out of the active shot's document.
    public func slider(_ name: String, in section: String) -> Double {
        activeEditState.slider(name, in: section)
    }

    /// Writes one slider and repaints the canvas — **without touching the disk**.
    ///
    /// Dragging a slider produces tens of values a second and every one of them
    /// would be a `write(2)` plus an `fsync`. So the drag mutates memory only,
    /// the GPU repaints from memory, and ``commitEditState()`` writes the file
    /// once when the drag ends (`SwiftUI.Slider`'s `onEditingChanged`). A crash
    /// mid-drag loses the drag, which is the same guarantee every editor gives.
    public func setSlider(_ name: String, in section: String, to value: Double) {
        activeEditState.setSlider(name, in: section, to: value)
        live?.update(editState: activeEditState)
    }

    /// Sets every slider of one group back to 0 (i.e. removes them).
    public func resetSection(_ section: String) {
        activeEditState[section: section] = EditSection()
        live?.update(editState: activeEditState)
        Task { await commitEditState() }
    }

    /// Sets every slider of every group back to 0, keeping ``EditState/perImage``
    /// (the face selection and, later, the crop) — resetting the look must not
    /// silently retarget the sliders onto a different face.
    public func resetAllSliders() {
        activeEditState.sections = [:]
        live?.update(editState: activeEditState)
        Task { await commitEditState() }
    }

    /// Persists the active shot's `EditState` to `edits/<id>.json`.
    ///
    /// Safe to call often: it is a no-op when the state has not changed since
    /// the last write.
    public func commitEditState() async {
        guard let shot = activeShot else { return }
        guard lastSavedEditState != activeEditState else { return }
        let store = self.store
        let id = shot.id
        let state = activeEditState
        do {
            try await Task.detached { try store.saveEditState(state, for: id) }.value
            lastSavedEditState = state
            if state.isDefault {
                editedShotIDs.remove(id)
            } else {
                editedShotIDs.insert(id)
            }
        } catch {
            lastErrorMessage = "Could not save edits for \(shot.originalFileName): \(error)"
        }
    }

    /// The document as it currently is on disk, so ``commitEditState()`` can skip
    /// a write that would change nothing.
    private var lastSavedEditState: EditState?

    // MARK: - "Đã chỉnh" index (library filter)

    /// Shots whose `edits/<id>.json` carries at least one slider.
    ///
    /// Kept as a set rather than recomputed per cell: the library's "Đã chỉnh"
    /// filter asks the question once per thumbnail, and the answer is a file
    /// read. Refreshed by ``refreshEditedIndex()`` when a library appears and
    /// whenever the active shot's edits are written, which is every place it can
    /// change from inside the app.
    public private(set) var editedShotIDs: Set<ShotID> = []

    public func isEdited(_ shot: Shot) -> Bool {
        if shot.id == activeShot?.id { return !activeEditState.isDefault }
        return editedShotIDs.contains(shot.id)
    }

    public func refreshEditedIndex() async {
        let store = self.store
        let ids = project.shots.map(\.id)
        editedShotIDs = await Task.detached { () -> Set<ShotID> in
            var edited: Set<ShotID> = []
            for id in ids {
                guard let state = try? store.loadEditState(for: id), !state.isDefault else {
                    continue
                }
                edited.insert(id)
            }
            return edited
        }.value
    }

    // MARK: - Face selection (Phase 2, docs/ADR-0013)

    /// Which detected face the face-dependent groups act on.
    public var faceSelection: FaceSelection {
        FaceSelection(activeEditState).resolved(faceCount: live?.faces.count ?? 0)
    }

    /// Number of faces RPVision found in the active shot. 0 when face analysis
    /// did not run (no models, no Metal, or the flag is off).
    public var detectedFaceCount: Int { live?.faces.count ?? 0 }

    /// Faces found in `shot`, or `nil` when nobody has analysed it yet.
    ///
    /// Face analysis runs **once per opened shot** on the canvas (ADR-0013), so
    /// the only shot with an answer is the one the GPU preview currently holds.
    /// The library's info panel says "—" for the rest rather than triggering 36 ms
    /// of Core ML per thumbnail, which is the cost this design exists to avoid.
    public func detectedFaceCount(for shot: Shot) -> Int? {
        guard let live, live.faceAnalysisRan,
            live.openContentHash == (shot.contentHash ?? shot.id.rawValue)
        else { return nil }
        return live.faces.count
    }

    /// The mockup's "Đồng bộ" toggle: `true` when a slider edit applies to
    /// **every** detected face rather than to one chosen face.
    ///
    /// It is not a new piece of state — it is exactly the absence of
    /// `EditState.perImage["selectedFace"]` (docs/ADR-0013), which is what makes
    /// the face-dependent nodes see all faces. docs/design/SPEC.md left the
    /// semantics open and said not to invent an `EditState` field for it; this
    /// is the reading that needs none, and with a single detected face it is
    /// inert exactly as the spec expects.
    public var isSyncingAllFaces: Bool { faceSelection.selectedIndex == nil }

    /// Turning sync **on** clears the face selection; turning it **off** pins
    /// the sliders to the face that is already highlighted, or to the first one.
    public func setSyncingAllFaces(_ isOn: Bool) {
        if isOn {
            selectFace(nil)
        } else if detectedFaceCount > 0 {
            selectFace(faceSelection.selectedIndex ?? 0)
        }
    }

    /// Selects a face, or `nil` for "all faces". Persisted immediately: unlike a
    /// slider drag it is a single discrete choice, and it changes what every
    /// face-dependent slider means.
    public func selectFace(_ index: Int?) {
        let selection =
            index.map { FaceSelection(target: .face(index: $0)) } ?? FaceSelection()
        selection.write(into: &activeEditState)
        live?.update(editState: activeEditState)
        Task { await commitEditState() }
    }

    // MARK: - Rating and flag (filmstrip writes)

    /// Writes a 0–5 rating for `shotID` and saves the manifest.
    public func setRating(_ rating: Int, for shotID: ShotID) async {
        await mutate { project, store in
            project.updateShot(id: shotID) { $0.rating = rating }
            project = try store.save(project, touchingModifiedAt: Date())
        }
    }

    /// A second tap on the same star clears the rating, the way Lightroom and
    /// Capture One behave.
    public func toggleRating(_ rating: Int, for shotID: ShotID) async {
        let current = project.shot(id: shotID)?.rating ?? 0
        await setRating(current == rating ? 0 : rating, for: shotID)
    }

    public func setFlag(_ flag: ShotFlag, for shotID: ShotID) async {
        await mutate { project, store in
            project.updateShot(id: shotID) { $0.flag = flag }
            project = try store.save(project, touchingModifiedAt: Date())
        }
    }

    /// Toggling to the flag it already has clears it back to `.unflagged`.
    public func toggleFlag(_ flag: ShotFlag, for shotID: ShotID) async {
        let current = project.shot(id: shotID)?.flag ?? .unflagged
        await setFlag(current == flag ? .unflagged : flag, for: shotID)
    }

    // MARK: - Presets (read-only in Phase 1)

    /// Lists `presets/`. Applying a preset is Phase 3 — nothing in RPUI writes
    /// an `EditState` from a preset yet.
    public func reloadPresets() async {
        do {
            let store = self.store
            presets = try await Task.detached { try store.listPresets() }.value
        } catch {
            presets = []
            lastErrorMessage = "Could not read presets: \(error)"
        }
    }

    /// Presets in `Project.presetOrder` first, then the rest by name — the
    /// order `Project.presetOrder` documents.
    public var orderedPresets: [Preset] {
        let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        var ordered = project.presetOrder.compactMap { byID[$0] }
        let placed = Set(ordered.map(\.id))
        ordered += presets.filter { !placed.contains($0.id) }
        return ordered
    }

    // MARK: - Import

    /// Whether the import controls should be shown at all.
    public var canImport: Bool { importer != nil }

    /// Copies the files the user picked into `originals/` and shows them in the
    /// filmstrip.
    ///
    /// The whole run goes through ``importer`` — RPImport's `FilesImporter`
    /// in the app — which writes through `ProjectMutating`, i.e. through the
    /// same `ProjectSession` actor as every other write (docs/ADR-0003 §12). No
    /// second writer, no last-save-wins.
    @discardableResult
    public func importFiles(at urls: [URL]) async -> ShotImportSummary {
        guard let importer, !urls.isEmpty else { return .empty }
        return await runImport { host in
            await importer.importFiles(at: urls, into: host)
        }
    }

    /// Same for assets picked in `PhotosPicker`, by `PHAsset.localIdentifier`.
    @discardableResult
    public func importPhotos(withLocalIdentifiers identifiers: [String]) async -> ShotImportSummary {
        guard let importer, !identifiers.isEmpty else { return .empty }
        return await runImport { host in
            await importer.importPhotos(withLocalIdentifiers: identifiers, into: host)
        }
    }

    public func dismissImportMessage() { lastImportMessage = nil }

    /// The picker itself failed (not one file inside a run). Surfaced through
    /// the same banner as everything else that goes wrong.
    public func reportImportFailure(_ message: String) {
        lastErrorMessage = "Could not open the picker: \(message)"
    }

    /// The bit both paths share: run it, pull the snapshot, land on something.
    private func runImport(
        _ body: (any ProjectMutating) async -> ShotImportSummary
    ) async -> ShotImportSummary {
        isImporting = true
        defer { isImporting = false }

        let previousSelection = selection.activeShotID
        let summary = await body(self)
        // `refresh()` re-synchronises the selection, which is what selects the
        // first shot of a project that was empty until a second ago.
        await refresh()
        // …and that new selection has an `EditState` nobody has read yet, and a
        // texture the GPU canvas has not been given. `refresh()` deliberately
        // does not do this (a rating change must not reload the document), so
        // the import path asks for it explicitly when the shot actually moved.
        if selection.activeShotID != previousSelection {
            await loadActiveEditState()
        }
        lastImportMessage = summary.isEmpty ? nil : summary.message
        if summary.failedCount > 0 {
            lastErrorMessage = "Import: \(summary.message)"
        }
        return summary
    }

    // MARK: - Reload

    /// Pulls a fresh snapshot out of the session. Call after an importer has
    /// added shots through `ProjectMutating`.
    public func refresh() async {
        project = await session.current
        selection.synchronize(with: project.shots)
    }

    public func loadActiveEditState() async {
        guard let shot = activeShot else {
            activeEditState = EditState()
            lastSavedEditState = nil
            live?.update(editState: activeEditState)
            return
        }
        let store = self.store
        let id = shot.id
        do {
            activeEditState = try await Task.detached { try store.loadEditState(for: id) }.value
        } catch {
            activeEditState = EditState()
            lastErrorMessage = "Could not read edits for \(shot.originalFileName): \(error)"
        }
        lastSavedEditState = activeEditState
        live?.update(editState: activeEditState)
    }

    public func dismissError() { lastErrorMessage = nil }

    // MARK: - Mutation plumbing

    /// One place where a `Project` write happens: through the session, then the
    /// snapshot and the selection are re-synchronised. Errors become
    /// `lastErrorMessage` instead of a `try` at every call site, because a
    /// failed star rating must not tear down the editor.
    private func mutate(
        _ body: @Sendable @escaping (inout Project, ProjectStore) throws -> Void
    ) async {
        isWriting = true
        defer { isWriting = false }
        do {
            try await session.withProject { project, store in
                try body(&project, store)
            }
            await refresh()
        } catch {
            lastErrorMessage = String(describing: error)
            await refresh()
        }
    }
}

/// `EditorModel` *is* the project owner while a project is open, so an importer
/// started from the editor can be handed the model itself.
///
/// The conformance forwards to the session rather than duplicating state: the
/// actor stays the serialisation point (ADR-0003 §12), and callers on the main
/// actor should follow a mutation with ``EditorModel/refresh()`` to pull the new
/// snapshot — which is exactly what ``EditorModel/mutate(_:)`` does.
extension EditorModel: ProjectMutating {
    nonisolated public func withProject<T: Sendable>(
        _ body: @Sendable (inout Project, ProjectStore) throws -> T
    ) async rethrows -> T {
        try await session.withProject(body)
    }
}
