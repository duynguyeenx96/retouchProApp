import Foundation
import RPCore

/// One photo's look, held in memory so it can be pasted onto others —
/// Lightroom's *Copy Settings* / *Paste Settings*.
///
/// It **is** a ``Preset`` inside: "a shot's edits minus the per-image fields" is
/// exactly what a preset is (docs/PLAN.md §2), and `Preset.init(from:)` already
/// drops `EditState.perImage`, so copying cannot carry a face index or a crop
/// from the source photo onto the targets. What it is not is a *saved* preset:
/// this never reaches `presets/`, has no name the user chose, and dies with the
/// window. Saving a look is the preset library's job and is a different button.
public struct CopiedSettings: Hashable, Sendable {
    /// The captured look. Its `name` is the source file name, for the menu text.
    public let preset: Preset
    /// Where it came from — used to keep "paste onto the photo you copied from"
    /// out of the enabled condition, and to name the source in the UI.
    public let sourceShotID: ShotID
    public let sourceFileName: String

    /// True when the source photo had no edits at all. Pasting it is still a
    /// real action: it **resets** the targets, exactly as applying an empty
    /// preset does (`EditState.applying(_:mode:.replace)` sets the sections
    /// wholesale). The UI says so rather than hiding the case.
    public var isEmpty: Bool { preset.isEmpty }

    public init(preset: Preset, sourceShotID: ShotID, sourceFileName: String) {
        self.preset = preset
        self.sourceShotID = sourceShotID
        self.sourceFileName = sourceFileName
    }
}

/// Multi-select and the settings clipboard.
///
/// Kept out of `EditorModel.swift` for the same reason `EditorModel+Presets` is:
/// it is one self-contained feature, and it belongs *on* `EditorModel` because
/// only that type owns the project, the open `EditState` and the live preview.
///
/// The write path is deliberately the preset apply path, not a second one:
/// paste = `EditState.applying(preset, mode: .replace)` + `saveEditState`, which
/// is what applying a template preset to every shot already does
/// (`EditorModel/applyPreset(_:replacingSections:scope:)`, and what a new import
/// gets from `ProjectStore.autoApplyEditState`).
extension EditorModel {

    // MARK: - Selection

    /// ⌘-click on macOS / a tap in the phone library's "Chọn" mode.
    ///
    /// Goes through the same "leaving a shot commits it, arriving loads it"
    /// sequence as ``select(shotID:)`` — ⌘-clicking a photo opens it, so an
    /// uncommitted slider drag on the outgoing shot must not be lost.
    public func toggleSelection(shotID: ShotID) async {
        let shots = project.shots
        await changeSelection { selection in selection.toggle(shotID, in: shots) }
    }

    /// ⇧-click: extend the selection from the anchor to `shotID`.
    public func extendSelection(toShotID shotID: ShotID) async {
        let shots = project.shots
        await changeSelection { selection in selection.selectRange(to: shotID, in: shots) }
    }

    /// End of a marquee drag over the library grid.
    public func selectShots(_ ids: Set<ShotID>, adding: Bool) async {
        let shots = project.shots
        await changeSelection { selection in selection.selectSet(ids, adding: adding, in: shots) }
    }

    public func selectAllShots() async {
        let shots = project.shots
        await changeSelection { selection in selection.selectAll(in: shots) }
    }

    /// Back to just the open photo.
    public func collapseSelection() async {
        await changeSelection { selection in selection.collapseToActiveShot() }
    }

    /// Runs `change` and, **only if it moved the open photo**, does the three
    /// things opening a photo does: commit the outgoing document, reset the
    /// viewport, load the incoming document. Extending a selection over photos
    /// that are merely highlighted must not re-decode anything.
    private func changeSelection(_ change: (inout FilmstripSelection) -> Void) async {
        let previous = selection.activeShotID
        var updated = selection
        change(&updated)
        guard updated != selection else { return }
        if updated.activeShotID != previous {
            await commitEditState()
        }
        selection = updated
        guard updated.activeShotID != previous else { return }
        viewport = CanvasViewport()
        await loadActiveEditState()
    }

    /// The shots a paste would write, in project order.
    public var pasteTargetIDs: [ShotID] { selection.selectedIDs(in: project.shots) }

    // MARK: - Copy

    /// Copies `shotID`'s current edits into the clipboard.
    ///
    /// The **open** photo is read from memory, not from disk: the user may have
    /// just dragged a slider, and a drag only reaches `edits/<id>.json` on
    /// commit (``setSlider(_:in:to:)``). Any other photo is read from its file,
    /// which is the only copy of its state that exists.
    public func copySettings(from shotID: ShotID) async {
        guard let shot = project.shot(id: shotID) else { return }
        let state: EditState
        if shotID == activeShot?.id {
            state = activeEditState
        } else {
            let store = self.store
            state = await Task.detached { (try? store.loadEditState(for: shotID)) ?? EditState() }
                .value
        }
        let copied = CopiedSettings(
            preset: Preset(name: shot.originalFileName, from: state),
            sourceShotID: shotID,
            sourceFileName: shot.originalFileName)
        copiedSettings = copied
        lastSettingsMessage =
            copied.isEmpty
            ? "Đã chép thiết lập của \(shot.originalFileName) — ảnh này chưa chỉnh gì, dán sẽ đưa ảnh khác về gốc."
            : "Đã chép thiết lập của \(shot.originalFileName)."
    }

    /// Copies the photo on the canvas.
    public func copySettingsFromActiveShot() async {
        guard let id = activeShot?.id else { return }
        await copySettings(from: id)
    }

    public func clearCopiedSettings() {
        copiedSettings = nil
        lastSettingsMessage = nil
    }

    public func dismissSettingsMessage() { lastSettingsMessage = nil }

    // MARK: - Paste

    /// Whether "Dán thiết lập" should be tappable: something was copied, no
    /// paste is already running, and the selection contains at least one photo
    /// that is **not** the one copied from (pasting a look onto its own source
    /// writes nothing).
    public var canPasteSettingsIntoSelection: Bool {
        canPasteSettings(into: pasteTargetIDs)
    }

    public func canPasteSettings(into ids: [ShotID]) -> Bool {
        guard let copiedSettings, !isPastingSettings else { return false }
        let live = Set(project.shots.map(\.id))
        return ids.contains { $0 != copiedSettings.sourceShotID && live.contains($0) }
    }

    /// Pastes the clipboard onto the batch selection and reports it in
    /// ``lastSettingsMessage``.
    @discardableResult
    public func pasteSettingsIntoSelection() async -> Int {
        let targets = pasteTargetIDs
        let written = await pasteCopiedSettings(to: targets)
        lastSettingsMessage =
            written == 0
            ? "Không có ảnh nào thay đổi."
            : "Đã dán thiết lập cho \(written) ảnh."
        return written
    }

    /// Pastes onto exactly `ids`, and reports it.
    @discardableResult
    public func pasteSettings(to ids: [ShotID]) async -> Int {
        let written = await pasteCopiedSettings(to: ids)
        lastSettingsMessage =
            written == 0
            ? "Không có ảnh nào thay đổi."
            : "Đã dán thiết lập cho \(written) ảnh."
        return written
    }

    /// Applies the clipboard to every shot in `ids` and writes each one.
    ///
    /// `.replace` and not `.merge`: "paste settings" means the target ends up
    /// looking like the source, so sections the source does **not** carry are
    /// cleared rather than left over from whatever the target had before — the
    /// same reason `ProjectStore.autoApplyEditState` uses `.replace`, and the
    /// reason copying an untouched photo resets its targets instead of doing
    /// nothing. `EditState.perImage` is never touched, so a paste cannot
    /// retarget the sliders onto a different face or move a crop.
    ///
    /// Two things that look like details and are not:
    ///
    /// * the **open** photo is written through ``replaceActiveEditState(_:)`` +
    ///   ``commitEditState()``, not through the detached batch, so the GPU
    ///   preview repaints — a paste onto the photo you are looking at has to be
    ///   visible, not just on disk;
    /// * the target list is snapshotted before the first `await`, so changing
    ///   the selection (or navigating) while the batch runs cannot redirect it.
    ///   If the user lands on a photo the batch has just rewritten, its document
    ///   is reloaded at the end.
    ///
    /// Returns the number of photos actually changed; a target that already
    /// looked like the source is skipped and not counted.
    @discardableResult
    public func pasteCopiedSettings(to ids: [ShotID]) async -> Int {
        guard let clipboard = copiedSettings, !isPastingSettings else { return 0 }
        let live = Set(project.shots.map(\.id))
        var seen: Set<ShotID> = []
        let targets = ids.filter { live.contains($0) && seen.insert($0).inserted }
        guard !targets.isEmpty else { return 0 }

        isPastingSettings = true
        defer { isPastingSettings = false }

        // The open photo may carry an uncommitted drag; write it before anything
        // reads `edits/` underneath us.
        await commitEditState()

        let preset = clipboard.preset
        var written = 0
        let openedID = activeShot?.id
        if let openedID, targets.contains(openedID) {
            let updated = activeEditState.applying(preset, mode: .replace)
            if updated != activeEditState {
                replaceActiveEditState(updated)
                await commitEditState()
                written += 1
            }
        }

        let others = targets.filter { $0 != openedID }
        if !others.isEmpty {
            let store = self.store
            written += await Task.detached { () -> Int in
                var count = 0
                for id in others {
                    // One unreadable document must not abort the batch: it is
                    // replaced by a fresh state carrying only the pasted look,
                    // which is what the user asked for anyway.
                    let current = (try? store.loadEditState(for: id)) ?? EditState()
                    let updated = current.applying(preset, mode: .replace)
                    guard updated != current else { continue }
                    do {
                        try store.saveEditState(updated, for: id)
                        count += 1
                    } catch {
                        continue
                    }
                }
                return count
            }.value
        }

        await refreshEditedIndex()
        // The user may have moved to another photo while the batch ran; if that
        // photo is one the batch rewrote, what is on screen is now stale.
        if let now = activeShot?.id, now != openedID, others.contains(now) {
            await loadActiveEditState()
        }
        return written
    }
}
