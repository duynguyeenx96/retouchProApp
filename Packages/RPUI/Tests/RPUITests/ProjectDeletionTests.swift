import Foundation
import Testing

import RPCore
@testable import RPUI

/// Deleting a whole project from the library screen (``ProjectsView``'s context
/// menu → ``ProjectsModel/deleteProject(_:)`` → ``ProjectLibrary/deleteProject(at:fileManager:)``).
///
/// The assertions are "gone from the list" *and* "gone from disk", because the
/// reason this exists is disk space: every imported photo is a full copy inside
/// the bundle, so a row disappearing without the folder disappearing would be
/// the bug, not the fix.
@Suite("Project library — delete")
struct ProjectDeletionTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Deleting removes the bundle from entries() and from disk")
    func deleteRemovesBundle() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        let doomed = try library.createProject(named: "Alpha")
        let keeper = try library.createProject(named: "Beta")

        // A real imported copy, so the test proves the photos go too.
        var project = doomed.project
        let source = root.appendingPathComponent("DSC00001.JPG")
        try Data("fake-pixels".utf8).write(to: source)
        let shot = try doomed.store.addShot(copyingOriginalAt: source, into: &project)
        let copiedOriginal = doomed.store.originalURL(for: shot)
        #expect(FileManager.default.fileExists(atPath: copiedOriginal.path))

        try library.deleteProject(at: doomed.store.bundleURL)

        #expect(try library.entries().map(\.name) == ["Beta"])
        #expect(!FileManager.default.fileExists(atPath: doomed.store.bundleURL.path))
        #expect(!FileManager.default.fileExists(atPath: copiedOriginal.path))
        #expect(FileManager.default.fileExists(atPath: keeper.store.bundleURL.path))
        // What the user imported *from* is untouched, as the dialog promises.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("The entry overload deletes the same bundle")
    func deleteByEntry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        try library.createProject(named: "Alpha")
        let entry = try #require(try library.entries().first)

        try library.deleteProject(entry)
        #expect(try library.entries().isEmpty)
    }

    @Test("A broken project — the one you most want gone — can be deleted")
    func deleteUnreadableProject() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let broken = root.appendingPathComponent("Broken.rpproj", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))

        let library = ProjectLibrary(rootURL: root)
        let entry = try #require(try library.entries().first)
        #expect(entry.problem != nil)

        try library.deleteProject(entry)
        #expect(try library.entries().isEmpty)
    }

    @Test("Deleting twice fails cleanly instead of crashing")
    func secondDeleteThrows() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        let created = try library.createProject(named: "Alpha")
        try library.deleteProject(at: created.store.bundleURL)

        #expect(throws: ProjectStoreError.self) {
            try library.deleteProject(at: created.store.bundleURL)
        }
        #expect(try library.entries().isEmpty)
    }

    @Test("A bundle outside the library folder is refused, not removed")
    func refusesBundleOutsideRoot() throws {
        let root = try makeRoot()
        let elsewhere = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let outsider = try ProjectStore.create(name: "Outsider", in: elsewhere)
        #expect(throws: ProjectStoreError.self) {
            try ProjectLibrary(rootURL: root).deleteProject(at: outsider.store.bundleURL)
        }
        #expect(FileManager.default.fileExists(atPath: outsider.store.bundleURL.path))
    }

    @Test("A root given without a trailing slash still matches its own bundles")
    func rootWithoutTrailingSlash() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // `URL(fileURLWithPath:)` with no `isDirectory` hint is what a path read
        // back from defaults or a bookmark looks like.
        let library = ProjectLibrary(rootURL: URL(fileURLWithPath: root.path))
        let created = try library.createProject(named: "Alpha")
        try library.deleteProject(at: created.store.bundleURL)
        #expect(!FileManager.default.fileExists(atPath: created.store.bundleURL.path))
    }

    @Test("The model drops the row and reports nothing wrong")
    @MainActor
    func modelDeletesAndReloads() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ProjectsModel(library: ProjectLibrary(rootURL: root))
        _ = await model.createProject(named: "Alpha")
        _ = await model.createProject(named: "Beta")
        await model.reload()
        let doomed = try #require(model.entries.first { $0.name == "Alpha" })

        let deleted = await model.deleteProject(doomed)
        #expect(deleted)
        #expect(model.entries.map(\.name) == ["Beta"])
        #expect(model.lastErrorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: doomed.bundleURL.path))
    }

    @Test("A stale row reports the failure and re-scans instead of throwing away the list")
    @MainActor
    func modelReportsFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = ProjectsModel(library: ProjectLibrary(rootURL: root))
        _ = await model.createProject(named: "Alpha")
        await model.reload()
        let stale = try #require(model.entries.first)

        // Someone else (Finder, another window) got there first.
        try FileManager.default.removeItem(at: stale.bundleURL)

        let deleted = await model.deleteProject(stale)
        #expect(!deleted)
        #expect(model.lastErrorMessage != nil)
        #expect(model.entries.isEmpty)
    }
}
