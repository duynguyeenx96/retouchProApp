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
/// The pixels are RPEngine's problem (`ManualMaskTests` measures the brush).
/// This suite is only about the two halves of the *storage* decision:
///
/// 1. the bytes go to `masks/<shot id>/<mask id>.png` inside the `.rpproj`
///    bundle, and are cleaned up with the shot;
/// 2. `EditState` holds **only an id**, in `perImage`, so it never travels in a
///    preset and never bloats the JSON that is rewritten on every slider release.
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

    // MARK: - The reference in the document

    @Test("The reference round-trips through EditState.perImage")
    func referenceRoundTrips() {
        var state = EditState()
        #expect(ManualMaskReference(state).maskID == nil)
        #expect(ManualMaskReference(state).hasMask == false)

        ManualMaskReference(maskID: MaskID("mask-a")!).write(into: &state)
        #expect(state.perImage[ManualMaskReference.key] == .string("mask-a"))
        #expect(ManualMaskReference(state).maskID == MaskID("mask-a"))

        // Clearing removes the key rather than writing a null, so an untouched
        // document stays untouched.
        ManualMaskReference().write(into: &state)
        #expect(state.perImage[ManualMaskReference.key] == nil)
        #expect(state.isDefault)
    }

    @Test("A malformed id in a document reads as 'no mask', not as an error")
    func aMalformedReferenceReadsAsAbsent() {
        var state = EditState()
        state.perImage[ManualMaskReference.key] = .string("../escape")
        #expect(ManualMaskReference(state).maskID == nil)

        state.perImage[ManualMaskReference.key] = .int(7)
        #expect(ManualMaskReference(state).maskID == nil)
    }

    @Test("A mask reference never travels inside a preset")
    func presetsDropTheReference() {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 90)
        ManualMaskReference(maskID: MaskID("mask-a")!).write(into: &state)

        let preset = Preset(name: "Soft", from: state)
        var other = EditState()
        other = other.applying(preset)

        // The slider transfers, the mask does not: it was painted around one
        // person's jaw on one frame and means nothing on the next.
        #expect(other.slider("smooth", in: EditState.SectionKey.skin) == 90)
        #expect(ManualMaskReference(other).maskID == nil)
    }
}
