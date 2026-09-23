import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// 2026-09-23 — exported files carry the canvas's whole-frame masks.
///
/// The pixel-level proof (a brush at preview size gating a full-size export)
/// is `RPEngineTests/ExportMasksTests`. This file pins the plumbing only the UI
/// can get wrong:
///
/// 1. **Persistence** — the brush is saved to `masks/<shot>/brush.png` after
///    each stroke/undo/redo, deleted when the session empties, and reloaded
///    when the shot is reopened.
/// 2. **Open shot** — the export takes the canvas's own masks, at the canvas's
///    reference size.
/// 3. **Non-open shots** — ``PreviewMaskSource`` rebuilds them from disk and
///    from the canvas's subject provider, behind the same flags and switches.
/// 4. **Controller** — every job carries its shot's masks.
@Suite("Export carries the canvas's masks (wiring)", .serialized)
@MainActor
struct ExportMaskWiringTests {

    // MARK: - Fakes

    final class MemoryMaskStore: ManualMaskStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Data?
        private var savesStorage = 0
        private var deletesStorage = 0

        init(_ initial: Data? = nil) { storage = initial }

        var data: Data? { lock.withLock { storage } }
        var saves: Int { lock.withLock { savesStorage } }
        var deletes: Int { lock.withLock { deletesStorage } }

        func loadManualMask() throws -> Data? { lock.withLock { storage } }
        func saveManualMask(_ png: Data) throws {
            lock.withLock {
                storage = png
                savesStorage += 1
            }
        }
        func deleteManualMask() throws {
            lock.withLock {
                storage = nil
                deletesStorage += 1
            }
        }
    }

    /// Returns a fixed 16×12 subject mask on whatever preview it is handed, and
    /// records the content hashes it was asked about.
    final class FakeSubjectProvider: SubjectMaskProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var askedStorage: [String] = []
        var asked: [String] { lock.withLock { askedStorage } }

        func subjectMask(
            for image: PreviewImage, contentHash: String, quality: SubjectMaskQuality
        ) async throws -> RenderMask? {
            lock.withLock { askedStorage.append(contentHash) }
            return RenderMask(
                width: 16, height: 12, values: [UInt8](repeating: 200, count: 16 * 12),
                maskToImage: CGAffineTransform(
                    scaleX: image.pixelSize.width / 16, y: image.pixelSize.height / 12))
        }
    }

    /// Hands back a canned result per file name.
    final class FakeMaskSource: ExportMaskSource, @unchecked Sendable {
        let byName: [String: ExportMasks]
        init(_ byName: [String: ExportMasks]) { self.byName = byName }
        func masks(
            for shot: Shot, originalURL: URL, editState: EditState
        ) async throws -> ExportMaskResult {
            ExportMaskResult(masks: byName[shot.originalFileName] ?? .none)
        }
    }

    static func withFlags(
        manualMask: Bool = false, backgroundLock: Bool = false, bodySkinSync: Bool = false,
        _ body: () async throws -> Void
    ) async throws {
        try await RPUIMaskFlagLock.exclusive {
            let saved = (
                RPEngineFeatureFlags.manualMask, RPEngineFeatureFlags.backgroundLock,
                RPEngineFeatureFlags.bodySkinSync
            )
            RPEngineFeatureFlags.manualMask = manualMask
            RPEngineFeatureFlags.backgroundLock = backgroundLock
            RPEngineFeatureFlags.bodySkinSync = bodySkinSync
            defer {
                RPEngineFeatureFlags.manualMask = saved.0
                RPEngineFeatureFlags.backgroundLock = saved.1
                RPEngineFeatureFlags.bodySkinSync = saved.2
            }
            try await body()
        }
    }

    static func brushPNG(width: Int = 20, height: Int = 20) throws -> (Data, [UInt8]) {
        var values = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height / 3) { values[i] = 255 }
        return (try ManualMaskSession.pngData(values: values, width: width, height: height), values)
    }

    // MARK: - 1. Storage path

    @Test("ProjectManualMaskStore writes masks/<shot id>/brush.png and deletes it")
    func projectStoreRoundTrip() throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let shot = temp.project.shots[0]
        let store = ProjectManualMaskStore(store: temp.store, shotID: shot.id)
        #expect(try store.loadManualMask() == nil)

        let (png, _) = try Self.brushPNG()
        try store.saveManualMask(png)
        let url = temp.store.bundleURL.appendingPathComponent(
            "masks/\(shot.id.rawValue)/brush.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try store.loadManualMask() == png)

        try store.deleteManualMask()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: Never.self) { try store.deleteManualMask() }
    }

    // MARK: - 1 & 2. The canvas saves, reloads and hands over its brush (GPU)

    @Test("Strokes are saved, an emptied session deletes the file, reopening reloads it")
    func canvasPersistsAndReloadsTheBrush() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(manualMask: true) {
            let (decoded, url) = try ManualMaskBrushWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = MemoryMaskStore()
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))
            await controller.open(
                decoded, contentHash: "persist", editState: EditState(), manualMaskStore: store)

            // Nothing painted, nothing on disk, nothing for the export.
            #expect(controller.exportMasks(forContentHash: "persist")?.manualMask == nil)

            controller.beginManualMaskStroke(
                at: CGPoint(x: 60, y: 60), settings: ManualMaskBrushSettings())
            controller.extendManualMaskStroke(to: CGPoint(x: 160, y: 100))
            controller.endManualMaskStroke()
            await controller.flushManualMaskWrites()
            let saved = try #require(store.data)
            #expect(store.saves == 1)

            // The export gets the canvas's own coverage, at the preview's size.
            let masks = try #require(controller.exportMasks(forContentHash: "persist"))
            #expect(masks.referenceSize == decoded.pixelSize)
            let manual = try #require(masks.manualMask)
            #expect(manual.width == Int(decoded.pixelSize.width))
            #expect(manual.maskToImage == .identity)
            #expect(manual.values.contains(255))
            // …and it is byte-identical to what went to disk.
            #expect(try ExportMasks.manualMask(fromPNG: saved).values == manual.values)
            // Another shot's hash gets nothing from this canvas.
            #expect(controller.exportMasks(forContentHash: "other") == nil)

            // Undo back to nothing: the file goes, so a batch sees "no mask".
            controller.undoManualMaskStroke()
            await controller.flushManualMaskWrites()
            #expect(store.data == nil)
            #expect(store.deletes == 1)
            controller.redoManualMaskStroke()
            await controller.flushManualMaskWrites()
            #expect(store.data == saved)

            // Reopen (another shot, then this one): the saved mask is back as
            // the baseline, so the canvas gates with it again.
            let (other, otherURL) = try ManualMaskBrushWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: otherURL) }
            await controller.open(other, contentHash: "elsewhere", editState: EditState())
            #expect(!controller.hasManualMask)
            await controller.open(
                decoded, contentHash: "persist", editState: EditState(), manualMaskStore: store)
            #expect(controller.hasManualMask)
            #expect(controller.renderRequest.gateMasks.count == 1)
            #expect(
                controller.exportMasks(forContentHash: "persist")?.manualMask?.values
                    == manual.values)

            // "Xoá mask" deletes it.
            controller.clearManualMask()
            await controller.flushManualMaskWrites()
            #expect(store.data == nil)
        }
    }

    // MARK: - 3. Non-open shots

    @Test("A non-open shot's saved brush is read from disk, at the PNG's own size")
    func previewMaskSourceReadsTheSavedBrush() async throws {
        try await Self.withFlags(manualMask: true) {
            let temp = try TempProject(shots: 2)
            defer { temp.cleanUp() }
            let (png, values) = try Self.brushPNG(width: 30, height: 20)
            try ProjectManualMaskStore(store: temp.store, shotID: temp.project.shots[1].id)
                .saveManualMask(png)
            let source = PreviewMaskSource(store: temp.store)

            let painted = try await source.masks(
                for: temp.project.shots[1],
                originalURL: temp.store.originalURL(for: temp.project.shots[1]),
                editState: EditState())
            #expect(painted.masks.referenceSize == CGSize(width: 30, height: 20))
            #expect(painted.masks.manualMask?.values == values)
            #expect(painted.masks.subjectMask == nil)

            let untouched = try await source.masks(
                for: temp.project.shots[0],
                originalURL: temp.store.originalURL(for: temp.project.shots[0]),
                editState: EditState())
            #expect(untouched.masks == .none)
        }
    }

    @Test("With the brush flag off a saved PNG is not applied — the canvas has no session either")
    func previewMaskSourceRespectsTheBrushFlag() async throws {
        try await Self.withFlags(manualMask: false) {
            let temp = try TempProject(shots: 1)
            defer { temp.cleanUp() }
            let shot = temp.project.shots[0]
            try ProjectManualMaskStore(store: temp.store, shotID: shot.id)
                .saveManualMask(try Self.brushPNG().0)
            let result = try await PreviewMaskSource(store: temp.store).masks(
                for: shot, originalURL: temp.store.originalURL(for: shot), editState: EditState())
            #expect(result.masks.isEmpty)
        }
    }

    @Test("Subject masks are built only when a flag and the document switch both ask")
    func previewMaskSourceBuildsTheSubjectOnlyWhenUsed() async throws {
        try await Self.withFlags(manualMask: true, backgroundLock: true) {
            let temp = try TempProject(shots: 1)
            defer { temp.cleanUp() }
            let shot = temp.project.shots[0]
            try ProjectManualMaskStore(store: temp.store, shotID: shot.id)
                .saveManualMask(try Self.brushPNG(width: 20, height: 20).0)
            let provider = FakeSubjectProvider()
            let source = PreviewMaskSource(store: temp.store, subjectProvider: provider)
            let url = temp.store.originalURL(for: shot)

            // Switch off: no segmentation is asked for.
            let off = try await source.masks(for: shot, originalURL: url, editState: EditState())
            #expect(provider.asked.isEmpty)
            #expect(off.masks.subjectMask == nil)

            // Switch on: asked once under the shot's content hash, and the brush
            // is mapped onto the same preview grid (the original is 40 px square).
            var locked = EditState()
            BackgroundLock(isOn: true).write(into: &locked)
            let on = try await source.masks(for: shot, originalURL: url, editState: locked)
            #expect(provider.asked == [shot.contentHash ?? shot.id.rawValue])
            #expect(on.masks.referenceSize == CGSize(width: 40, height: 40))
            #expect(on.masks.subjectMask != nil)
            let manual = try #require(on.masks.manualMask)
            let corner = CGPoint(x: 20, y: 20).applying(manual.maskToImage)
            #expect(corner == CGPoint(x: 40, y: 40))
        }
    }

    // MARK: - 4. The controller puts them on the jobs

    @Test("Every job carries its own shot's masks")
    func jobsCarryMasks() async throws {
        let harness = try await BatchQueueTests.Harness()
        defer { harness.cleanUp() }
        let names = harness.model.shots.map(\.originalFileName)
        let brush = RenderMask(
            width: 4, height: 3, values: [UInt8](repeating: 255, count: 12), maskToImage: .identity)
        let expected = ExportMasks(referenceSize: CGSize(width: 4, height: 3), manualMask: brush)
        let controller = ExportController(
            runner: harness.runner, thermal: BatchQueueTests.ScriptedThermal([.nominal]),
            faceSource: harness.faces, maskSource: FakeMaskSource([names[1]: expected]))
        var options = harness.options
        options.scope = .allShots
        await controller.export(scope: .allShots, of: harness.model, options: options)

        let jobs = harness.runner.jobs
        #expect(jobs.map(\.originalFileName) == names)
        #expect(jobs[0].masks == .none)
        #expect(jobs[1].masks == expected)
        #expect(jobs[2].masks == .none)
    }

    @Test("Without an override the controller reads the saved brush for a non-open shot")
    func controllerDefaultSourceReadsDisk() async throws {
        try await Self.withFlags(manualMask: true) {
            let harness = try await BatchQueueTests.Harness()
            defer { harness.cleanUp() }
            let shots = harness.model.shots
            let (png, values) = try Self.brushPNG(width: 30, height: 20)
            try ProjectManualMaskStore(store: harness.temp.store, shotID: shots[2].id)
                .saveManualMask(png)
            var options = harness.options
            options.scope = .allShots
            await harness.controller.export(scope: .allShots, of: harness.model, options: options)

            let jobs = harness.runner.jobs
            #expect(jobs.count == 3)
            #expect(jobs[0].masks.isEmpty)
            #expect(jobs[1].masks.isEmpty)
            #expect(jobs[2].masks.manualMask?.values == values)
            #expect(jobs[2].masks.referenceSize == CGSize(width: 30, height: 20))
        }
    }
}
