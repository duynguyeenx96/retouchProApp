import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// 2026-09-23 — exported files carry the canvas's whole-frame masks, and the
/// brush travels as **strokes** (docs/ADR-0019 addendum, docs/ADR-0025).
///
/// The pixel-level proof (strokes recorded on a preview gating a full-size
/// export, rasterised at render size) is `RPEngineTests/ExportMasksTests`. This
/// file pins the plumbing only the UI can get wrong:
///
/// 1. **Persistence** — a finished stroke lands in `edits/<shot>.strokes.json`
///    through `EditorModel`, "Xoá mask" removes the file, and no PNG is written.
/// 2. **Canvas** — reopening replays the document's strokes; the canvas's
///    export masks carry no brush raster (the brush goes as strokes).
/// 3. **Non-open shots** — ``PreviewMaskSource`` reads the strokes from disk
///    and builds subject masks behind the same flags and switches.
/// 4. **Controller** — every job carries its shot's masks; the open shot's
///    brush is the document in memory.
@Suite("Export carries the canvas's masks (wiring)", .serialized)
@MainActor
struct ExportMaskWiringTests {

    // MARK: - Fakes

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

    static let stroke = ManualMaskStroke(
        radius: 0.05, hardness: 0.5, flow: 1, mode: .add,
        points: [.init(x: 0.2, y: 0.3), .init(x: 0.7, y: 0.4)])

    /// A finished stroke in the canvas's own units (mask pixels).
    static func pixelStroke() -> BrushStroke {
        BrushStroke(
            radius: 12, hardness: 0.5, flow: 1, mode: .add,
            points: [
                BrushPoint(location: CGPoint(x: 8, y: 10)),
                BrushPoint(location: CGPoint(x: 30, y: 12)),
            ])
    }

    // MARK: - 1. Storage path (no GPU)

    @Test("A recorded stroke is saved as edits/<shot>.strokes.json; Xoá mask removes it; no PNG")
    func modelPersistsStrokes() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let shot = try #require(model.activeShot)
        let url = temp.store.manualMaskStrokesURL(for: shot.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        model.recordBrushStroke(Self.pixelStroke(), maskSize: CGSize(width: 40, height: 40))
        await model.flushPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let onDisk = try temp.store.loadManualMaskStrokes(for: shot.id)
        #expect(onDisk.count == 1)
        #expect(onDisk[0] == Self.pixelStroke().normalized(imageSize: CGSize(width: 40, height: 40)))
        #expect(abs(onDisk[0].radius - 12.0 / 40) < 1e-12)
        // No raster anywhere in the bundle.
        #expect(!FileManager.default.fileExists(
            atPath: temp.store.bundleURL.appendingPathComponent("masks").path))

        model.clearBrushStrokes()
        await model.flushPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.activeStrokes.isEmpty)
    }

    // MARK: - 2. The canvas replays the document (GPU)

    @Test("Opening a shot replays its stored strokes; its export masks carry no brush raster")
    func canvasReplaysTheDocument() async throws {
        guard let context = MetalContext.shared else { return }
        try await Self.withFlags(manualMask: true) {
            let (decoded, url) = try ManualMaskBrushWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: url) }
            let controller = LivePreviewController(
                renderer: try LivePreviewRenderer(context: context))

            await controller.open(
                decoded, contentHash: "persist", editState: EditState(),
                manualMaskStrokes: [Self.stroke])
            #expect(controller.hasManualMask)
            #expect(controller.manualMaskStrokeCount == 1)
            #expect(controller.renderRequest.gateMasks.count == 1)
            // Denormalised onto this preview.
            let replayed = try #require(controller.manualMaskStrokes.first)
            #expect(abs(replayed.radius - 0.05 * Double(decoded.pixelSize.width)) < 1e-9)

            let masks = try #require(controller.exportMasks(forContentHash: "persist"))
            #expect(masks.brushStrokes.isEmpty)
            #expect(masks.referenceSize == decoded.pixelSize)
            #expect(controller.exportMasks(forContentHash: "other") == nil)

            // Another shot with no strokes, then this one again with none.
            let (other, otherURL) = try ManualMaskBrushWiringTests.decodedFixture()
            defer { try? FileManager.default.removeItem(at: otherURL) }
            await controller.open(other, contentHash: "elsewhere", editState: EditState())
            #expect(!controller.hasManualMask)
            await controller.open(
                decoded, contentHash: "persist", editState: EditState(),
                manualMaskStrokes: [Self.stroke, Self.stroke])
            #expect(controller.manualMaskStrokeCount == 2)
        }
    }

    // MARK: - 3. Non-open shots

    @Test("A non-open shot's strokes are read from disk")
    func previewMaskSourceReadsTheStrokes() async throws {
        try await Self.withFlags(manualMask: true) {
            let temp = try TempProject(shots: 2)
            defer { temp.cleanUp() }
            try temp.store.saveManualMaskStrokes([Self.stroke], for: temp.project.shots[1].id)
            let source = PreviewMaskSource(store: temp.store)

            let painted = try await source.masks(
                for: temp.project.shots[1],
                originalURL: temp.store.originalURL(for: temp.project.shots[1]),
                editState: EditState())
            #expect(painted.masks.brushStrokes == [Self.stroke])
            #expect(painted.masks.subjectMask == nil)

            let untouched = try await source.masks(
                for: temp.project.shots[0],
                originalURL: temp.store.originalURL(for: temp.project.shots[0]),
                editState: EditState())
            #expect(untouched.masks.isEmpty)
        }
    }

    @Test("With the brush flag off saved strokes are not applied — the canvas has no session either")
    func previewMaskSourceRespectsTheBrushFlag() async throws {
        try await Self.withFlags(manualMask: false) {
            let temp = try TempProject(shots: 1)
            defer { temp.cleanUp() }
            let shot = temp.project.shots[0]
            try temp.store.saveManualMaskStrokes([Self.stroke], for: shot.id)
            let result = try await PreviewMaskSource(store: temp.store).masks(
                for: shot, originalURL: temp.store.originalURL(for: shot), editState: EditState())
            #expect(result.masks.isEmpty)
        }
    }

    @Test("A corrupt strokes file exports without the brush, with a note, rather than failing")
    func previewMaskSourceToleratesACorruptFile() async throws {
        try await Self.withFlags(manualMask: true) {
            let temp = try TempProject(shots: 1)
            defer { temp.cleanUp() }
            let shot = temp.project.shots[0]
            try Data("{ not json".utf8).write(to: temp.store.manualMaskStrokesURL(for: shot.id))
            let result = try await PreviewMaskSource(store: temp.store).masks(
                for: shot, originalURL: temp.store.originalURL(for: shot), editState: EditState())
            #expect(result.masks.brushStrokes.isEmpty)
            #expect(result.notes.count == 1)
        }
    }

    @Test("Subject masks are built only when a flag and the document switch both ask")
    func previewMaskSourceBuildsTheSubjectOnlyWhenUsed() async throws {
        try await Self.withFlags(manualMask: true, backgroundLock: true) {
            let temp = try TempProject(shots: 1)
            defer { temp.cleanUp() }
            let shot = temp.project.shots[0]
            try temp.store.saveManualMaskStrokes([Self.stroke], for: shot.id)
            let provider = FakeSubjectProvider()
            let source = PreviewMaskSource(store: temp.store, subjectProvider: provider)
            let url = temp.store.originalURL(for: shot)

            // Switch off: no segmentation is asked for.
            let off = try await source.masks(for: shot, originalURL: url, editState: EditState())
            #expect(provider.asked.isEmpty)
            #expect(off.masks.subjectMask == nil)
            #expect(off.masks.brushStrokes == [Self.stroke])

            // Switch on: asked once under the shot's content hash; the strokes
            // ride along unchanged (they are normalised).
            var locked = EditState()
            BackgroundLock(isOn: true).write(into: &locked)
            let on = try await source.masks(for: shot, originalURL: url, editState: locked)
            #expect(provider.asked == [shot.contentHash ?? shot.id.rawValue])
            #expect(on.masks.referenceSize == CGSize(width: 40, height: 40))
            #expect(on.masks.subjectMask != nil)
            #expect(on.masks.brushStrokes == [Self.stroke])
        }
    }

    // MARK: - 4. The controller puts them on the jobs

    @Test("Every job carries its own shot's masks")
    func jobsCarryMasks() async throws {
        let harness = try await BatchQueueTests.Harness()
        defer { harness.cleanUp() }
        let names = harness.model.shots.map(\.originalFileName)
        let expected = ExportMasks(referenceSize: .zero, brushStrokes: [Self.stroke])
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

    @Test("Without an override: disk strokes for other shots, the document's for the open one")
    func controllerDefaultSourceReadsDisk() async throws {
        try await Self.withFlags(manualMask: true) {
            let harness = try await BatchQueueTests.Harness()
            defer { harness.cleanUp() }
            let shots = harness.model.shots
            try harness.temp.store.saveManualMaskStrokes([Self.stroke], for: shots[2].id)
            // The open shot (the first) has a stroke only in memory so far —
            // the export must still see it (flushed or not).
            harness.model.recordBrushStroke(
                Self.pixelStroke(), maskSize: CGSize(width: 40, height: 40))
            var options = harness.options
            options.scope = .allShots
            await harness.controller.export(scope: .allShots, of: harness.model, options: options)

            let jobs = harness.runner.jobs
            #expect(jobs.count == 3)
            #expect(jobs[0].masks.brushStrokes == harness.model.activeStrokes)
            #expect(jobs[0].masks.brushStrokes.count == 1)
            #expect(jobs[1].masks.isEmpty)
            #expect(jobs[2].masks.brushStrokes == [Self.stroke])
        }
    }
}
