import Foundation
import Testing

import RPCore
@testable import RPUI

/// Stands in for `App/RPImportShotImporter.swift` the same way
/// `ImportWiringTests.FakeImporter` does: it really copies through
/// `ProjectMutating`, so the assertions say something about the seam.
private struct CopyingImporter: ShotImporting {
    func importFiles(at urls: [URL], into host: any ProjectMutating) async -> ShotImportSummary {
        var ids: [ShotID] = []
        for url in urls {
            let shot = try? await host.withProject { project, store in
                try store.addShot(copyingOriginalAt: url, into: &project)
            }
            if let shot { ids.append(shot.id) }
        }
        return ShotImportSummary(
            importedCount: ids.count,
            importedShotIDs: ids,
            message: "\(ids.count) imported")
    }

    func importPhotos(
        withLocalIdentifiers identifiers: [String],
        into host: any ProjectMutating
    ) async -> ShotImportSummary {
        .empty
    }
}

/// The Share Extension hand-off, at the level `RetouchProRootView` drives it
/// (docs/PLAN.md §Phase 3B item 4). The view itself is not instantiable in a
/// unit test; every step it performs is, and they are performed here in the same
/// order for the same reasons.
@MainActor
@Suite("External open (Share Extension hand-off)")
struct ExternalOpenCoordinatorTests {
    @Test("A request is queued and taken exactly once")
    func takenOnce() {
        let coordinator = ExternalOpenCoordinator()
        #expect(coordinator.pending == nil)

        coordinator.request(fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")])
        #expect(coordinator.pending != nil)

        let taken = coordinator.take()
        #expect(taken?.fileURLs.map(\.lastPathComponent) == ["a.jpg"])
        // The second take is what stops a re-appearing view from creating a
        // second project for the same photo.
        #expect(coordinator.take() == nil)
        #expect(coordinator.pending == nil)
    }

    @Test("The same file is not opened twice in one launch")
    func acceptsEachFileOnce() {
        let coordinator = ExternalOpenCoordinator()
        let file = URL(fileURLWithPath: "/tmp/inbox/a.jpg")
        coordinator.request(fileURLs: [file])
        #expect(coordinator.take() != nil)

        // Both entry points can name the same staged file on a cold start —
        // the `retouchpro://` URL and the launch-time inbox scan.
        coordinator.request(fileURLs: [file])
        #expect(coordinator.pending == nil)

        // A different file in the same request still gets through.
        coordinator.request(fileURLs: [file, URL(fileURLWithPath: "/tmp/inbox/b.jpg")])
        #expect(coordinator.pending?.fileURLs.map(\.lastPathComponent) == ["b.jpg"])
    }

    @Test("An empty request is refused, not queued")
    func emptyRequest() {
        let coordinator = ExternalOpenCoordinator()
        coordinator.request(fileURLs: [])
        #expect(coordinator.pending == nil)
    }

    @Test("A second share replaces the first and gets a new id")
    func replacesPending() {
        let coordinator = ExternalOpenCoordinator()
        coordinator.request(fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let first = coordinator.pending?.id
        coordinator.request(fileURLs: [URL(fileURLWithPath: "/tmp/b.jpg")])
        #expect(coordinator.pending?.id != first)
        #expect(coordinator.pending?.fileURLs.map(\.lastPathComponent) == ["b.jpg"])
    }

    @Test("The default project name is the one the New-project button uses")
    func defaultProjectName() {
        let coordinator = ExternalOpenCoordinator()
        coordinator.request(fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")])
        #expect(coordinator.pending?.projectName == ProjectLibrary.suggestedProjectName())
        #expect(coordinator.pending?.projectName.hasPrefix("Shoot ") == true)
    }

    @Test("Every step logs, so a hand-off that fails on a device leaves a trace")
    func logs() {
        let lines = Recorder()
        let coordinator = ExternalOpenCoordinator(log: { lines.append($0) })
        coordinator.request(fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")])
        coordinator.report("1 imported")
        #expect(lines.all.count == 2)
        #expect(lines.all[0].contains("a.jpg"))
        #expect(lines.all[1].contains("1 imported"))
        #expect(coordinator.lastMessage == "1 imported")
    }

    /// The whole path the root view runs: create a project named like the
    /// New-project button, ingest the handed-over file through the ordinary
    /// import seam, select the shot, then throw the hand-off copy away.
    @Test("Hand-off creates a project, ingests the file, selects it and cleans up")
    func endToEnd() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Stands in for the App Group container the extension writes into.
        let inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let shared = try TempProject.writePNG(
            at: inbox.appendingPathComponent("IMG_0042.png"), size: 32)

        let library = ProjectLibrary(
            rootURL: root.appendingPathComponent("Projects", isDirectory: true))
        let projects = ProjectsModel(library: library)
        let coordinator = ExternalOpenCoordinator()
        coordinator.request(fileURLs: [shared])

        let request = try #require(coordinator.take())
        let bundleURL = try #require(await projects.createProject(named: request.projectName))
        #expect(bundleURL.deletingPathExtension().lastPathComponent == request.projectName)

        let model = try await EditorModel.open(bundleURL: bundleURL, importer: CopyingImporter())
        #expect(model.shots.isEmpty)

        let summary = await model.importFiles(at: request.fileURLs)
        #expect(summary.importedCount == 1)
        let first = try #require(summary.importedShotIDs.first)
        await model.select(shotID: first)

        // The editor is on the shared photo — no library screen, no picker.
        #expect(model.shots.count == 1)
        #expect(model.activeShot?.id == first)
        #expect(model.activeShot?.originalFileName == "IMG_0042.png")
        let onDisk = try #require(model.activeOriginalURL)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        // …and the hand-off buffer is emptied, because the photo now lives in
        // the project (and still lives in Photos).
        #expect(request.removesSourcesAfterImport)
        ShareHandoff.discard(request.fileURLs)
        #expect(FileManager.default.fileExists(atPath: shared.path) == false)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }
}

/// Tiny thread-safe sink so the coordinator's `@Sendable` log closure can be
/// asserted on without a global.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
