import Foundation
import Testing

import RPCore
@testable import RPUI

@Suite("Filmstrip selection")
struct FilmstripSelectionTests {
    static func shots(_ count: Int) -> [Shot] {
        (0..<count).map {
            Shot(
                id: ShotID("shot-\($0)")!,
                originalFileName: "DSC0000\($0).ARW",
                originalRelativePath: "originals/DSC0000\($0).ARW"
            )
        }
    }

    @Test("Opening a project selects the first shot")
    func synchronizeSelectsFirst() {
        var selection = FilmstripSelection()
        selection.synchronize(with: Self.shots(3))
        #expect(selection.activeShotID == ShotID("shot-0"))
    }

    @Test("A marquee keeps the open photo open when it is inside the band")
    func marqueeKeepsActive() {
        let shots = Self.shots(5)
        var selection = FilmstripSelection()
        selection.synchronize(with: shots)
        selection.select(shots[2].id, in: shots)
        selection.selectSet([shots[1].id, shots[2].id, shots[3].id], adding: false, in: shots)
        #expect(selection.activeShotID == shots[2].id)
        #expect(selection.selectedShotIDs == [shots[1].id, shots[2].id, shots[3].id])
    }

    @Test("A marquee away from the open photo opens its first hit, in project order")
    func marqueeMovesActive() {
        let shots = Self.shots(5)
        var selection = FilmstripSelection()
        selection.synchronize(with: shots)
        selection.selectSet([shots[4].id, shots[3].id], adding: false, in: shots)
        #expect(selection.activeShotID == shots[3].id)
        #expect(selection.selectedShotIDs == [shots[3].id, shots[4].id])
    }

    @Test("⌘-marquee adds to the batch; an empty plain marquee changes nothing")
    func marqueeAddingAndEmpty() {
        let shots = Self.shots(5)
        var selection = FilmstripSelection()
        selection.synchronize(with: shots)
        selection.selectSet([shots[3].id], adding: true, in: shots)
        #expect(selection.selectedShotIDs == [shots[0].id, shots[3].id])
        #expect(selection.activeShotID == shots[0].id)
        let changed = selection.selectSet([], adding: false, in: shots)
        #expect(!changed)
        #expect(selection.selectedShotIDs == [shots[0].id, shots[3].id])
    }

    @Test("An empty project has no selection")
    func emptyProject() {
        var selection = FilmstripSelection()
        selection.synchronize(with: [])
        #expect(selection.activeShotID == nil)
        #expect(selection.activeIndex(in: []) == nil)
        let forward = selection.selectNext(in: [])
        let backward = selection.selectPrevious(in: [])
        #expect(!forward)
        #expect(!backward)
    }

    @Test("An import that appends shots leaves the selection alone")
    func importDoesNotStealSelection() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[1].id, in: shots)

        selection.synchronize(with: shots + Self.shots(6).suffix(3))
        #expect(selection.activeShotID == shots[1].id)
    }

    /// The behaviour a photographer expects after deleting a frame: land on the
    /// neighbour, not back at the top of a 400-shot strip.
    @Test("Removing the active shot lands on the shot that took its place")
    func removalFallsToNeighbour() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[2].id, in: shots)

        var remaining = shots
        remaining.remove(at: 2)
        selection.synchronize(with: remaining)
        #expect(selection.activeShotID == shots[3].id)
    }

    @Test("Removing the last shot falls back to the new last shot")
    func removalAtEnd() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[2].id, in: shots)
        selection.synchronize(with: Array(shots.prefix(2)))
        #expect(selection.activeShotID == shots[1].id)
    }

    @Test("Arrow keys stop at the ends instead of wrapping")
    func steppingStopsAtEnds() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)

        let atStart = selection.selectPrevious(in: shots)
        #expect(atStart == false)
        #expect(selection.activeShotID == shots[0].id)

        let step1 = selection.selectNext(in: shots)
        let step2 = selection.selectNext(in: shots)
        #expect(step1 && step2)
        #expect(selection.activeShotID == shots[2].id)
        let atEnd = selection.selectNext(in: shots)
        #expect(atEnd == false)
        #expect(selection.activeShotID == shots[2].id)
    }

    @Test("Selecting an id that is not in the project clears rather than keeping a stale one")
    func unknownIDClears() {
        let shots = Self.shots(2)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.select(ShotID("not-here")!, in: shots)
        #expect(selection.activeShotID == nil)
    }

    @Test("Stepping from no selection enters at the matching end")
    func steppingFromNoSelection() {
        let shots = Self.shots(3)
        var forward = FilmstripSelection()
        let movedForward = forward.selectNext(in: shots)
        #expect(movedForward)
        #expect(forward.activeShotID == shots[0].id)

        var backward = FilmstripSelection()
        let movedBackward = backward.selectPrevious(in: shots)
        #expect(movedBackward)
        #expect(backward.activeShotID == shots[2].id)
    }

    // MARK: - Multi-select (⌘-click / ⇧-click)

    @Test("A plain selection is a batch of one containing the open photo")
    func singleSelectIsABatchOfOne() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[1].id, in: shots)
        #expect(selection.selectedShotIDs == [shots[1].id])
        #expect(selection.isMultiSelecting == false)
        #expect(selection.isSelected(shots[1].id))
        #expect(selection.isSelected(shots[0].id) == false)
    }

    @Test("⌘-click adds a shot and makes it the open one")
    func commandClickAdds() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        let added = selection.toggle(shots[2].id, in: shots)
        #expect(added)

        #expect(selection.selectedShotIDs == [shots[0].id, shots[2].id])
        #expect(selection.activeShotID == shots[2].id)
        #expect(selection.isMultiSelecting)
        #expect(selection.selectedIDs(in: shots) == [shots[0].id, shots[2].id])
    }

    @Test("⌘-click on a selected shot removes it, handing 'open' to a neighbour")
    func commandClickRemoves() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.toggle(shots[1].id, in: shots)
        selection.toggle(shots[3].id, in: shots)
        #expect(selection.activeShotID == shots[3].id)

        selection.toggle(shots[3].id, in: shots)
        #expect(selection.selectedShotIDs == [shots[0].id, shots[1].id])
        // The open photo has to stay inside the selection.
        #expect(selection.activeShotID == shots[1].id)
    }

    @Test("⌘-click never empties the selection")
    func commandClickKeepsTheLastOne() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[1].id, in: shots)

        let removedLast = selection.toggle(shots[1].id, in: shots)
        #expect(removedLast == false)
        #expect(selection.selectedShotIDs == [shots[1].id])
        #expect(selection.activeShotID == shots[1].id)
    }

    @Test("⇧-click takes the range from the anchor, and re-measures it")
    func shiftClickSelectsARange() {
        let shots = Self.shots(5)
        var selection = FilmstripSelection()
        selection.select(shots[1].id, in: shots)

        let ranged = selection.selectRange(to: shots[3].id, in: shots)
        #expect(ranged)
        #expect(selection.selectedShotIDs == Set(shots[1...3].map(\.id)))
        #expect(selection.activeShotID == shots[3].id)

        // A second shift-click pivots on the same anchor rather than stacking.
        selection.selectRange(to: shots[0].id, in: shots)
        #expect(selection.selectedShotIDs == Set(shots[0...1].map(\.id)))
        #expect(selection.activeShotID == shots[0].id)
    }

    @Test("A plain click collapses the batch back to one")
    func plainClickCollapses() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.selectRange(to: shots[3].id, in: shots)
        #expect(selection.selectedShotIDs.count == 4)

        selection.select(shots[2].id, in: shots)
        #expect(selection.selectedShotIDs == [shots[2].id])
    }

    @Test("Arrow keys collapse the batch too")
    func steppingCollapses() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.selectRange(to: shots[2].id, in: shots)

        let stepped = selection.selectNext(in: shots)
        #expect(stepped)
        #expect(selection.selectedShotIDs == [shots[3].id])
    }

    @Test("Select all, then collapse back to the open photo")
    func selectAllThenCollapse() {
        let shots = Self.shots(3)
        var selection = FilmstripSelection()
        selection.select(shots[1].id, in: shots)
        selection.selectAll(in: shots)
        #expect(selection.selectedShotIDs.count == 3)
        #expect(selection.activeShotID == shots[1].id)

        selection.collapseToActiveShot()
        #expect(selection.selectedShotIDs == [shots[1].id])
    }

    @Test("Removing a shot prunes it from the batch and keeps the rest")
    func synchronizePrunesTheBatch() {
        let shots = Self.shots(4)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.toggle(shots[2].id, in: shots)
        selection.toggle(shots[3].id, in: shots)

        // shot-3 (the open one) is deleted.
        let remaining = Array(shots.prefix(3))
        selection.synchronize(with: remaining)
        #expect(selection.selectedShotIDs == [shots[0].id, shots[2].id])
        // "Open" lands on a surviving member of the batch, not on an unselected
        // neighbour.
        #expect(selection.activeShotID == shots[2].id)
    }

    @Test("Emptying the project clears the batch as well")
    func synchronizeWithNoShotsClearsTheBatch() {
        let shots = Self.shots(2)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        selection.toggle(shots[1].id, in: shots)

        selection.synchronize(with: [])
        #expect(selection.selectedShotIDs.isEmpty)
        #expect(selection.activeShotID == nil)
    }

    @Test("⌘/⇧-click on a shot that is not in the project changes nothing")
    func unknownIDsAreIgnored() {
        let shots = Self.shots(2)
        var selection = FilmstripSelection()
        selection.select(shots[0].id, in: shots)
        let stranger = ShotID("not-here")!

        let toggled = selection.toggle(stranger, in: shots)
        let ranged = selection.selectRange(to: stranger, in: shots)
        #expect(toggled == false)
        #expect(ranged == false)
        #expect(selection.selectedShotIDs == [shots[0].id])
        #expect(selection.activeShotID == shots[0].id)
    }
}

@Suite("Before / after control")
struct BeforeAfterStateTests {
    @Test("The divider can never reach an edge")
    func splitIsClamped() {
        var state = BeforeAfterState()
        state.setSplit(-4)
        #expect(state.splitFraction == BeforeAfterState.splitRange.lowerBound)
        state.setSplit(9)
        #expect(state.splitFraction == BeforeAfterState.splitRange.upperBound)
        state.setSplit(.nan)
        #expect(state.splitFraction == 0.5)
    }

    @Test("Dragging maps view x to a fraction, and a zero-width view is ignored")
    func splitFromDrag() {
        var state = BeforeAfterState()
        state.setSplit(fromX: 300, width: 1200)
        #expect(state.splitFraction == 0.25)
        state.setSplit(fromX: 100, width: 0)
        #expect(state.splitFraction == 0.25)
    }

    @Test("Only the two-image modes need the original decoded as well")
    func needsBothImages() {
        #expect(BeforeAfterState(mode: .off).needsBothImages == false)
        #expect(BeforeAfterState(mode: .split).needsBothImages)
        #expect(BeforeAfterState(mode: .sideBySide).needsBothImages)
    }

    @Test("Hold-to-see-original works from any mode")
    func holdOriginal() {
        var state = BeforeAfterState(mode: .split)
        #expect(!state.showsOriginalFullFrame)
        state.isHoldingOriginal = true
        #expect(state.showsOriginalFullFrame)
    }

    @Test("Cycling visits every mode and returns")
    func cycling() {
        var state = BeforeAfterState()
        var seen: [BeforeAfterMode] = [state.mode]
        for _ in BeforeAfterMode.allCases.dropFirst() {
            state.cycleMode()
            seen.append(state.mode)
        }
        #expect(Set(seen) == Set(BeforeAfterMode.allCases))
        state.cycleMode()
        #expect(state.mode == .off)
    }
}
