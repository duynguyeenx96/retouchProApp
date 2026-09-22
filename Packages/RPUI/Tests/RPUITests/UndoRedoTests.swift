import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// Undo / redo / "Đặt lại" (`EditorModel.swift`'s `commitEditState`, `undo`,
/// `redo`, `resetAllSliders`) — user request 2026-09-22: *"tao cần nút reset
/// … tao cần 2 nút undo, redo … phải lưu nhiều thao tác đó vì có thể undo
/// cho tới khi ảnh vừa được import vào"*.
///
/// Uses `TempProject` (EditorModelTests.swift) because the point is the files
/// undo/redo actually write, not just what `activeEditState` says in memory.
@MainActor
@Suite("Undo / redo")
struct UndoRedoTests {

    @Test("A commit is an undo point; undoing writes the previous state to disk")
    func undoReturnsToThePreviousCommit() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(!model.canUndo)

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        #expect(model.canUndo)

        await model.undo()

        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 0)
        #expect(!model.canUndo)
        #expect(model.canRedo)
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(onDisk.isDefault)
    }

    @Test("Redo is the exact inverse of undo")
    func redoReappliesWhatWasUndone() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        await model.undo()

        await model.redo()

        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 20)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(onDisk.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 20)
    }

    @Test("A new edit after undoing clears the redo stack")
    func newEditAfterUndoClearsRedo() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        await model.undo()
        #expect(model.canRedo)

        model.setSlider(ColorSliders.Key.contrast, in: EditState.SectionKey.color, to: 10)
        await model.commitEditState()

        #expect(!model.canRedo)
    }

    @Test("Several commits undo one step at a time, in order")
    func multipleCommitsUndoInOrder() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 10)
        await model.commitEditState()
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 30)
        await model.commitEditState()

        await model.undo()
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 20)
        await model.undo()
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 10)
        await model.undo()
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 0)
        #expect(!model.canUndo)
    }

    @Test("Undoing with nothing to undo, and redoing with nothing to redo, are no-ops")
    func edgesAreNoOps() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let before = model.activeEditState

        await model.undo()
        await model.redo()

        #expect(model.activeEditState == before)
        #expect(!model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("Switching shots clears the history — undo stops at 'as this photo was opened'")
    func switchingShotsClearsHistory() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        #expect(model.canUndo)

        await model.selectNextShot()

        #expect(!model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("\"Đặt lại\" clears every slider and is itself an undo point")
    func resetAllSlidersIsUndoable() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        model.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        await model.commitEditState()

        // `resetAllSliders()` mutates `activeEditState` synchronously (safe
        // to read right away, the same as every other test in this file that
        // reads it straight after a slider call) and fires its own commit on
        // an un-awaited `Task`. Following it with an explicit, awaited
        // `commitEditState()` — a harmless no-op if that Task already ran —
        // is what makes the undo point it pushes deterministically visible
        // before this test moves on to `undo()`; `commitEditState()`'s own
        // doc comment is why calling it twice for the same change is safe.
        model.resetAllSliders()
        #expect(model.activeEditState.isDefault)
        await model.commitEditState()

        await model.undo()

        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 20)
        #expect(model.slider("smooth", in: EditState.SectionKey.skin) == 40)
    }
}
