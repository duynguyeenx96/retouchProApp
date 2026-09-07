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
