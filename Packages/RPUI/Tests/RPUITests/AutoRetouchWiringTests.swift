import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// "Tự động v1" in the editor (docs/PLAN.md §6.5): the rail item, the panel
/// slot, and the write path — apply / strength drag / release / undo / batch —
/// against real project files (`TempProject`).
@MainActor
@Suite("Auto retouch wiring")
struct AutoRetouchWiringTests {
    private let skin = EditState.SectionKey.skin
    private let color = EditState.SectionKey.color

    /// RPCore cannot import RPEngine, so the recipe's key strings are pinned to
    /// the engine's own key lists here — a renamed engine key must fail this
    /// rather than leave auto writing JSON no node reads.
    @Test("Every recipe key is a real engine slider in a real panel, none in Mặt")
    func recipeKeysAreEngineKeys() {
        #expect(
            AutoRetouch.recipe.map(\.key) == [
                SkinSliders.Key.smooth, SkinSliders.Key.evenTone,
                EyesTeethSliders.Key.eyeBrighten, ColorSliders.Key.autoDodgeBurn,
            ])
        for ingredient in AutoRetouch.recipe {
            let panels = SliderPanelLayout.sections(forStorageKey: ingredient.section)
            #expect(
                panels.contains { $0.parameters.contains { $0.key == ingredient.key } },
                "\(ingredient.key)")
            #expect(Slider.range(for: ingredient.key, in: ingredient.section) == Slider.range)
        }
        #expect(
            AutoRetouch.recipe.map { AutoRetouchView.names(for: $0).0 } == [
                "Mịn da", "Đều màu da", "Sáng mắt", "Dodge & Burn tự động",
            ])
    }

    @Test("The rail item opens the auto panel, exclusively, and leaves the group alone")
    func railOpensThePanel() throws {
        let item = try #require(RailLayout.leafItems.first { $0.id == "auto" })
        #expect(item.presentation == .autoRetouch)
        #expect(!item.isLocked)

        let chrome = EditorChrome()
        chrome.activeGroupKey = SliderPanelLayout.PanelKey.eyes
        chrome.isBrushing = true
        chrome.selectRailItem(item)
        #expect(chrome.isShowingAutoRetouch)
        #expect(!chrome.isBrushing)
        #expect(chrome.presetLibrary == nil)
        #expect(chrome.activeGroupKey == SliderPanelLayout.PanelKey.eyes)
        #expect(chrome.isRailItemActive(item))
        #expect(
            RailLayout.leafItems.filter { chrome.isRailItemActive($0) }.map(\.id) == ["auto"])

        // Any other rail item takes the slot back.
        chrome.selectRailItem(RailLayout.colorItem)
        #expect(!chrome.isShowingAutoRetouch)
        chrome.selectRailItem(item)
        let templates = try #require(RailLayout.leafItems.first { $0.id == "templates" })
        chrome.selectRailItem(templates)
        #expect(!chrome.isShowingAutoRetouch)
        #expect(chrome.presetLibrary == .templates)
    }

    @Test("Apply writes the recipe and is exactly one persisted undo step")
    func applyIsOneUndoStep() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let id = try #require(model.activeShot?.id)
        model.setSlider(ColorSliders.Key.exposure, in: color, to: 25)
        await model.commitEditState()

        await model.applyAutoRetouch()
        await model.flushPendingWrites()

        #expect(model.autoRetouchStrength == 100)
        #expect(model.isAutoRetouchExact)
        let onDisk = try temp.store.loadEditState(for: id)
        #expect(onDisk.slider(SkinSliders.Key.smooth, in: skin) == 30)
        #expect(onDisk.slider(ColorSliders.Key.autoDodgeBurn, in: color) == 40)
        #expect(onDisk.slider(ColorSliders.Key.exposure, in: color) == 25)
        #expect(try temp.store.loadShotHistory(for: id).undoSteps.count == 2)

        // Pressing it again at 100 % changes nothing and records nothing.
        await model.applyAutoRetouch()
        await model.flushPendingWrites()
        #expect(try temp.store.loadShotHistory(for: id).undoSteps.count == 2)

        await model.undo()
        #expect(model.slider(SkinSliders.Key.smooth, in: skin) == 0)
        #expect(model.slider(ColorSliders.Key.exposure, in: color) == 25)
        #expect(model.autoRetouchStrength == 0)
        await model.redo()
        #expect(model.autoRetouchStrength == 100)
    }

    @Test("A strength drag previews without writing; release is one undo step")
    func dragThenReleaseIsOneStep() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let id = try #require(model.activeShot?.id)
        await model.applyAutoRetouch()
        await model.flushPendingWrites()
        let stepsAfterApply = try temp.store.loadShotHistory(for: id).undoSteps.count

        for value in stride(from: 100.0, through: 50.0, by: -5) {
            model.previewAutoRetouchStrength(value)
        }
        #expect(model.slider(SkinSliders.Key.smooth, in: skin) == 15)
        #expect(abs(model.autoRetouchStrength - 50) < 1e-9)
        // Nothing on disk moved during the drag.
        #expect(try temp.store.loadEditState(for: id).slider(SkinSliders.Key.smooth, in: skin) == 30)

        await model.commitAutoRetouchStrength()
        await model.flushPendingWrites()
        #expect(try temp.store.loadEditState(for: id).slider(SkinSliders.Key.smooth, in: skin) == 15)
        #expect(try temp.store.loadShotHistory(for: id).undoSteps.count == stepsAfterApply + 1)

        // One Hoàn tác undoes the whole drag, the next one the apply.
        await model.undo()
        #expect(model.autoRetouchStrength == 100)
        await model.undo()
        #expect(model.activeEditState.isDefault)
    }

    @Test("A hand-moved recipe slider makes the strength inexact; dragging restores the recipe")
    func handEditThenDrag() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.applyAutoRetouch()
        model.setSlider(SkinSliders.Key.smooth, in: skin, to: 70)
        await model.commitEditState()
        #expect(!model.isAutoRetouchExact)

        model.previewAutoRetouchStrength(80)
        await model.commitAutoRetouchStrength()
        #expect(model.isAutoRetouchExact)
        #expect(model.slider(SkinSliders.Key.smooth, in: skin) == 24)
    }

    @Test("Áp cho ảnh đã chọn writes every selected photo, each with its own undo step")
    func batchApply() async throws {
        let temp = try TempProject(shots: 3)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let ids = model.shots.map(\.id)
        // A photo that is not selected must not be touched.
        await model.selectShots([ids[0], ids[1]], adding: false)
        #expect(Set(model.autoRetouchBatchTargetIDs) == [ids[0], ids[1]])
        // The other selected photo already has its own work in another section.
        var other = EditState()
        other.setSlider(ColorSliders.Key.contrast, in: color, to: -20)
        try temp.store.saveEditState(other, for: ids[1])

        let written = await model.applyAutoRetouch(
            toShots: model.autoRetouchBatchTargetIDs, strength: 50)
        await model.flushPendingWrites()

        #expect(written == 2)
        for id in [ids[0], ids[1]] {
            let state = try temp.store.loadEditState(for: id)
            #expect(AutoRetouch.strength(in: state) == 0.5, "\(id)")
            #expect(try temp.store.loadShotHistory(for: id).undoSteps.count == 1, "\(id)")
        }
        #expect(
            try temp.store.loadEditState(for: ids[1]).slider(ColorSliders.Key.contrast, in: color)
                == -20)
        #expect(try temp.store.loadEditState(for: ids[2]).isDefault)
    }
}
