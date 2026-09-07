import Foundation
import Testing
import UniformTypeIdentifiers

import RPCore
import RPEngine
@testable import RPUI

/// Stands in for `App/RPImportShotImporter.swift`, which is what the shipping
/// app injects.
///
/// It is not a mock that only records calls: it does the one thing the real
/// adapter does that this layer cares about — write through `ProjectMutating`,
/// i.e. through the same `ProjectSession` actor as every other write — by
/// copying real files in with `ProjectStore.addShot`. That is exactly the shape
/// RPImport's `ShotIngestor` has (docs/ADR-0003 §1), so a test that passes here
/// says something about the seam and not just about itself.
///
/// The real RPImport call path is covered by `RPImportTests` (per-file results,
/// RAW preserved byte-for-byte, de-duplication) and the adapter that joins the
/// two is covered by `AppTests/RPImportShotImporterTests.swift`.
private struct FakeImporter: ShotImporting {
    /// `identifier -> file to copy in`, so the Photos path can be driven without
    /// PhotoKit.
    var assets: [String: URL] = [:]
    /// Forced outcome for the "one file failed" case.
    var forcedFailureCount = 0

    func importFiles(at urls: [URL], into host: any ProjectMutating) async -> ShotImportSummary {
        await copy(urls.map { (name: $0.lastPathComponent, url: $0) }, into: host)
    }

    func importPhotos(
        withLocalIdentifiers identifiers: [String],
        into host: any ProjectMutating
    ) async -> ShotImportSummary {
        let pairs = identifiers.compactMap { id in assets[id].map { (name: id, url: $0) } }
        return await copy(pairs, into: host)
    }

    private func copy(
        _ items: [(name: String, url: URL)],
        into host: any ProjectMutating
    ) async -> ShotImportSummary {
        var ids: [ShotID] = []
        for item in items {
            let shot = try? await host.withProject { project, store in
                try store.addShot(copyingOriginalAt: item.url, into: &project)
            }
            if let shot { ids.append(shot.id) }
        }
        let failed = forcedFailureCount
        var parts = ["\(ids.count) imported"]
        if failed > 0 { parts.append("\(failed) failed") }
        return ShotImportSummary(
            importedCount: ids.count,
            failedCount: failed,
            importedShotIDs: ids,
            message: parts.joined(separator: ", "),
            detail: parts.joined(separator: ", ")
        )
    }
}

@MainActor
@Suite("Import wiring")
struct ImportWiringTests {
    /// The bug this whole item exists for: a project you cannot get photos into.
    /// Empty project → pick two files → they are in the filmstrip and on disk,
    /// with no close-and-reopen.
    @Test("Files import adds shots and the filmstrip sees them without reopening")
    func filesImportShowsUpImmediately() async throws {
        let temp = try TempProject(shots: 0)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL, importer: FakeImporter())
        #expect(model.canImport)
        #expect(model.shots.isEmpty)
        #expect(model.activeShot == nil)

        let a = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("pick-a.png"), size: 24)
        let b = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("pick-b.png"), size: 26)

        let summary = await model.importFiles(at: [a, b])

        #expect(summary.importedCount == 2)
        #expect(summary.importedShotIDs.count == 2)
        // The snapshot the filmstrip renders from, with no extra `refresh()`
        // from the caller and no reopening of the project.
        #expect(model.shots.count == 2)
        #expect(model.shots.map(\.originalFileName) == ["pick-a.png", "pick-b.png"])
        // A project that had nothing selected now has the first new shot active,
        // and its (empty) EditState has been read.
        #expect(model.activeShot?.originalFileName == "pick-a.png")
        #expect(model.activeEditState.isDefault)
        #expect(model.isImporting == false)
        #expect(model.lastImportMessage == "2 imported")
        #expect(model.lastErrorMessage == nil)
        // And it is really on disk, not only in the snapshot.
        #expect(try temp.reloadedProject().shots.count == 2)
    }

    @Test("Photos import goes through the same seam and lands in the project")
    func photosImportShowsUpImmediately() async throws {
        let temp = try TempProject(shots: 0)
        defer { temp.cleanUp() }

        let asset = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("IMG_0042.png"), size: 30)
        let importer = FakeImporter(assets: ["local-id-42": asset])
        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL, importer: importer)

        let summary = await model.importPhotos(withLocalIdentifiers: ["local-id-42"])

        #expect(summary.importedCount == 1)
        #expect(model.shots.map(\.originalFileName) == ["IMG_0042.png"])
        #expect(try temp.reloadedProject().shots.count == 1)
    }

    /// Importing into a project that already has a shot must not move the user
    /// off what they were editing.
    @Test("An import into a non-empty project keeps the selection and the EditState")
    func importKeepsExistingSelection() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL, importer: FakeImporter())
        await model.selectNextShot()
        model.setSlider("smooth", in: EditState.SectionKey.skin, to: 42)
        await model.commitEditState()
        let selected = try #require(model.activeShot?.id)

        let incoming = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("late.png"), size: 28)
        await model.importFiles(at: [incoming])

        #expect(model.shots.count == 3)
        #expect(model.activeShot?.id == selected)
        #expect(model.activeEditState.slider("smooth", in: EditState.SectionKey.skin) == 42)
    }

    @Test("Failures come back through the error banner, successes through the status line")
    func failuresAreReported() async throws {
        let temp = try TempProject(shots: 0)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL,
            importer: FakeImporter(forcedFailureCount: 1))
        let file = try TempProject.writePNG(
            at: temp.root.appendingPathComponent("one.png"), size: 20)

        let summary = await model.importFiles(at: [file])
        #expect(summary.failedCount == 1)
        #expect(model.lastImportMessage == "1 imported, 1 failed")
        #expect(model.lastErrorMessage == "Import: 1 imported, 1 failed")

        model.dismissImportMessage()
        model.dismissError()
        #expect(model.lastImportMessage == nil)
        #expect(model.lastErrorMessage == nil)
    }

    /// A build with no importer wired (the default) hides the controls rather
    /// than offering a button that does nothing.
    @Test("With no importer the controls are hidden and the calls are no-ops")
    func withoutAnImporter() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.canImport == false)

        let summary = await model.importFiles(at: [temp.root.appendingPathComponent("nope.png")])
        #expect(summary == .empty)
        #expect(model.shots.count == 1)
        #expect(model.lastImportMessage == nil)
    }

    @Test("An empty pick is not reported as an import")
    func emptyPickIsSilent() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL, importer: FakeImporter())
        #expect(await model.importFiles(at: []) == .empty)
        #expect(await model.importPhotos(withLocalIdentifiers: []) == .empty)
        #expect(model.lastImportMessage == nil)
    }

    /// The picker's filter is derived from RPCore's allow-list, so a format added
    /// there cannot become un-pickable without this failing.
    @Test("The file picker offers every importable extension")
    func fileTypesCoverTheAllowList() {
        #expect(ImportFileTypes.allowed.contains(.image))
        // Whatever this machine has no UTType for is still importable through
        // `public.image`; the list is here so the gap is visible rather than
        // silent.
        let missing = ImportFileTypes.extensionsWithoutUTType
        #expect(
            missing.isEmpty,
            "no UTType on this machine for: \(missing.joined(separator: ", "))")
        for ext in ProjectBundle.importableExtensions where !missing.contains(ext) {
            let type = try! #require(UTType(filenameExtension: ext))
            #expect(
                ImportFileTypes.allowed.contains(type) || type.conforms(to: .image),
                "\(ext) would be greyed out in the file picker")
        }
    }

    /// Smoke: the editor chrome that carries the import controls builds, in the
    /// state where it matters most (an empty project, where the filmstrip shows
    /// the two "Add from…" buttons).
    @Test("The editor builds with the import controls on")
    func editorBuildsWithImportControls() async throws {
        let temp = try TempProject(shots: 0)
        defer { temp.cleanUp() }

        let model = try await EditorModel.open(
            bundleURL: temp.store.bundleURL, importer: FakeImporter())
        let cache = PreviewImageCache()
        _ = EditorView(model: model, cache: cache, close: {}).body
        _ = FilmstripView(
            model: model, cache: cache, axis: .vertical,
            importFromFiles: {}, importFromPhotos: {}
        ).body
    }
}
