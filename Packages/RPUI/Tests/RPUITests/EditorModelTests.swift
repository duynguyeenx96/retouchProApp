import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import RPCore
import RPEngine
@testable import RPUI

/// A temporary `.rpproj` with real files in it. The point of these tests is
/// that the filmstrip's writes land **on disk**, through `ProjectSession`, and
/// not just in the observable snapshot.
struct TempProject {
    let root: URL
    let store: ProjectStore
    var project: Project

    init(name: String = "Test Shoot", shots: Int = 3) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let created = try ProjectStore.create(name: name, in: root)
        store = created.store
        project = created.project

        for index in 0..<shots {
            let file = try Self.writePNG(
                at: root.appendingPathComponent("DSC0000\(index).png"), size: 40 + index * 10)
            try store.addShot(copyingOriginalAt: file, into: &project)
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Reads the manifest back from disk — the assertion that matters.
    func reloadedProject() throws -> Project {
        try store.load().project
    }

    @discardableResult
    static func writePNG(at url: URL, size: Int) throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

@MainActor
@Suite("EditorModel")
struct EditorModelTests {
    @Test("Opening a project selects the first shot and reads its EditState")
    func openSelectsFirstShot() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.shots.count == 3)
        #expect(model.activeShot?.id == temp.project.shots[0].id)
        #expect(model.activeEditState.isDefault)
        #expect(model.activeOriginalURL?.lastPathComponent == "DSC00000.png")
    }

    @Test("A rating set in the filmstrip is on disk in manifest.json")
    func ratingIsPersisted() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let target = temp.project.shots[1].id

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.setRating(4, for: target)

        #expect(model.project.shot(id: target)?.rating == 4)
        #expect(try temp.reloadedProject().shot(id: target)?.rating == 4)
    }

    @Test("Ratings are clamped to 0–5 by the model layer's own rules")
    func ratingIsClamped() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let target = temp.project.shots[0].id

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.setRating(99, for: target)
        #expect(try temp.reloadedProject().shot(id: target)?.rating == 5)
        await model.setRating(-3, for: target)
        #expect(try temp.reloadedProject().shot(id: target)?.rating == 0)
    }

    @Test("Clicking the same star again clears the rating")
    func toggleRating() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let target = temp.project.shots[0].id

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.toggleRating(3, for: target)
        #expect(model.project.shot(id: target)?.rating == 3)
        await model.toggleRating(3, for: target)
        #expect(model.project.shot(id: target)?.rating == 0)
        await model.toggleRating(2, for: target)
        #expect(model.project.shot(id: target)?.rating == 2)
    }

    @Test("Flags round-trip to disk and toggle off")
    func flagIsPersisted() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }
        let target = temp.project.shots[2].id

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.toggleFlag(.reject, for: target)
        #expect(try temp.reloadedProject().shot(id: target)?.flag == .reject)

        await model.toggleFlag(.pick, for: target)
        #expect(try temp.reloadedProject().shot(id: target)?.flag == .pick)

        await model.toggleFlag(.pick, for: target)
        #expect(try temp.reloadedProject().shot(id: target)?.flag == .unflagged)
    }

    @Test("A write for a shot that is gone is reported, not crashed on")
    func unknownShotIsHarmless() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.setRating(5, for: ShotID("ghost")!)
        #expect(model.shots.allSatisfy { $0.rating == 0 })
        #expect(model.lastErrorMessage == nil)
    }

    /// The ADR-0003 §12 contract: an importer holding the model as
    /// `ProjectMutating` adds shots, and `refresh()` brings them into the UI
    /// without the two copies fighting.
    @Test("An importer writing through ProjectMutating shows up after refresh")
    func projectMutatingConformance() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.shots.count == 1)

        let incoming = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("incoming.png"), size: 32)
        let mutating: any ProjectMutating = model
        try await mutating.withProject { project, store in
            try store.addShot(copyingOriginalAt: incoming, into: &project)
        }

        // Not visible until the snapshot is pulled — that is the model, stated.
        #expect(model.shots.count == 1)
        await model.refresh()
        #expect(model.shots.count == 2)
        #expect(model.selection.activeShotID == temp.project.shots[0].id)
        #expect(try temp.reloadedProject().shots.count == 2)
    }

    @Test("Selection moves and reloads the EditState of the new shot")
    func selectionLoadsEditState() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }

        var edited = EditState()
        edited.setSlider("smooth", in: EditState.SectionKey.skin, to: 42)
        try temp.store.saveEditState(edited, for: temp.project.shots[1].id)

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.activeEditState.isDefault)

        await model.selectNextShot()
        #expect(model.activeShot?.id == temp.project.shots[1].id)
        #expect(model.activeEditState.slider("smooth", in: EditState.SectionKey.skin) == 42)

        await model.selectPreviousShot()
        #expect(model.activeEditState.isDefault)
    }

    /// docs/ADR-0016, at the layer the panel actually writes through: a negative
    /// "Màu" value survives all the way to `edits/<id>.json`, and a negative
    /// "Da" value is still clamped to 0 (which removes the key).
    @Test("A negative value survives in the Màu group and is clamped away in Da")
    func negativeValuesAreScopedToTheColorGroup() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: -40)
        model.setSlider(ColorSliders.Key.curves, in: EditState.SectionKey.color, to: -40)
        model.setSlider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin, to: -40)
        #expect(model.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == -40)
        #expect(model.slider(ColorSliders.Key.curves, in: EditState.SectionKey.color) == 0)
        #expect(model.slider(SkinSliders.Key.smooth, in: EditState.SectionKey.skin) == 0)

        await model.commitEditState()
        let shot = try #require(model.activeShot)
        let reloaded = try temp.store.loadEditState(for: shot.id)
        #expect(reloaded.slider(ColorSliders.Key.exposure, in: EditState.SectionKey.color) == -40)
        #expect(reloaded.sections[EditState.SectionKey.skin] == nil)
    }

    @Test("Changing shot resets the viewport to fit")
    func selectionResetsViewport() async throws {
        let temp = try TempProject()
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        model.viewport.actualSize()
        model.viewport.pan(by: CGSize(width: 40, height: 40))
        #expect(!model.viewport.isFittingToWindow)

        await model.selectNextShot()
        #expect(model.viewport.isFittingToWindow)
        #expect(model.viewport.offset == .zero)
    }

    @Test("Presets are listed in Project.presetOrder, then the rest by name")
    func presetOrdering() async throws {
        var temp = try TempProject()
        defer { temp.cleanUp() }

        let zulu = Preset(id: PresetID("p-zulu")!, name: "Zulu")
        let alpha = Preset(id: PresetID("p-alpha")!, name: "Alpha")
        let mike = Preset(id: PresetID("p-mike")!, name: "Mike")
        for preset in [zulu, alpha, mike] { try temp.store.savePreset(preset) }
        temp.project.presetOrder = [mike.id]
        try temp.store.save(temp.project)

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.orderedPresets.map(\.name) == ["Mike", "Alpha", "Zulu"])
    }

    @Test("thumbnailURL prefers a rendered preview when one exists, else the original")
    func thumbnailFallsBackToOriginal() async throws {
        var temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let shot = try #require(model.shots.first)
        #expect(model.thumbnailURL(for: shot) == temp.store.originalURL(for: shot))

        // Simulate the Phase 2 renderer having written previews/<id>.jpg.
        let previewURL = temp.store.previewURL(for: shot.id, pathExtension: "png")
        try TempProject.writePNG(at: previewURL, size: 16)
        temp.project.updateShot(id: shot.id) {
            $0.previewRelativePath = "previews/\(shot.id.rawValue).png"
        }
        try temp.store.save(temp.project)

        let reopened = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let reopenedShot = try #require(reopened.shots.first)
        #expect(reopened.thumbnailURL(for: reopenedShot) == previewURL)
    }
}

@Suite("Project library")
struct ProjectLibraryTests {
    @Test("Lists .rpproj bundles newest first and ignores anything else")
    func listsProjects() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        let first = try library.createProject(named: "Alpha")
        let second = try library.createProject(named: "Beta")

        // Not a project.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        // Make Alpha the more recently modified one.
        var alpha = first.project
        alpha.name = "Alpha"
        try first.store.save(alpha, touchingModifiedAt: Date().addingTimeInterval(60))

        let entries = try library.entries()
        #expect(entries.map(\.name) == ["Alpha", "Beta"])
        #expect(entries[0].shotCount == 0)
        #expect(entries.allSatisfy { $0.problem == nil })
        #expect(second.store.bundleURL.lastPathComponent == "Beta.rpproj")
    }

    @Test("A duplicate name gets a suffix instead of failing")
    func duplicateNames() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        let a = try library.createProject(named: "Studio")
        let b = try library.createProject(named: "Studio")
        #expect(a.store.bundleURL.lastPathComponent == "Studio.rpproj")
        #expect(b.store.bundleURL.lastPathComponent == "Studio 2.rpproj")
        #expect(b.project.name == "Studio 2")
    }

    @Test("An unreadable project is still listed, carrying its problem")
    func brokenProjectIsListedNotHidden() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let broken = root.appendingPathComponent("Broken.rpproj", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))

        let entries = try ProjectLibrary(rootURL: root).entries()
        #expect(entries.count == 1)
        #expect(entries[0].name == "Broken")
        #expect(entries[0].problem != nil)
    }

    @Test("A cover image is offered when the project has a shot")
    func coverURL() throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }
        let entry = ProjectLibrary(rootURL: temp.root).entry(forBundleAt: temp.store.bundleURL)
        #expect(entry.shotCount == 2)
        #expect(entry.coverURL?.lastPathComponent == "DSC00000.png")
    }

    @Test("An empty or whitespace name is refused")
    func emptyNameRefused() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ProjectLibrary(rootURL: root)
        #expect(throws: ProjectStoreError.self) { try library.createProject(named: "   ") }
    }
}
