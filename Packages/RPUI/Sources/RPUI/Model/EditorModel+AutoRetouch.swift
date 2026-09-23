import Foundation
import RPCore

/// "Tự động v1" (docs/PLAN.md §6.5) — the write half of the auto panel.
///
/// Everything here is an ``EditState/applyingAutoRetouch(strength:)`` (a fixed
/// ``Preset`` through `applying(_:mode:)`, RPCore) followed by the same two
/// seams every other edit uses: ``replaceActiveEditState(_:)`` for the canvas,
/// ``commitEditState()`` for disk + one undo step (docs/ADR-0025). No render
/// path, no stored strength.
///
/// **Why it does not reuse the preset panel's "Cường độ" session**
/// (``PresetIntensityPreview``): that session blends *from a baseline* toward a
/// preset, section by section, and has to remember the baseline for as long as
/// the panel is open. The plan settles auto's strength differently — *"nhân hệ
/// số scale [0,1] vào từng giá trị trong Preset trước khi applying … không lưu
/// riêng, tính lại mỗi lần user kéo"* — which is a pure function of the slider
/// position, so there is nothing to open, end or clear on undo, and the slider
/// reads its position back off the document (``AutoRetouch/strength(in:)``).
/// What *is* shared is the contract: drag = memory + GPU only, release = one
/// commit = one undo step.
extension EditorModel {

    /// The overall strength as the slider shows it, `0...100`.
    ///
    /// Read off the four recipe keys of the open document, so undo, redo and
    /// switching shots move it without any bookkeeping here. When the user has
    /// moved one of those four by hand the document is no longer an exact
    /// multiple of the recipe; the slider then sits at the closest one
    /// (``AutoRetouch/estimatedStrength(in:)``) and ``isAutoRetouchExact`` says
    /// so.
    public var autoRetouchStrength: Double {
        (AutoRetouch.strength(in: activeEditState)
            ?? AutoRetouch.estimatedStrength(in: activeEditState)) * 100
    }

    /// `false` when a recipe slider was changed by hand after applying — the
    /// panel says that dragging will put all four back on the recipe.
    public var isAutoRetouchExact: Bool {
        AutoRetouch.strength(in: activeEditState) != nil
    }

    /// "Áp dụng": the recipe at full strength on the open photo, written, one
    /// undo step. Idempotent — pressing it on a photo already at 100 % writes
    /// nothing and records nothing (``commitEditState()`` skips a no-op).
    public func applyAutoRetouch() async {
        guard activeShot != nil else { return }
        replaceActiveEditState(activeEditState.applyingAutoRetouch(strength: 1))
        await commitEditState()
    }

    /// The strength slider moving — memory and GPU preview only. `value` is
    /// the slider's `0...100`.
    public func previewAutoRetouchStrength(_ value: Double) {
        guard activeShot != nil else { return }
        replaceActiveEditState(
            activeEditState.applyingAutoRetouch(strength: Slider.clamp(value) / 100))
    }

    /// The strength slider released: one write, one undo step for the whole
    /// drag.
    public func commitAutoRetouchStrength() async {
        await commitEditState()
    }

    /// The photos "Áp cho ảnh đã chọn" would write — the filmstrip's batch
    /// selection, the open photo included, exactly what "Dán thiết lập" targets.
    public var autoRetouchBatchTargetIDs: [ShotID] { pasteTargetIDs }

    /// Applies the recipe at `strength` (`0...100`) to every shot in `ids`.
    ///
    /// The same write path as pasting settings and "Cả project" preset apply:
    /// the **open** photo through ``replaceActiveEditState(_:)`` +
    /// ``commitEditState()`` so the canvas repaints, every other photo through
    /// `ProjectStore.saveEditStateRecordingHistory` so it gets an undo step in
    /// *its own* persisted history (docs/ADR-0025). Guarded by
    /// ``isPastingSettings`` because it writes the same `edits/<id>.json`
    /// files a paste does, and two batches must not interleave.
    ///
    /// Returns the number of photos actually changed and reports it in
    /// ``lastSettingsMessage`` (the filmstrip's status line).
    @discardableResult
    public func applyAutoRetouch(toShots ids: [ShotID], strength: Double) async -> Int {
        guard !isPastingSettings else { return 0 }
        let live = Set(project.shots.map(\.id))
        var seen: Set<ShotID> = []
        let targets = ids.filter { live.contains($0) && seen.insert($0).inserted }
        guard !targets.isEmpty else { return 0 }
        isPastingSettings = true
        defer { isPastingSettings = false }

        let factor = Slider.clamp(strength) / 100
        await commitEditState()
        var written = 0
        let openedID = activeShot?.id
        if let openedID, targets.contains(openedID) {
            let updated = activeEditState.applyingAutoRetouch(strength: factor)
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
                    let current = (try? store.loadEditState(for: id)) ?? EditState()
                    let updated = current.applyingAutoRetouch(strength: factor)
                    guard updated != current else { continue }
                    do {
                        try store.saveEditStateRecordingHistory(
                            updated, replacing: current, for: id)
                        count += 1
                    } catch {
                        continue
                    }
                }
                return count
            }.value
        }

        await refreshEditedIndex()
        if let now = activeShot?.id, now != openedID, others.contains(now) {
            await loadActiveEditState()
        }
        lastSettingsMessage =
            written == 0
            ? "Không có ảnh nào thay đổi."
            : "Đã áp Tự động cho \(written) ảnh."
        return written
    }
}
