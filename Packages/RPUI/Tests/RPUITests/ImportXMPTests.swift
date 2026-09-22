import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// Importing a Lightroom `.xmp` sidecar — straight into "Của tôi", at full
/// strength, without touching the open photo (`EditorModel+ImportXMP.swift`).
///
/// Uses `TempProject` (EditorModelTests.swift) because the point of an import
/// is the file it writes, and `PresetLibraryTests.TemporaryLibraryRoot` for
/// the same reason `PresetLibraryTests` itself does: a test run must not see
/// — or add to — the presets on the machine it runs on.
@MainActor
@Suite("Import .xmp")
struct ImportXMPTests {

    private static let sampleXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            crs:Exposure2012="+2.5"
            crs:Contrast2012="+20"/>
         </rdf:RDF>
        </x:xmpmeta>
        """

    private func writeSampleXMP(named name: String = "sample-\(UUID().uuidString)") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).xmp")
        try Data(Self.sampleXMP.utf8).write(to: url)
        return url
    }

    private func makeLibrary(_ temp: PresetLibraryTests.TemporaryLibraryRoot) -> PresetLibraryModel {
        PresetLibraryModel(kind: .templates, store: PresetLibraryStore(rootURL: temp.url))
    }

    @Test("Importing writes a Look straight to \"Của tôi\" at full strength, named after the file")
    func importWritesALookImmediately() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let xmpURL = try writeSampleXMP(named: "Anime - Hiep Hoang")
        defer { try? FileManager.default.removeItem(at: xmpURL) }

        let saved = try #require(model.importXMPAsPreset(from: xmpURL, in: library))

        #expect(saved.name == "Anime - Hiep Hoang")
        #expect(saved.group == PresetLibraryKind.looks.groupName)
        // Exposure2012 +2.5 → +100 on the ±5 EV slider's own scale = 50, full strength.
        #expect(saved.sections[EditState.SectionKey.color]?.slider(ColorSliders.Key.exposure) == 50)
        #expect(saved.sections[EditState.SectionKey.color]?.slider(ColorSliders.Key.contrast) == 20)
        #expect(Set(saved.sections.keys) == [EditState.SectionKey.color])

        // On disk…
        let onDisk = try library.store!.listPresets()
        #expect(onDisk.map(\.id) == [saved.id])
        // …and in the exact `PresetLibraryModel` the screen renders from,
        // without closing and reopening the panel — a bug reported
        // 2026-09-22 ("import xong không thấy gì trong danh sách").
        #expect(library.mine.map(\.id) == [saved.id])
    }

    @Test("The open photo is never touched by an import")
    func importDoesNotTouchTheOpenPhoto() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.vibrance, in: EditState.SectionKey.color, to: 12)
        await model.commitEditState()
        let before = model.activeEditState
        let xmpURL = try writeSampleXMP()
        defer { try? FileManager.default.removeItem(at: xmpURL) }

        model.importXMPAsPreset(from: xmpURL, in: library)

        #expect(model.activeEditState == before)
        let onDisk = try temp.store.loadEditState(for: model.activeShot!.id)
        #expect(onDisk == before)
    }

    @Test("A file with none of the fields this app reads is rejected, not silently saved empty")
    func fileWithNoUsableFieldsIsRejected() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString).xmp")
        try Data("<a><b>1</b></a>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = model.importXMPAsPreset(from: url, in: library)

        #expect(saved == nil)
        #expect(model.lastImportMessage != nil)
        #expect(library.mine.isEmpty)
    }

    @Test("Garbage that is not XML at all is rejected with a distinct message")
    func garbageFileIsRejected() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("garbage-\(UUID().uuidString).xmp")
        try Data("not xml at all <<<".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = model.importXMPAsPreset(from: url, in: library)

        #expect(saved == nil)
        #expect(model.lastImportMessage?.contains("không phải file .xmp hợp lệ") == true)
    }

    // MARK: - Several files at once (2026-09-22)

    @Test("Several loose files each land in the default \"Của tôi\" bucket, uncollected")
    func multipleLooseFilesAreIndependent() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let a = try writeSampleXMP(named: "A")
        let b = try writeSampleXMP(named: "B")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        model.importXMPPresets(fromFiles: [a, b], in: library)

        #expect(Set(library.mine.map(\.name)) == ["A", "B"])
        #expect(library.mine.allSatisfy { $0.collection == nil })
        let groups = library.mineGroupedByCollection
        #expect(groups.map(\.title) == ["Của tôi"])
        #expect(groups.first?.presets.count == 2)
    }

    // MARK: - A whole folder (2026-09-22, "nếu import folder thì sẽ tạo 1 group")

    private func writeSampleFolder(named folderName: String, fileNames: [String]) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(folderName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in fileNames {
            try Data(Self.sampleXMP.utf8).write(to: folder.appendingPathComponent("\(name).xmp"))
        }
        return folder
    }

    @Test("A folder's sidecars all land in one group named after the folder")
    func folderImportGroupsByFolderName() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let folder = try writeSampleFolder(named: "Anime Presets", fileNames: ["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: folder) }

        model.importXMPPresets(fromFolder: folder, in: library)

        #expect(library.mine.count == 3)
        #expect(library.mine.allSatisfy { $0.collection == folder.lastPathComponent })
        let groups = library.mineGroupedByCollection
        #expect(groups.map(\.title) == [folder.lastPathComponent])
        #expect(Set(groups[0].presets.map(\.name)) == ["A", "B", "C"])
    }

    @Test("Folder import skips non-.xmp files inside the folder")
    func folderImportSkipsOtherFiles() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let folder = try writeSampleFolder(named: "Mixed", fileNames: ["Real"])
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        defer { try? FileManager.default.removeItem(at: folder) }

        model.importXMPPresets(fromFolder: folder, in: library)

        #expect(library.mine.map(\.name) == ["Real"])
    }

    @Test("An empty folder (no .xmp inside) imports nothing and reports why")
    func emptyFolderReportsAndImportsNothing() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let folder = try writeSampleFolder(named: "Empty", fileNames: [])
        defer { try? FileManager.default.removeItem(at: folder) }

        model.importXMPPresets(fromFolder: folder, in: library)

        #expect(library.mine.isEmpty)
        #expect(model.lastImportMessage != nil)
    }

    @Test("Của tôi is listed first among the groups, ahead of any folder group")
    func mineBucketSortsFirst() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let libraryRoot = try PresetLibraryTests.TemporaryLibraryRoot()
        let library = makeLibrary(libraryRoot)
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let folder = try writeSampleFolder(named: "Batch", fileNames: ["One"])
        let loose = try writeSampleXMP(named: "Loose")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: loose)
        }

        // Folder first, so "Của tôi" is not simply "whichever came first".
        model.importXMPPresets(fromFolder: folder, in: library)
        model.importXMPAsPreset(from: loose, in: library)

        #expect(library.mineGroupedByCollection.map(\.title) == ["Của tôi", folder.lastPathComponent])
    }
}
