import Foundation
import Testing

@testable import RPCore

/// Phase 6.1 — where a hand-painted mask lives, and how a document points at it
/// (docs/PLAN.md §6.1, docs/ADR-0019).
///
/// **Superseded 2026-09-23** for the brush, which is now stored as strokes
/// (`ProjectSessionFilesTests`). The generic `masks/` API these tests pin is
/// kept for `removeShot`'s clean-up and has no writer in the app.
///
/// What is left pinned here: the bytes go to `masks/<shot id>/<mask id>.png`
/// inside the `.rpproj` bundle and are cleaned up with the shot. The `perImage`
/// reference half (`ManualMaskReference`) was removed after the fb27550 review:
/// nothing wrote `perImage["manualMask"]` any more.
@Suite("Phase 6.1 manual mask storage")
struct ManualMaskStorageTests {
    /// Stand-in "PNG": nothing here decodes it, and using real pixels would test
    /// ImageIO rather than the store.
    private let pixels = Data("not-really-a-png".utf8)

    private func makeSourceImage(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fake-pixels".utf8).write(to: url)
        return url
    }

    // MARK: - The path

    @Test("A mask lands at masks/<shot id>/<mask id>.png and reads back")
    func maskRoundTripsThroughTheBundle() throws {
        let temp = try TemporaryDirectory("masks")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = ShotID("shot-1")!
        let mask = MaskID("mask-a")!

        #expect(try store.loadMaskData(for: shot, maskID: mask) == nil)

        try store.saveMask(pixels, for: shot, maskID: mask)

        let expected = store.bundleURL
            .appendingPathComponent("masks/shot-1/mask-a.png")
        #expect(store.maskURL(for: shot, maskID: mask) == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(try store.loadMaskData(for: shot, maskID: mask) == pixels)
        #expect(try store.maskIDs(for: shot) == [mask])
    }

    @Test("A missing mask reads as nil rather than throwing")
    func missingMaskIsNotAnError() throws {
        let temp = try TemporaryDirectory("masks")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        // The normal case for every shot in a project, and the case where a user
        // deleted the file by hand — a document that opens must keep opening.
        #expect(try store.loadMaskData(for: ShotID("nobody")!, maskID: MaskID("nothing")!) == nil)
        #expect(try store.maskIDs(for: ShotID("nobody")!).isEmpty)
        #expect(throws: Never.self) {
            try store.deleteMask(for: ShotID("nobody")!, maskID: MaskID("nothing")!)
        }
    }

    @Test("Deleting a shot takes its masks with it")
    func removingAShotDeletesItsMasks() throws {
        let temp = try TemporaryDirectory("masks")
        let (store, project0) = try ProjectStore.create(name: "Shoot", in: temp.url)
        var project = project0
        let source = try makeSourceImage("DSC0001.JPG", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        try store.saveMask(pixels, for: shot.id, maskID: MaskID("mask-a")!)
        try store.saveMask(pixels, for: shot.id, maskID: MaskID("mask-b")!)
        #expect(try store.maskIDs(for: shot.id).count == 2)

        _ = try store.removeShot(id: shot.id, from: &project)

        #expect(
            FileManager.default.fileExists(atPath: store.masksURL(for: shot.id).path) == false)
        #expect(try store.maskIDs(for: shot.id).isEmpty)
    }

    @Test("A mask id that is not a safe path component never becomes a URL")
    func aCorruptIDCannotEscapeTheBundle() {
        // The defence is in `Identifier`, not in `ProjectStore`: a traversal
        // string fails to construct a `MaskID` at all, so `maskURL(for:maskID:)`
        // is unreachable with one. Same guarantee ShotID/PresetID already give.
        #expect(MaskID("../../../etc/passwd") == nil)
        #expect(MaskID("a/b") == nil)
        #expect(MaskID("") == nil)
        #expect(MaskID("mask-a") != nil)
    }
}
