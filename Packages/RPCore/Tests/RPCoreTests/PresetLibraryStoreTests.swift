import Foundation
import Testing

@testable import RPCore

/// The cross-project preset store and the app-bundle presets behind the "Nổi
/// bật" / "Của tôi" / "Yêu thích" tabs (docs/PLAN.md §Phase 3 items a–c).
@Suite("PresetLibraryStore — the user's cross-project presets")
struct PresetLibraryStoreTests {
    private func makeStore() throws -> (TemporaryDirectory, PresetLibraryStore) {
        let temp = try TemporaryDirectory("preset-library")
        return (temp, PresetLibraryStore(rootURL: temp.url.appendingPathComponent("Library")))
    }

    private func preset(_ name: String, created: TimeInterval = 0) -> Preset {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        state.perImage["selectedFace"] = 1
        return Preset(
            name: name, group: "Mẫu", createdAt: Date(timeIntervalSince1970: created), from: state)
    }

    @Test("Saving lays out presets/<id>.json, the same shape ProjectStore uses")
    func savesOneFilePerPreset() throws {
        let (temp, store) = try makeStore()
        _ = temp
        let saved = preset("Studio")

        try store.savePreset(saved)

        let url = store.presetsURL.appendingPathComponent("\(saved.id.rawValue).json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try store.loadPreset(id: saved.id) == saved)
    }

    @Test("A preset saved here carries no per-image data")
    func dropsPerImage() throws {
        let (temp, store) = try makeStore()
        _ = temp
        let saved = preset("Studio")
        try store.savePreset(saved)

        let text = try String(
            contentsOf: store.presetURL(for: saved.id), encoding: .utf8)
        #expect(!text.contains("perImage"))
        #expect(!text.contains("selectedFace"))
    }

    @Test("Listing is newest first and survives an unreadable file")
    func listsNewestFirst() throws {
        let (temp, store) = try makeStore()
        _ = temp
        let old = preset("Cũ", created: 1_000)
        let new = preset("Mới", created: 2_000)
        try store.savePreset(old)
        try store.savePreset(new)
        try Data("not json".utf8).write(to: store.presetsURL.appendingPathComponent("broken.json"))

        let listed = try store.listPresets()
        #expect(listed.map(\.name) == ["Mới", "Cũ"])
    }

    @Test("Listing an empty library is [] rather than a throw")
    func listsNothingBeforeFirstSave() throws {
        let (temp, store) = try makeStore()
        _ = temp
        #expect(try store.listPresets().isEmpty)
    }

    @Test("Deleting removes the file and the favourite flag with it")
    func deleteClearsFavorite() throws {
        let (temp, store) = try makeStore()
        _ = temp
        let saved = preset("Studio")
        try store.savePreset(saved)
        try store.setFavorite(true, for: saved.id)
        #expect(store.loadFavorites().contains(saved.id))

        try store.deletePreset(id: saved.id)

        #expect(try store.listPresets().isEmpty)
        #expect(!store.loadFavorites().contains(saved.id))
        #expect(throws: ProjectStoreError.self) { try store.loadPreset(id: saved.id) }
    }

    @Test("Favourites persist across a fresh store on the same root")
    func favoritesPersist() throws {
        let (temp, store) = try makeStore()
        let builtIn = try #require(BuiltInPresets.looks.first)
        try store.setFavorite(true, for: builtIn.id)

        // A second store object over the same folder is what a relaunch looks
        // like: the flag must come back, including for a read-only built-in.
        let reopened = PresetLibraryStore(rootURL: temp.url.appendingPathComponent("Library"))
        #expect(reopened.loadFavorites() == [builtIn.id])

        _ = try reopened.setFavorite(false, for: builtIn.id)
        #expect(reopened.loadFavorites().isEmpty)
    }

    @Test("A corrupt favourites file reads as 'nothing starred', not a failure")
    func corruptFavoritesAreEmpty() throws {
        let (temp, store) = try makeStore()
        _ = temp
        try store.createDirectories()
        try Data("{{{".utf8).write(to: store.favoritesURL)
        #expect(store.loadFavorites().isEmpty)
    }

    @Test("The default library is rooted in Application Support, not Documents")
    func defaultRoot() throws {
        let store = try PresetLibraryStore.default()
        #expect(store.rootURL.lastPathComponent == PresetLibraryStore.libraryDirectoryName)
        #expect(
            store.rootURL.deletingLastPathComponent().lastPathComponent
                == PresetLibraryStore.directoryName)
        #expect(store.rootURL.path.contains("Application Support"))
        #expect(!store.rootURL.path.contains("/Documents/"))
    }
}

@Suite("BuiltInPresets — the app-bundle 'Nổi bật' list")
struct BuiltInPresetsTests {
    @Test("The bundle really ships presets (a packaging mistake is invisible otherwise)")
    func bundleIsNotEmpty() {
        #expect(!BuiltInPresets.isEmpty)
        #expect(BuiltInPresets.templates.count == 5)
        #expect(BuiltInPresets.looks.count == 5)
    }

    @Test("The five Looks are the curated list, in the mockup's order")
    func looksAreTheCuratedFive() {
        #expect(
            BuiltInPresets.looks.map(\.name) == ["Gốc", "Tự nhiên", "Normcore", "Sữa", "Điện ảnh"])
    }

    @Test("A Look carries only the colour section, so applying one cannot disturb skin work")
    func looksAreColourOnly() {
        for look in BuiltInPresets.looks {
            #expect(look.carriedSectionNames.isSubset(of: [EditState.SectionKey.color]))
            #expect(look.group == "Looks")
        }
        // "Gốc" is the deliberate empty one: it means "no look", and
        // `applying(_:replacingSections:)` turns that into a reset of `color`.
        #expect(BuiltInPresets.looks[0].isEmpty)
    }

    @Test("Templates carry whole looks and declare the Mẫu group")
    func templatesCarryEverything() {
        for template in BuiltInPresets.templates {
            #expect(template.group == "Mẫu")
            #expect(!template.isEmpty)
            #expect(
                template.carriedSectionNames.isSubset(of: Set(EditState.SectionKey.all)),
                "\(template.name) carries an unknown section")
        }
    }

    @Test("Ids are unique and stable, so a favourite cannot point at two presets")
    func idsAreUnique() {
        let ids = BuiltInPresets.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(BuiltInPresets.preset(id: ids[0])?.id == ids[0])
        #expect(BuiltInPresets.isBuiltIn(ids[0]))
        #expect(!BuiltInPresets.isBuiltIn(PresetID.generate()))
    }

    @Test("Every built-in value is inside its slider's range")
    func valuesAreInRange() {
        for preset in BuiltInPresets.all {
            for (name, section) in preset.sections {
                for (key, raw) in section.values {
                    let range = Slider.range(for: key, in: name)
                    let value = raw.numberValue ?? .nan
                    #expect(
                        range.contains(value),
                        "\(preset.name).\(name).\(key) = \(value) is outside \(range)")
                }
            }
        }
    }

    @Test("kind(of:) reads the group back, so a copied preset keeps its picker")
    func kindRoundTrips() {
        #expect(BuiltInPresets.kind(of: BuiltInPresets.templates[0]) == .template)
        #expect(BuiltInPresets.kind(of: BuiltInPresets.looks[0]) == .look)
        #expect(BuiltInPresets.kind(of: Preset(name: "Không nhóm")) == nil)
    }
}
