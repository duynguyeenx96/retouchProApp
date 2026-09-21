import Foundation
import Testing

import RPCore
@testable import RPUI

/// Lightroom's *Copy Settings* / *Paste Settings*: capture one photo's look in
/// memory, paste it onto the photos the filmstrip has selected.
///
/// Uses `TempProject` (EditorModelTests.swift) — three real PNG shots in a real
/// `.rpproj` bundle — because the point of a paste is the **files it writes**,
/// and asserting on `model.activeEditState` alone would pass even if nothing
/// ever reached `edits/<id>.json`.
@MainActor
@Suite("Copy / paste settings")
struct CopySettingsTests {

    /// A shot with two sliders in two namespaces, so a paste has something to
    /// carry and something to overwrite.
    private func editActiveShot(_ model: EditorModel) async {
        model.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        model.setSlider("exposure", in: EditState.SectionKey.color, to: 25)
        await model.commitEditState()
    }

    @Test("Copying the open photo takes its edits but not its per-image data")
    func copyCapturesTheLook() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await editActiveShot(model)
        model.selectFace(1)

        await model.copySettingsFromActiveShot()

        let copied = try #require(model.copiedSettings)
        #expect(copied.sourceShotID == model.activeShot?.id)
        #expect(copied.isEmpty == false)
        #expect(copied.preset.sections[EditState.SectionKey.skin]?.slider("smooth") == 40)
        #expect(copied.preset.sections[EditState.SectionKey.color]?.slider("exposure") == 25)
        // `Preset` carries sections and nothing else, so the face selection —
        // which lives in `EditState.perImage` — cannot travel with it.
        #expect(
            Set(copied.preset.sections.keys)
                == [EditState.SectionKey.skin, EditState.SectionKey.color])
    }

    @Test("Copying a photo that is not open reads it from disk")
    func copyFromAnotherShot() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let other = temp.project.shots[2].id
        var state = EditState()
        state.setSlider("teeth", in: EditState.SectionKey.eyesTeeth, to: 60)
        try temp.store.saveEditState(state, for: other)

        await model.copySettings(from: other)

        let copied = try #require(model.copiedSettings)
        #expect(copied.sourceShotID == other)
        #expect(copied.preset.sections[EditState.SectionKey.eyesTeeth]?.slider("teeth") == 60)
    }

    @Test("Pasting writes every selected photo, each one its own file")
    func pasteToManyShots() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await editActiveShot(model)
        await model.copySettingsFromActiveShot()
        let source = try #require(model.activeShot?.id)
        let expected = try temp.store.loadEditState(for: source).sections

        // ⌘-click the other two, then paste onto the whole selection.
        await model.toggleSelection(shotID: temp.project.shots[1].id)
        await model.toggleSelection(shotID: temp.project.shots[2].id)
        #expect(model.selection.selectedShotIDs.count == 3)
        #expect(model.canPasteSettingsIntoSelection)

        let written = await model.pasteSettingsIntoSelection()

        // The source already looked like itself, so only the two others changed.
        #expect(written == 2)
        for id in temp.project.shots.map(\.id) {
            #expect(try temp.store.loadEditState(for: id).sections == expected)
        }
        #expect(model.editedShotIDs.count == 3)
        #expect(model.lastSettingsMessage == "Đã dán thiết lập cho 2 ảnh.")
    }

    @Test("Pasting onto the open photo repaints it, not just the file")
    func pasteOntoTheOpenPhoto() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await editActiveShot(model)
        await model.copySettingsFromActiveShot()

        // Open a different photo and paste the copied look onto it.
        let target = temp.project.shots[1].id
        await model.select(shotID: target)
        #expect(model.activeEditState.isDefault)

        let written = await model.pasteCopiedSettings(to: [target])

        #expect(written == 1)
        // In memory — this is what the GPU preview is fed.
        #expect(model.activeEditState.slider("smooth", in: EditState.SectionKey.skin) == 40)
        // …and on disk.
        #expect(
            try temp.store.loadEditState(for: target)
                .slider("exposure", in: EditState.SectionKey.color) == 25)
    }

    @Test("Pasting an untouched photo resets its targets instead of doing nothing")
    func pastingAnEmptyClipboardResets() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)

        // Photo 1 has work on it; photo 0 (open) has none.
        let dirty = temp.project.shots[1].id
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 70)
        try temp.store.saveEditState(state, for: dirty)

        await model.copySettingsFromActiveShot()
        let copied = try #require(model.copiedSettings)
        #expect(copied.isEmpty)

        let written = await model.pasteCopiedSettings(to: [dirty])

        #expect(written == 1)
        #expect(try temp.store.loadEditState(for: dirty).isDefault)
        #expect(model.editedShotIDs.contains(dirty) == false)
    }

    @Test("Paste is disabled with nothing copied, and with only the source selected")
    func pasteIsDisabledWhenItWouldDoNothing() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)

        // (a) nothing copied yet
        #expect(model.canPasteSettingsIntoSelection == false)
        #expect(await model.pasteCopiedSettings(to: model.pasteTargetIDs) == 0)

        // (b) copied, but the selection is just the photo it came from
        await editActiveShot(model)
        await model.copySettingsFromActiveShot()
        #expect(model.canPasteSettingsIntoSelection == false)

        // (c) a second photo joins the selection
        await model.toggleSelection(shotID: temp.project.shots[1].id)
        #expect(model.canPasteSettingsIntoSelection)

        // (d) an empty target list writes nothing rather than crashing
        #expect(await model.pasteCopiedSettings(to: []) == 0)
        // …and so does a target that is no longer in the project.
        #expect(await model.pasteCopiedSettings(to: [ShotID("gone")!]) == 0)
    }

    @Test("Pasting is not confused by a stale target list")
    func staleTargetsAreFiltered() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await editActiveShot(model)
        await model.copySettingsFromActiveShot()

        let removed = temp.project.shots[2].id
        await model.removeShot(removed)

        // The menu was built before the removal and still names three photos.
        let written = await model.pasteCopiedSettings(
            to: temp.project.shots.map(\.id) + [removed, removed])

        #expect(written == 1)  // only shot 1; shot 0 is the source, shot 2 is gone
        #expect(model.shots.count == 2)
    }

    @Test("⌘-clicking another photo opens it and keeps its own edits")
    func toggleSelectionOpensTheShot() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await editActiveShot(model)

        await model.toggleSelection(shotID: temp.project.shots[1].id)

        #expect(model.activeShot?.id == temp.project.shots[1].id)
        #expect(model.activeEditState.isDefault)
        // Leaving the first photo committed it.
        #expect(
            try temp.store.loadEditState(for: temp.project.shots[0].id)
                .slider("smooth", in: EditState.SectionKey.skin) == 40)
    }

    @Test("Extending the selection with ⇧ opens the shot at the end of the range")
    func extendSelectionOpensTheEnd() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)

        await model.extendSelection(toShotID: temp.project.shots[2].id)

        #expect(model.selection.selectedShotIDs.count == 3)
        #expect(model.activeShot?.id == temp.project.shots[2].id)
        #expect(model.pasteTargetIDs == temp.project.shots.map(\.id))
    }
}
