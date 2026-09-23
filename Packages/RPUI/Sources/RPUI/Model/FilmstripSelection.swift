import Foundation
import RPCore

/// Which shots the filmstrip has selected, and what happens to that selection
/// when the shot list changes underneath it.
///
/// **Two related ideas, one type** (Lightroom's model, ADR-0002 §1 ordering):
///
/// * ``activeShotID`` — the photo the editor has *open*. Exactly one, ever. The
///   canvas, the slider panel and ``EditorModel/activeEditState`` all follow it.
/// * ``selectedShotIDs`` — the *batch* selection: every photo the next bulk
///   action (copy/paste settings today, batch export later) will act on.
///
/// They are not independent: **the active shot is always a member of the
/// selection**, and a plain click collapses the selection back to `[active]`,
/// so single-select — which is all this app had until now — is just the case
/// `selectedShotIDs == [activeShotID]`. That invariant is why no call site that
/// only knows about `activeShotID` had to change: it keeps meaning "the photo on
/// the canvas". The extra members are drawn dimmer in the strip, the way
/// Lightroom draws everything but the "most selected" cell.
///
/// Kept as a value type with no SwiftUI so the awkward cases — the active shot
/// being removed, an import appending shots while the user is looking at one,
/// an empty project, a batch selection half of which was deleted — are
/// unit-testable.
public struct FilmstripSelection: Hashable, Sendable {
    public private(set) var activeShotID: ShotID?
    /// The batch selection. Empty exactly when ``activeShotID`` is `nil`;
    /// otherwise it always contains ``activeShotID``.
    public private(set) var selectedShotIDs: Set<ShotID> = []
    /// Where a shift-click measures its range from — the last shot the user
    /// picked *without* extending (a plain click, or a ⌘-click). Finder and
    /// Lightroom both pivot around this rather than around the active shot, so
    /// successive shift-clicks grow and shrink one range instead of walking.
    private var anchorShotID: ShotID?
    /// Index the active shot last occupied. Used to pick a neighbour when the
    /// active shot disappears, which is what a photographer expects after
    /// deleting a frame: land on the next one, not back at the top.
    private var lastIndex: Int

    public init(activeShotID: ShotID? = nil, lastIndex: Int = 0) {
        self.activeShotID = activeShotID
        self.selectedShotIDs = activeShotID.map { [$0] } ?? []
        self.anchorShotID = activeShotID
        self.lastIndex = max(0, lastIndex)
    }

    public func activeIndex(in shots: [Shot]) -> Int? {
        guard let activeShotID else { return nil }
        return shots.firstIndex { $0.id == activeShotID }
    }

    public func activeShot(in shots: [Shot]) -> Shot? {
        guard let index = activeIndex(in: shots) else { return nil }
        return shots[index]
    }

    // MARK: - Batch selection

    public func isSelected(_ id: ShotID) -> Bool { selectedShotIDs.contains(id) }

    /// True when the selection is bigger than the open photo, i.e. a bulk action
    /// would hit more than one file.
    public var isMultiSelecting: Bool { selectedShotIDs.count > 1 }

    /// The selection in **project order**, not `Set` order: a batch that writes
    /// files must be reproducible, and the status line counts the same thing the
    /// strip draws.
    public func selectedShots(in shots: [Shot]) -> [Shot] {
        shots.filter { selectedShotIDs.contains($0.id) }
    }

    public func selectedIDs(in shots: [Shot]) -> [ShotID] {
        selectedShots(in: shots).map(\.id)
    }

    /// Selects `id` if it is in `shots`; a `nil` or unknown id clears the
    /// selection rather than silently keeping a stale one.
    ///
    /// A plain click: the batch selection **collapses** to this one shot.
    public mutating func select(_ id: ShotID?, in shots: [Shot]) {
        guard let id, let index = shots.firstIndex(where: { $0.id == id }) else {
            activeShotID = nil
            selectedShotIDs = []
            anchorShotID = nil
            return
        }
        setActive(id, index: index)
        selectedShotIDs = [id]
        anchorShotID = id
    }

    /// A marquee drag over the library grid: the batch becomes exactly `ids`
    /// (or `ids` added to what was there, for a ⌘-drag). The open photo stays
    /// open when it is still in the batch; otherwise the first hit in project
    /// order opens, so the canvas always shows something that is selected.
    /// An empty drag with no ⌘ is a no-op, not "select nothing" — this app has
    /// no "no photo open" state (see ``toggle(_:in:)``).
    @discardableResult
    public mutating func selectSet(_ ids: Set<ShotID>, adding: Bool, in shots: [Shot]) -> Bool {
        let live = Set(shots.map(\.id))
        let hits = ids.intersection(live)
        let batch = adding ? selectedShotIDs.union(hits) : hits
        guard !batch.isEmpty else { return false }
        if let activeShotID, batch.contains(activeShotID) {
            selectedShotIDs = batch
            return true
        }
        guard let index = shots.firstIndex(where: { batch.contains($0.id) }) else { return false }
        setActive(shots[index].id, index: index)
        selectedShotIDs = batch
        anchorShotID = shots[index].id
        return true
    }

    /// Puts back a selection saved in the project's `session.json`
    /// (docs/ADR-0025). Ids no longer in `shots` are dropped; if the saved
    /// active shot is gone, the first surviving selected shot becomes active,
    /// and if nothing survives this is ``synchronize(with:)``'s fresh-open
    /// state. The invariant holds either way: the active shot is selected.
    public mutating func restore(
        activeShotID: ShotID?, selectedShotIDs: Set<ShotID>, in shots: [Shot]
    ) {
        let live = Set(shots.map(\.id))
        let batch = selectedShotIDs.intersection(live)
        let active =
            activeShotID.flatMap { live.contains($0) ? $0 : nil }
            ?? shots.first(where: { batch.contains($0.id) })?.id
        guard let active, let index = shots.firstIndex(where: { $0.id == active }) else {
            synchronize(with: shots)
            return
        }
        setActive(active, index: index)
        self.selectedShotIDs = batch.union([active])
        anchorShotID = active
    }

    public mutating func select(index: Int, in shots: [Shot]) {
        guard shots.indices.contains(index) else { return }
        select(shots[index].id, in: shots)
    }

    /// ⌘-click on macOS, a tap in the phone's "Chọn" mode: adds `id` to the
    /// batch selection, or takes it out again.
    ///
    /// Adding makes `id` the active shot — ⌘-clicking a photo shows it, which is
    /// what both Finder and Lightroom do. Removing the active shot hands
    /// "active" to the nearest shot still selected, so the canvas never ends up
    /// showing something that is not in the selection.
    ///
    /// **Deselecting the last one is a no-op** (Lightroom's rule, not Finder's):
    /// this app has no "no photo open" state to fall back to — the canvas would
    /// go blank — so the final selected shot stays.
    ///
    /// Returns `false` when `id` is not in `shots` or nothing changed.
    @discardableResult
    public mutating func toggle(_ id: ShotID, in shots: [Shot]) -> Bool {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return false }
        if selectedShotIDs.contains(id) {
            guard selectedShotIDs.count > 1 else { return false }
            selectedShotIDs.remove(id)
            if activeShotID == id, let next = nearestSelectedIndex(to: index, in: shots) {
                setActive(shots[next].id, index: next)
            }
        } else {
            selectedShotIDs.insert(id)
            setActive(id, index: index)
        }
        anchorShotID = id
        return true
    }

    /// ⇧-click: selects everything between the anchor and `id`, inclusive, and
    /// makes `id` active. The anchor is left where it was, so a second
    /// shift-click re-measures the range instead of stacking onto the first.
    @discardableResult
    public mutating func selectRange(to id: ShotID, in shots: [Shot]) -> Bool {
        guard let target = shots.firstIndex(where: { $0.id == id }) else { return false }
        let anchorIndex =
            anchorShotID.flatMap { anchor in shots.firstIndex { $0.id == anchor } }
            ?? activeIndex(in: shots)
            ?? target
        let range = min(anchorIndex, target)...max(anchorIndex, target)
        selectedShotIDs = Set(range.map { shots[$0].id })
        setActive(id, index: target)
        anchorShotID = shots[anchorIndex].id
        return true
    }

    /// ⌘A / "Chọn tất cả". Keeps the open photo open.
    public mutating func selectAll(in shots: [Shot]) {
        guard !shots.isEmpty else { return }
        selectedShotIDs = Set(shots.map(\.id))
        if activeIndex(in: shots) == nil {
            setActive(shots[0].id, index: 0)
            anchorShotID = shots[0].id
        }
    }

    /// Drops the batch back to the open photo — leaving the phone's "Chọn" mode,
    /// or "Bỏ chọn".
    public mutating func collapseToActiveShot() {
        guard let activeShotID else {
            selectedShotIDs = []
            anchorShotID = nil
            return
        }
        selectedShotIDs = [activeShotID]
        anchorShotID = activeShotID
    }

    /// Reconciles the selection with a new shot list.
    ///
    /// - drops selected shots that are gone, keeping the rest of the batch;
    /// - keeps the active shot when it is still there (its index may have moved);
    /// - falls back to a surviving member of the batch nearest the old index,
    ///   then to whatever now sits at that index, then to the last shot;
    /// - selects the first shot when nothing was selected and shots exist, so
    ///   opening a project always shows something;
    /// - clears when the project is empty.
    public mutating func synchronize(with shots: [Shot]) {
        guard !shots.isEmpty else {
            activeShotID = nil
            selectedShotIDs = []
            anchorShotID = nil
            lastIndex = 0
            return
        }
        let live = Set(shots.map(\.id))
        selectedShotIDs.formIntersection(live)
        if let anchor = anchorShotID, !live.contains(anchor) { anchorShotID = nil }

        if let index = activeIndex(in: shots), let activeShotID {
            lastIndex = index
            selectedShotIDs.insert(activeShotID)
            if anchorShotID == nil { anchorShotID = activeShotID }
            return
        }
        let fallback = min(lastIndex, shots.count - 1)
        let index = nearestSelectedIndex(to: fallback, in: shots) ?? fallback
        setActive(shots[index].id, index: index)
        selectedShotIDs.insert(shots[index].id)
        if anchorShotID == nil { anchorShotID = shots[index].id }
    }

    @discardableResult
    public mutating func selectNext(in shots: [Shot]) -> Bool {
        step(by: 1, in: shots)
    }

    @discardableResult
    public mutating func selectPrevious(in shots: [Shot]) -> Bool {
        step(by: -1, in: shots)
    }

    /// Moves the selection, stopping at the ends rather than wrapping —
    /// wrapping from the last frame back to the first while arrow-keying
    /// through a shoot is disorienting. Arrow keys **collapse** a batch
    /// selection, the way they do in Lightroom and Finder.
    private mutating func step(by delta: Int, in shots: [Shot]) -> Bool {
        guard !shots.isEmpty else { return false }
        guard let current = activeIndex(in: shots) else {
            select(index: delta > 0 ? 0 : shots.count - 1, in: shots)
            return true
        }
        let next = current + delta
        guard shots.indices.contains(next) else { return false }
        select(index: next, in: shots)
        return true
    }

    private mutating func setActive(_ id: ShotID, index: Int) {
        activeShotID = id
        lastIndex = index
    }

    /// Index of the selected shot closest to `index`, preferring the one *after*
    /// it — the same "land on the next frame" rule ``synchronize(with:)`` uses.
    private func nearestSelectedIndex(to index: Int, in shots: [Shot]) -> Int? {
        let selected = shots.indices.filter { selectedShotIDs.contains(shots[$0].id) }
        guard !selected.isEmpty else { return nil }
        return selected.first { $0 >= index } ?? selected.last
    }
}
