import CoreGraphics
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

    /// 2026-09-23 (docs/ADR-0025) — replaces "switching shots clears the
    /// history": each shot keeps its own history, on disk.
    @Test("Each shot keeps its own history across a shot switch")
    func switchingShotsKeepsEachShotsHistory() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let exposure = (ColorSliders.Key.exposure, EditState.SectionKey.color)
        model.setSlider(exposure.0, in: exposure.1, to: 20)
        await model.commitEditState()
        #expect(model.canUndo)

        await model.selectNextShot()
        // The next shot has none of the first shot's history.
        #expect(!model.canUndo)
        #expect(!model.canRedo)

        await model.selectPreviousShot()
        #expect(model.canUndo)
        await model.undo()
        #expect(model.slider(exposure.0, in: exposure.1) == 0)
        #expect(model.canRedo)
    }

    @Test("Slider steps and brush strokes share one timeline, and survive reopening the project")
    func historyPersistsAcrossReopen() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let exposure = (ColorSliders.Key.exposure, EditState.SectionKey.color)
        let size = CGSize(width: 40, height: 40)
        do {
            let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
            model.setSlider(exposure.0, in: exposure.1, to: 10)
            await model.commitEditState()
            model.recordBrushStroke(ExportMaskWiringTests.pixelStroke(), maskSize: size)
            model.setSlider(exposure.0, in: exposure.1, to: 30)
            await model.commitEditState()
            model.recordBrushStroke(ExportMaskWiringTests.pixelStroke(), maskSize: size)
            await model.flushPendingWrites()
            #expect(model.activeStrokes.count == 2)
        }

        // A fresh model on the same bundle — the app relaunched.
        let reopened = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(reopened.activeStrokes.count == 2)
        #expect(reopened.slider(exposure.0, in: exposure.1) == 30)
        #expect(reopened.canUndo)

        // Undo walks back past the reopen, newest first, interleaved.
        await reopened.undo()
        #expect(reopened.activeStrokes.count == 1)
        #expect(reopened.slider(exposure.0, in: exposure.1) == 30)
        await reopened.undo()
        #expect(reopened.slider(exposure.0, in: exposure.1) == 10)
        #expect(reopened.activeStrokes.count == 1)
        await reopened.undo()
        #expect(reopened.activeStrokes.isEmpty)
        await reopened.undo()
        #expect(reopened.slider(exposure.0, in: exposure.1) == 0)
        #expect(!reopened.canUndo)

        // …and what it undid is on disk, redo included.
        await reopened.flushPendingWrites()
        let id = try #require(reopened.activeShot?.id)
        #expect(try temp.store.loadManualMaskStrokes(for: id).isEmpty)
        #expect(try temp.store.loadEditState(for: id).isDefault)
        #expect(try temp.store.loadShotHistory(for: id).redoSteps.count == 4)

        await reopened.redo()
        await reopened.redo()
        #expect(reopened.activeStrokes.count == 1)
        #expect(reopened.slider(exposure.0, in: exposure.1) == 10)
    }

    @Test("Pasting onto a shot that is not open is an undo step in that shot's history")
    func batchWriteIsUndoableOnTheTargetShot() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let exposure = (ColorSliders.Key.exposure, EditState.SectionKey.color)
        let ids = model.shots.map(\.id)
        // Shot 1 has an edit of its own first.
        await model.select(shotID: ids[1])
        model.setSlider(exposure.0, in: exposure.1, to: 5)
        await model.commitEditState()
        // Back on shot 0: copy a look and paste it onto shot 1 (not open).
        await model.select(shotID: ids[0])
        model.setSlider(exposure.0, in: exposure.1, to: 50)
        await model.commitEditState()
        await model.copySettingsFromActiveShot()
        _ = await model.pasteCopiedSettings(to: [ids[1]])

        await model.select(shotID: ids[1])
        #expect(model.slider(exposure.0, in: exposure.1) == 50)
        await model.undo()
        // The paste comes off first, back to shot 1's own edit — not past it.
        #expect(model.slider(exposure.0, in: exposure.1) == 5)
        await model.undo()
        #expect(model.slider(exposure.0, in: exposure.1) == 0)
    }

    /// Review of fb27550: the undo step must reach disk before the edit it
    /// undoes, so a crash between the two never leaves an un-undoable edit.
    @Test("A commit writes its history step before the document; a stroke before its strokes file")
    func historyIsWrittenBeforeTheChange() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        final class Order: @unchecked Sendable {
            let lock = NSLock()
            var names: [String] = []
            func add(_ url: URL) {
                // The temp file sits in the destination's directory; for
                // `edits/` tell the document from the strokes file by what is
                // being written (no strokes exist before this test paints).
                lock.withLock { names.append(url.deletingLastPathComponent().lastPathComponent) }
            }
            var snapshot: [String] { lock.withLock { names } }
        }
        let order = Order()
        let store = ProjectStore(
            bundleURL: temp.store.bundleURL,
            writer: AtomicFileWriter(synchronizesToDisk: false, beforeCommit: { order.add($0) }))
        let project = try store.load().project
        let model = EditorModel(
            session: ProjectSession(store: store, project: project), store: store, project: project)
        await model.loadActiveEditState()

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 20)
        await model.commitEditState()
        await model.flushPendingWrites()
        #expect(order.snapshot == ["history", "edits"])

        model.recordBrushStroke(ExportMaskWiringTests.pixelStroke(), maskSize: CGSize(width: 40, height: 40))
        await model.flushPendingWrites()
        #expect(order.snapshot == ["history", "edits", "history", "edits"])
        let id = try #require(model.activeShot?.id)
        #expect(FileManager.default.fileExists(atPath: store.manualMaskStrokesURL(for: id).path))
    }

    @Test("\"Xoá mask\" is one undoable step that brings every stroke back")
    func clearingStrokesIsUndoable() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let size = CGSize(width: 40, height: 40)
        for _ in 0..<3 {
            model.recordBrushStroke(ExportMaskWiringTests.pixelStroke(), maskSize: size)
        }
        model.clearBrushStrokes()
        #expect(model.activeStrokes.isEmpty)
        await model.undo()
        #expect(model.activeStrokes.count == 3)
        await model.redo()
        #expect(model.activeStrokes.isEmpty)
    }

    @Test("History is capped at ShotHistory.maximumSteps, oldest dropped")
    func historyIsCapped() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let size = CGSize(width: 40, height: 40)
        for _ in 0..<(ShotHistory.maximumSteps + 5) {
            model.recordBrushStroke(ExportMaskWiringTests.pixelStroke(), maskSize: size)
        }
        await model.flushPendingWrites()
        let id = try #require(model.activeShot?.id)
        let onDisk = try temp.store.loadShotHistory(for: id)
        #expect(onDisk.undoSteps.count == ShotHistory.maximumSteps)
        var undone = 0
        while model.canUndo {
            await model.undo()
            undone += 1
        }
        #expect(undone == ShotHistory.maximumSteps)
        // The five oldest strokes are past the cap: still painted, not undoable.
        #expect(model.activeStrokes.count == 5)
    }

    @Test("A corrupt history or strokes file does not stop the shot from opening")
    func corruptSideFilesAreTolerated() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let id = temp.project.shots[0].id
        var state = EditState()
        state.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 25)
        try temp.store.saveEditState(state, for: id)
        try FileManager.default.createDirectory(
            at: temp.store.historyURL, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: temp.store.historyURL(for: id))
        try Data(#"{"formatVersion": 99, "strokes": []}"#.utf8)
            .write(to: temp.store.manualMaskStrokesURL(for: id))

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.activeShot?.id == id)
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == 25)
        #expect(model.activeStrokes.isEmpty)
        #expect(!model.canUndo)
        #expect(model.lastErrorMessage == nil)
        // The next real edit replaces the unreadable history with a good one.
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 30)
        await model.commitEditState()
        await model.flushPendingWrites()
        #expect(try temp.store.loadShotHistory(for: id).undoSteps.count == 1)
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
