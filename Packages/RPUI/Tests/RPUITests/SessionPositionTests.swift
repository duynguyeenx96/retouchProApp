import CoreGraphics
import Foundation
import Testing

import RPCore
@testable import RPUI

/// 2026-09-23 — "a project is a session" (docs/ADR-0025): reopening a project
/// lands on the shot, the selection, the zoom and the tab it was left on.
@MainActor
@Suite("Session position")
struct SessionPositionTests {

    @Test("Open shot, multi-selection, zoom and tab come back after reopening")
    func restoresWhereTheUserLeft() async throws {
        let temp = try TempProject(shots: 4)
        defer { temp.cleanUp() }
        let ids = temp.project.shots.map(\.id)
        do {
            let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
            await model.select(shotID: ids[2])
            await model.toggleSelection(shotID: ids[3])  // ⌘-click: 3 opens, 2 stays selected
            model.viewport.setZoom(
                2, anchor: CGPoint(x: 100, y: 80), viewSize: CGSize(width: 800, height: 600))
            model.noteTab(.edit)
            #expect(model.selection.activeShotID == ids[3])
            #expect(model.selection.selectedShotIDs == [ids[2], ids[3]])
            await model.flushSessionPosition()
        }
        let saved = try #require(try temp.store.loadSessionPosition())
        #expect(saved.activeShotID == ids[3])

        let reopened = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(reopened.selection.activeShotID == ids[3])
        #expect(reopened.selection.selectedShotIDs == [ids[2], ids[3]])
        #expect(reopened.viewport.zoom == 2)
        #expect(!reopened.viewport.isFittingToWindow)
        #expect(reopened.viewport.offset == saved.viewport.map {
            CGSize(width: $0.offsetX, height: $0.offsetY)
        })
        #expect(reopened.restoredTab == .edit)
    }

    @Test("A burst of viewport changes is written once, after it settles")
    func viewportWritesAreDebounced() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        for step in 0..<60 {
            model.viewport.zoom(
                by: 1.01, anchor: CGPoint(x: Double(step), y: 0),
                viewSize: CGSize(width: 500, height: 500))
        }
        // Mid-gesture: nothing on disk yet.
        #expect(!FileManager.default.fileExists(atPath: temp.store.sessionPositionURL.path))
        try await Task.sleep(for: EditorModel.sessionSaveDelay * 3)
        let saved = try #require(try temp.store.loadSessionPosition())
        #expect(abs((saved.viewport?.zoom ?? 0) - Double(model.viewport.zoom)) < 1e-9)
    }

    @Test("Shots that no longer exist are dropped from a restored selection")
    func staleIDsAreDropped() async throws {
        let temp = try TempProject(shots: 3)
        defer { temp.cleanUp() }
        let ids = temp.project.shots.map(\.id)
        try temp.store.saveSessionPosition(
            SessionPosition(
                activeShotID: ShotID("gone-shot")!, selectedShotIDs: [ShotID("gone-shot")!, ids[1]],
                tab: "edit"))
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.selection.activeShotID == ids[1])
        #expect(model.selection.selectedShotIDs == [ids[1]])
    }

    @Test("A missing, corrupt or future session.json opens the project fresh")
    func badSessionFilesOpenFresh() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }
        let first = temp.project.shots[0].id
        for contents in ["", "{ nope", #"{"formatVersion": 42, "activeShotID": "x"}"#] {
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: temp.store.sessionPositionURL)
            } else {
                try Data(contents.utf8).write(to: temp.store.sessionPositionURL)
            }
            let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
            #expect(model.selection.activeShotID == first)
            #expect(model.restoredTab == nil)
            #expect(model.viewport == CanvasViewport())
        }
    }
}
