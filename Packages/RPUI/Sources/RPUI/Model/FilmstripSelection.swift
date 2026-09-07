import Foundation
import RPCore

/// Which shot the filmstrip has selected, and what happens to that selection
/// when the shot list changes underneath it.
///
/// Kept as a value type with no SwiftUI so the awkward cases — the active shot
/// being removed, an import appending shots while the user is looking at one,
/// an empty project — are unit-testable.
public struct FilmstripSelection: Hashable, Sendable {
    public private(set) var activeShotID: ShotID?
    /// Index the active shot last occupied. Used to pick a neighbour when the
    /// active shot disappears, which is what a photographer expects after
    /// deleting a frame: land on the next one, not back at the top.
    private var lastIndex: Int

    public init(activeShotID: ShotID? = nil, lastIndex: Int = 0) {
        self.activeShotID = activeShotID
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

    /// Selects `id` if it is in `shots`; a `nil` or unknown id clears the
    /// selection rather than silently keeping a stale one.
    public mutating func select(_ id: ShotID?, in shots: [Shot]) {
        guard let id, let index = shots.firstIndex(where: { $0.id == id }) else {
            activeShotID = nil
            return
        }
        activeShotID = id
        lastIndex = index
    }

    public mutating func select(index: Int, in shots: [Shot]) {
        guard shots.indices.contains(index) else { return }
        activeShotID = shots[index].id
        lastIndex = index
    }

    /// Reconciles the selection with a new shot list.
    ///
    /// - keeps the active shot when it is still there (its index may have moved);
    /// - falls back to the shot now at the old index, then to the last shot;
    /// - selects the first shot when nothing was selected and shots exist, so
    ///   opening a project always shows something;
    /// - clears when the project is empty.
    public mutating func synchronize(with shots: [Shot]) {
        guard !shots.isEmpty else {
            activeShotID = nil
            lastIndex = 0
            return
        }
        if let index = activeIndex(in: shots) {
            lastIndex = index
            return
        }
        let index = min(lastIndex, shots.count - 1)
        activeShotID = shots[index].id
        lastIndex = index
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
    /// through a shoot is disorienting.
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
}
