import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// The preset library screen's model layer (docs/PLAN.md §Phase 3): what the
/// three tabs contain, and what applying / arming a preset does to the project
/// on disk.
///
/// Every test gives ``PresetLibraryModel`` its own temporary root instead of the
/// real Application Support one, so a test run cannot see — or add to — the
/// presets on the machine it runs on.
@MainActor
@Suite("Preset library")
struct PresetLibraryTests {
    private func makeLibrary(_ temp: TemporaryLibraryRoot, kind: PresetLibraryKind = .templates)
        -> PresetLibraryModel
    {
        PresetLibraryModel(kind: kind, store: PresetLibraryStore(rootURL: temp.url))
    }

    /// A scratch root for the "Của tôi" store.
    final class TemporaryLibraryRoot {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("rpui-presets-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Tabs

    @Test("'Nổi bật' is the bundled list, and it is not empty in this build")
    func featuredTabIsTheBundledList() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()

        #expect(library.tab == .featured)
        #expect(library.visiblePresets.map(\.id) == BuiltInPresets.templates.map(\.id))
        #expect(library.emptyMessage == nil)

        library.kind = .looks
        #expect(library.visiblePresets.map(\.name).first == "Gốc")
        #expect(library.visiblePresets.count == 5)
    }

    @Test("'Của tôi' is empty until something is saved, and says why")
    func mineStartsEmpty() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()
        library.tab = .mine

        #expect(library.visiblePresets.isEmpty)
        #expect(library.emptyMessage?.contains("Chưa có preset nào") == true)
    }

    @Test("A saved preset lands in 'Của tôi' and survives a reload of the same root")
    func savingPersistsAcrossReload() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()

        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 35)
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 10)
        state.perImage["selectedFace"] = 2

        let saved = try #require(library.savePreset(named: "Buổi chụp A", from: state))
        #expect(library.tab == .mine)
        #expect(library.visiblePresets.map(\.id) == [saved.id])
        #expect(saved.group == "Mẫu")
        #expect(saved.sections[EditState.SectionKey.skin]?.slider("smooth") == 35)

        // A second model over the same root is what a relaunch looks like.
        let reopened = makeLibrary(temp)
        await reopened.reload()
        reopened.tab = .mine
        #expect(reopened.visiblePresets.map(\.name) == ["Buổi chụp A"])
    }

    @Test("A preset saved from the Looks picker is colour-only")
    func looksAreSavedColourOnly() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp, kind: .looks)
        await library.reload()

        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 35)
        state.setSlider("exposure", in: EditState.SectionKey.color, to: 10)

        let saved = try #require(library.savePreset(named: "Look A", from: state))
        #expect(saved.carriedSectionNames == [EditState.SectionKey.color])
        #expect(saved.group == "Looks")

        // …and it shows up under Looks, not under Mẫu.
        library.kind = .templates
        library.tab = .mine
        #expect(library.visiblePresets.isEmpty)
        library.kind = .looks
        #expect(library.visiblePresets.map(\.id) == [saved.id])
    }

    @Test("A favourite can be a built-in preset, and persists across a reload")
    func favoritesIncludeBuiltIns() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()

        let builtIn = BuiltInPresets.templates[2]
        library.toggleFavorite(builtIn)
        #expect(library.isFavorite(builtIn))

        library.tab = .favorites
        #expect(library.visiblePresets.map(\.id) == [builtIn.id])

        let reopened = makeLibrary(temp)
        await reopened.reload()
        #expect(reopened.isFavorite(builtIn))

        reopened.toggleFavorite(builtIn)
        #expect(!reopened.isFavorite(builtIn))
        reopened.tab = .favorites
        #expect(reopened.visiblePresets.isEmpty)
        #expect(reopened.emptyMessage == "Chưa đánh dấu preset nào.")
    }

    @Test("Deleting removes one of the user's presets but never a built-in")
    func deleteOnlyTouchesUserPresets() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()

        let saved = try #require(library.savePreset(named: "Tạm", from: EditState()))
        library.delete(saved)
        #expect(library.mineForKind.isEmpty)

        let builtIn = BuiltInPresets.templates[0]
        library.delete(builtIn)
        #expect(BuiltInPresets.templates.contains { $0.id == builtIn.id })
        #expect(library.lastErrorMessage == nil)
    }

    @Test("The default name does not repeat itself")
    func defaultNames() async throws {
        let temp = try TemporaryLibraryRoot()
        let library = makeLibrary(temp)
        await library.reload()

        #expect(library.defaultPresetName() == "Mẫu 1")
        _ = library.savePreset(named: library.defaultPresetName(), from: EditState())
        #expect(library.defaultPresetName() == "Mẫu 2")
    }

    // MARK: - Applying

    @Test("Applying a template to the open photo writes edits/<id>.json")
    func applyToActiveShot() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let preset = BuiltInPresets.templates[0]

        let count = await model.applyPreset(
            preset, replacingSections: PresetLibraryKind.templates.sectionNames)

        #expect(count == 1)
        let target = try #require(model.activeShot?.id)
        let onDisk = try temp.store.loadEditState(for: target)
        #expect(onDisk.sections == preset.sections)
        // The other two are untouched — scope was "this photo".
        for other in temp.project.shots.map(\.id) where other != target {
            #expect(try temp.store.loadEditState(for: other).isDefault)
        }
    }

    @Test("Applying to the whole project writes every shot")
    func applyToAllShots() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let preset = BuiltInPresets.templates[1]

        let count = await model.applyPreset(
            preset, replacingSections: PresetLibraryKind.templates.sectionNames, scope: .allShots)

        #expect(count == 3)
        for id in temp.project.shots.map(\.id) {
            #expect(try temp.store.loadEditState(for: id).sections == preset.sections)
        }
    }

    @Test("A Look replaces only colour, leaving skin work on disk untouched")
    func applyingALookKeepsSkin() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        await model.commitEditState()

        let look = BuiltInPresets.looks[4]  // "Điện ảnh"
        _ = await model.applyPreset(
            look, replacingSections: PresetLibraryKind.looks.sectionNames)

        let target = try #require(model.activeShot?.id)
        let onDisk = try temp.store.loadEditState(for: target)
        #expect(onDisk.slider("smooth", in: EditState.SectionKey.skin) == 40)
        #expect(
            onDisk[section: EditState.SectionKey.color]
                == look.sections[EditState.SectionKey.color])

        // …and "Gốc" (the empty Look) takes the colour back off without
        // disturbing the skin sliders.
        _ = await model.applyPreset(
            BuiltInPresets.looks[0], replacingSections: PresetLibraryKind.looks.sectionNames)
        let reset = try temp.store.loadEditState(for: target)
        #expect(reset[section: EditState.SectionKey.color].isEmpty)
        #expect(reset.slider("smooth", in: EditState.SectionKey.skin) == 40)
    }

    // MARK: - Applying with intensity (2026-09-22, replaces "Áp cho" + "Áp dụng")

    @Test("Selecting a preset previews it live at full strength, uncommitted")
    func selectingPreviewsAtFullStrength() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 5)
        await model.commitEditState()
        let before = model.activeEditState
        let look = BuiltInPresets.looks[4]  // "Điện ảnh"

        model.selectPresetForApply(look)

        #expect(model.presetApply?.presetID == look.id)
        #expect(model.presetApply?.intensity == 100)
        #expect(
            model.activeEditState[section: EditState.SectionKey.color]
                == look.sections[EditState.SectionKey.color])
        // A Look never touches skin, selecting one included.
        #expect(model.slider("smooth", in: EditState.SectionKey.skin) == 40)
        // Nothing has reached disk yet.
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(onDisk == before)
    }

    @Test("\"Gốc\" resets colour to neutral even though it carries no data at all")
    func gocResetsColorToNeutral() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 42)
        await model.commitEditState()
        let goc = BuiltInPresets.looks[0]
        #expect(goc.name == "Gốc")
        #expect(goc.sections.isEmpty)

        model.selectPresetForApply(goc)

        #expect(model.slider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color) == 0)
    }

    @Test("Intensity blends from the baseline toward the preset, and resets keys the preset does not set")
    func intensityBlendsAndResetsUnsetKeys() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.contrast, in: EditState.SectionKey.color, to: -20)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 50)
        await model.commitEditState()
        // "Điện ảnh" sets contrast (18) but not vibrance at all.
        let look = BuiltInPresets.looks[4]
        let section = try #require(look.sections[EditState.SectionKey.color])
        #expect(section.values[ColorSliders.Key.vibrance] == nil)
        let targetContrast = section.slider(ColorSliders.Key.contrast)
        #expect(targetContrast == 18)

        model.selectPresetForApply(look)
        model.setPresetApplyIntensity(50)

        // Halfway from -20 toward the preset's own contrast (18): -1.
        #expect(
            model.slider(ColorSliders.Key.contrast, in: EditState.SectionKey.color)
                == -20 + (targetContrast - -20) * 0.5)
        // Vibrance: the preset does not set it, so it blends toward 0
        // (neutral) — a Look replaces the whole section, not just its own keys.
        #expect(model.slider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color) == 25)
    }

    @Test("Committing writes the current blend to disk and clears the selection")
    func committingWritesToDisk() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let look = BuiltInPresets.looks[4]

        model.selectPresetForApply(look)
        model.setPresetApplyIntensity(40)
        await model.commitPresetApply()

        #expect(model.presetApply == nil)
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(
            onDisk[section: EditState.SectionKey.color]
                == model.activeEditState[section: EditState.SectionKey.color])
        // "Điện ảnh" sets contrast to 18; 40% of the way from the 0 baseline.
        #expect(onDisk.slider(ColorSliders.Key.contrast, in: EditState.SectionKey.color) == 18 * 0.4)
    }

    @Test("Cancelling restores exactly what was there before selecting; nothing reaches disk")
    func cancellingRestoresBaseline() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 5)
        await model.commitEditState()
        let before = model.activeEditState

        model.selectPresetForApply(BuiltInPresets.looks[4])
        model.setPresetApplyIntensity(70)
        model.cancelPresetApply()

        #expect(model.presetApply == nil)
        #expect(model.activeEditState == before)
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(onDisk == before)
    }

    @Test("Switching to a second preset before committing keeps blending from the original baseline")
    func switchingPresetsKeepsTheOriginalBaseline() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 5)
        await model.commitEditState()
        let before = model.activeEditState

        model.selectPresetForApply(BuiltInPresets.looks[4])
        model.selectPresetForApply(BuiltInPresets.looks[1])

        #expect(model.presetApply?.presetID == BuiltInPresets.looks[1].id)
        #expect(
            model.activeEditState[section: EditState.SectionKey.color]
                == BuiltInPresets.looks[1].sections[EditState.SectionKey.color])

        model.cancelPresetApply()
        #expect(model.activeEditState == before)
    }

    @Test("cancelPresetApply with nothing selected is a no-op")
    func cancelWithNoSelectionDoesNothing() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let before = model.activeEditState

        model.cancelPresetApply()

        #expect(model.activeEditState == before)
    }

    // MARK: - Auto-apply

    @Test("Arming a preset copies it into the project so the bundle is self-contained")
    func autoApplyCopiesThePresetIntoTheProject() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let preset = BuiltInPresets.templates[3]

        await model.setAutoApplyPreset(preset)

        #expect(model.isAutoApply(preset))
        let reloaded = try temp.reloadedProject()
        #expect(reloaded.autoApplyPresetID == preset.id)
        // The copy is what makes a moved project keep working: the built-in
        // lives in the app bundle, not in the .rpproj.
        #expect(try temp.store.loadPreset(id: preset.id).sections == preset.sections)
        #expect(reloaded.presetOrder.contains(preset.id))

        // What a new import will start from.
        let seeded = try #require(temp.store.autoApplyEditState(for: reloaded))
        #expect(seeded.sections == preset.sections)

        await model.clearAutoApplyPreset()
        #expect(try temp.reloadedProject().autoApplyPresetID == nil)
        // Disarming leaves the copied preset in the project's own library.
        #expect(try temp.store.listPresets().map(\.id) == [preset.id])
    }

    // MARK: - Device self-test

    /// The env-var gate on ``PresetSelfTest`` — the only part of it that can be
    /// tested off-device. What it *does* is checked by running it on the phone
    /// (`RP_PRESET_SELFTEST=1`), because the two things it exists to catch (an
    /// empty resource bundle, an unwritable Application Support) cannot happen
    /// here.
    @Test("The preset self-test is off unless RP_PRESET_SELFTEST says otherwise")
    func selfTestIsOffByDefault() {
        #expect(PresetSelfTest.target(environment: [:]) == nil)
        #expect(PresetSelfTest.target(environment: [PresetSelfTest.environmentKey: " "]) == nil)
        #expect(
            PresetSelfTest.target(environment: [PresetSelfTest.environmentKey: "1"]) == .firstShot)
        #expect(
            PresetSelfTest.target(environment: [PresetSelfTest.environmentKey: "DSC05259.jpg"])
                == .fileName("DSC05259.jpg"))
    }
}
