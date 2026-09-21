import Foundation
import Testing

@testable import RPCore

/// ``ProjectStore/deleteBundle(fileManager:)`` — the one operation that removes
/// imported originals, so the tests are about *what is gone afterwards*, not
/// about a return value.
///
/// In its own file rather than appended to `ProjectStoreTests` so a destructive
/// operation's coverage is easy to find and to read in one screen.
@Suite("ProjectStore — deleting a whole bundle")
struct ProjectDeleteTests {
    @discardableResult
    private func makeSourceImage(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fake-pixels".utf8).write(to: url)
        return url
    }

    @Test("Deletes the bundle with every copied original inside it")
    func deletesEverything() throws {
        let temp = try TemporaryDirectory("delete")
        let created = try ProjectStore.create(name: "Shoot", in: temp.url)
        let store = created.store
        var project = created.project
        let source = try makeSourceImage("DSC00001.JPG", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        try store.saveEditState(EditState(), for: shot.id)

        let copiedOriginal = store.originalURL(for: shot)
        #expect(FileManager.default.fileExists(atPath: copiedOriginal.path))

        try store.deleteBundle()

        #expect(!FileManager.default.fileExists(atPath: store.bundleURL.path))
        #expect(!FileManager.default.fileExists(atPath: copiedOriginal.path))
        // The file the user imported *from* is not the app's to delete.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try temp.entries() == ["DSC00001.JPG"])
    }

    @Test("Deleting an already-deleted bundle throws instead of crashing")
    func secondDeleteThrows() throws {
        let temp = try TemporaryDirectory("delete")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        try store.deleteBundle()
        #expect(throws: ProjectStoreError.bundleNotFound(path: store.bundleURL.path)) {
            try store.deleteBundle()
        }
    }

    @Test("Refuses a path that is not a .rpproj bundle")
    func refusesNonBundlePath() throws {
        let temp = try TemporaryDirectory("delete")
        let folder = temp.url.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeSourceImage("keep.JPG", in: folder)

        #expect(throws: ProjectStoreError.self) {
            try ProjectStore(bundleURL: folder).deleteBundle()
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Refuses a .rpproj path that is a file, not a directory")
    func refusesFileNamedLikeBundle() throws {
        let temp = try TemporaryDirectory("delete")
        let impostor = temp.url.appendingPathComponent("Shoot.rpproj")
        try Data("not a bundle".utf8).write(to: impostor)

        #expect(throws: ProjectStoreError.self) {
            try ProjectStore(bundleURL: impostor).deleteBundle()
        }
        #expect(FileManager.default.fileExists(atPath: impostor.path))
    }
}
