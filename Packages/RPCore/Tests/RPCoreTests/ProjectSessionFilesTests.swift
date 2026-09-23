import Foundation
import Testing

@testable import RPCore

/// 2026-09-23 — "a project is a session" (docs/ADR-0025): brush strokes,
/// per-shot undo history and `session.json`, as files in the bundle.
@Suite("Project session files")
struct ProjectSessionFilesTests {

    static let stroke = ManualMaskStroke(
        radius: 0.03125, hardness: 0.5, flow: 1, mode: .add,
        points: [
            .init(x: 0.1, y: 0.2, pressure: 1),
            .init(x: 0.123456789012345, y: 0.987654321, pressure: 0.35),
        ])

    // MARK: - Strokes

    @Test("Strokes round-trip through edits/<id>.strokes.json exactly, in normalised units")
    func strokesRoundTrip() throws {
        let temp = try TemporaryDirectory("strokes")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = ShotID("shot-1")!
        #expect(try store.loadManualMaskStrokes(for: shot).isEmpty)

        let erase = ManualMaskStroke(
            radius: 0.01, hardness: 1, flow: 0.5, mode: .subtract, points: [.init(x: 1, y: 0)])
        try store.saveManualMaskStrokes([Self.stroke, erase], for: shot)
        let url = store.bundleURL.appendingPathComponent("edits/shot-1.strokes.json")
        #expect(url == store.manualMaskStrokesURL(for: shot))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Doubles survive JSON bit for bit (shortest round-tripping repr).
        #expect(try store.loadManualMaskStrokes(for: shot) == [Self.stroke, erase])

        // Compact: points are one flat number array, not objects.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""points":[0.1,0.2,1,"#))
        #expect(text.contains(#""formatVersion":1"#))

        // Empty ⇒ no file (same rule as an untouched edits/<id>.json).
        try store.saveManualMaskStrokes([], for: shot)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A malformed or future strokes file throws; the loader never half-reads it")
    func strokesDecodeIsStrict() throws {
        let decoder = RPJSON.decoder
        let odd = #"{"formatVersion":1,"strokes":[{"radius":0.1,"points":[0.1,0.2]}]}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(ManualMaskStrokeDocument.self, from: Data(odd.utf8))
        }
        let future = #"{"formatVersion":2,"strokes":[]}"#
        #expect(throws: ProjectStoreError.unsupportedFormatVersion(found: 2, supported: 1)) {
            try decoder.decode(ManualMaskStrokeDocument.self, from: Data(future.utf8))
        }
        // Optional fields default; a minimal stroke decodes.
        let minimal = #"{"formatVersion":1,"strokes":[{"radius":0.1,"points":[0.5,0.5,1]}]}"#
        let doc = try decoder.decode(ManualMaskStrokeDocument.self, from: Data(minimal.utf8))
        #expect(doc.strokes == [
            ManualMaskStroke(
                radius: 0.1, hardness: 0.5, flow: 1, mode: .add, points: [.init(x: 0.5, y: 0.5)])
        ])
    }

    // MARK: - History

    @Test("History steps apply and invert; undo/redo walk one timeline")
    func historyModel() {
        var snapshot = ShotSnapshot()
        var history = ShotHistory()
        var edited = EditState()
        edited.setSlider("exposure", in: "color", to: 40)

        // A slider commit, then a stroke, then a clear.
        history.record(.edit(snapshot.editState))
        snapshot.editState = edited
        history.record(.removeLastStroke)
        snapshot.strokes.append(Self.stroke)
        history.record(.replaceStrokes(snapshot.strokes))
        snapshot.strokes = []

        let step1 = history.undo(&snapshot)
        #expect(step1)
        #expect(snapshot.strokes == [Self.stroke])
        let step2 = history.undo(&snapshot)
        #expect(step2)
        #expect(snapshot.strokes.isEmpty)
        #expect(snapshot.editState == edited)
        let step3 = history.undo(&snapshot)
        #expect(step3)
        #expect(snapshot.editState == EditState())
        let step4 = history.undo(&snapshot)
        #expect(!step4)

        let step5 = history.redo(&snapshot)
        #expect(step5)
        let step6 = history.redo(&snapshot)
        #expect(step6)
        #expect(snapshot.strokes == [Self.stroke])
        #expect(snapshot.editState == edited)
        // The redo entry for a stroke carries the stroke; the undo entry does not.
        #expect(history.undoSteps.last == .removeLastStroke)
        #expect(history.redoSteps == [.replaceStrokes([])])
    }

    @Test("A new action clears redo, and each stack is capped at maximumSteps")
    func historyRecordAndCap() {
        var history = ShotHistory()
        var snapshot = ShotSnapshot(strokes: [Self.stroke])
        history.record(.removeLastStroke)
        let step7 = history.undo(&snapshot)
        #expect(step7)
        #expect(history.canRedo)
        history.record(.edit(EditState()))
        #expect(!history.canRedo)

        for _ in 0..<(ShotHistory.maximumSteps + 20) { history.record(.removeLastStroke) }
        #expect(history.undoSteps.count == ShotHistory.maximumSteps)
    }

    @Test("A step that no longer applies is skipped, not fatal")
    func inconsistentStepIsSkipped() {
        var history = ShotHistory(undoSteps: [.edit(EditState()), .removeLastStroke])
        var snapshot = ShotSnapshot()
        var edited = EditState()
        edited.setSlider("exposure", in: "color", to: 5)
        snapshot.editState = edited
        // `removeLastStroke` with no strokes is skipped; the edit below applies.
        let step8 = history.undo(&snapshot)
        #expect(step8)
        #expect(snapshot.editState == EditState())
    }

    @Test("History round-trips through history/<id>.json, and an empty one deletes it")
    func historyPersists() throws {
        let temp = try TemporaryDirectory("history")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = ShotID("shot-1")!
        #expect(try store.loadShotHistory(for: shot).isEmpty)

        var edited = EditState()
        edited.setSlider("smooth", in: "skin", to: 30)
        let history = ShotHistory(
            undoSteps: [.edit(edited), .removeLastStroke, .replaceStrokes([Self.stroke])],
            redoSteps: [.appendStroke(Self.stroke)])
        try store.saveShotHistory(history, for: shot)
        #expect(FileManager.default.fileExists(
            atPath: store.bundleURL.appendingPathComponent("history/shot-1.json").path))
        #expect(try store.loadShotHistory(for: shot) == history)

        try store.saveShotHistory(ShotHistory(), for: shot)
        #expect(!FileManager.default.fileExists(atPath: store.historyURL(for: shot).path))

        let future = #"{"formatVersion":9,"undo":[],"redo":[]}"#
        try FileManager.default.createDirectory(at: store.historyURL, withIntermediateDirectories: true)
        try Data(future.utf8).write(to: store.historyURL(for: shot))
        #expect(throws: ProjectStoreError.self) { try store.loadShotHistory(for: shot) }
    }

    @Test("A batch write lands its history step before the document it undoes")
    func batchWriteOrdersHistoryFirst() throws {
        let temp = try TemporaryDirectory("order")
        final class Names: @unchecked Sendable {
            let lock = NSLock()
            var list: [String] = []
        }
        let names = Names()
        let (created, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let store = ProjectStore(
            bundleURL: created.bundleURL,
            writer: AtomicFileWriter(synchronizesToDisk: false, beforeCommit: { url in
                names.lock.withLock { names.list.append(url.deletingLastPathComponent().lastPathComponent) }
            }))
        var pasted = EditState()
        pasted.setSlider("exposure", in: "color", to: 50)
        let shot = ShotID("shot-1")!
        try store.saveEditStateRecordingHistory(pasted, replacing: EditState(), for: shot)
        #expect(names.lock.withLock { names.list } == ["history", "edits"])

        // A failure writing the document leaves the step, never the reverse.
        let failing = ProjectStore(
            bundleURL: created.bundleURL,
            writer: AtomicFileWriter(synchronizesToDisk: false, beforeCommit: { url in
                if url.deletingLastPathComponent().lastPathComponent == "edits" {
                    throw CocoaError(.fileWriteUnknown)
                }
            }))
        var again = pasted
        again.setSlider("exposure", in: "color", to: 80)
        #expect(throws: (any Error).self) {
            try failing.saveEditStateRecordingHistory(again, replacing: pasted, for: shot)
        }
        #expect(try store.loadShotHistory(for: shot).undoSteps.count == 2)
        #expect(try store.loadEditState(for: shot) == pasted)
    }

    // MARK: - Session position

    @Test("session.json round-trips, and tolerates bad ids and a bad viewport")
    func sessionPosition() throws {
        let temp = try TemporaryDirectory("session")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        #expect(try store.loadSessionPosition() == nil)

        let position = SessionPosition(
            activeShotID: ShotID("b")!, selectedShotIDs: [ShotID("b")!, ShotID("a")!], tab: "edit",
            viewport: .init(zoom: 2.5, offsetX: -40, offsetY: 12.25, fitsWindow: false))
        try store.saveSessionPosition(position)
        let loaded = try #require(try store.loadSessionPosition())
        #expect(loaded.activeShotID == position.activeShotID)
        #expect(Set(loaded.selectedShotIDs) == Set(position.selectedShotIDs))
        #expect(loaded.tab == "edit")
        #expect(loaded.viewport == position.viewport)

        let messy = #"""
            {"formatVersion":1,"activeShotID":"../evil","selectedShotIDs":["ok","a/b",""],
             "viewport":{"zoom":"big"},"tab":7}
            """#
        let decoded = try RPJSON.decoder.decode(SessionPosition.self, from: Data(messy.utf8))
        #expect(decoded.activeShotID == nil)
        #expect(decoded.selectedShotIDs == [ShotID("ok")!])
        #expect(decoded.viewport == nil)
        #expect(decoded.tab == nil)
    }

    // MARK: - Removal and layout

    @Test("Removing a shot deletes its strokes and history, and no masks/ dir is created")
    func removeShotCleansUp() throws {
        let temp = try TemporaryDirectory("remove")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let source = temp.url.appendingPathComponent("DSC1.jpg")
        try Data("pixels".utf8).write(to: source)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        #expect(!FileManager.default.fileExists(atPath: store.masksURL.path))
        #expect(FileManager.default.fileExists(atPath: store.historyURL.path))

        try store.saveManualMaskStrokes([Self.stroke], for: shot.id)
        try store.saveShotHistory(ShotHistory(undoSteps: [.removeLastStroke]), for: shot.id)
        try store.removeShot(id: shot.id, from: &project)
        #expect(!FileManager.default.fileExists(atPath: store.manualMaskStrokesURL(for: shot.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.historyURL(for: shot.id).path))
        _ = store
    }
}
