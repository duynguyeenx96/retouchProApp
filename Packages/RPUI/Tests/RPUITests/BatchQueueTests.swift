import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// docs/PLAN.md Phase 3 — `BatchQueue` and the controller path that feeds it.
///
/// Everything runs against fakes: a runner that records jobs and writes a
/// three-byte file, a thermal source that plays back a scripted sequence, and a
/// face source that reports what it was asked for. No Metal, no 24 MP decode —
/// what is pinned is the policy (order, isolation, cancel, heat, counts) and
/// the shot → job mapping, not the renderer's pixels (that is
/// `RPEngineTests/ExportRendererTests`).
@MainActor
@Suite("Phase 3 batch export")
struct BatchQueueTests {

    // MARK: - Fakes

    struct FakeFailure: Error, CustomStringConvertible {
        var description: String { "fake failure" }
    }

    /// Records jobs in the order they ran; fails any file named in `failing`.
    final class RecordingRunner: ExportRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ExportJob] = []
        private var failingStorage: Set<String> = []
        private var inFlight = 0
        private var maxInFlightStorage = 0

        var failing: Set<String> {
            get { lock.withLock { failingStorage } }
            set { lock.withLock { failingStorage = newValue } }
        }
        var jobs: [ExportJob] { lock.withLock { storage } }
        var maxInFlight: Int { lock.withLock { maxInFlightStorage } }

        func run(_ job: ExportJob) throws -> ExportResult {
            let shouldFail = lock.withLock { () -> Bool in
                storage.append(job)
                inFlight += 1
                maxInFlightStorage = max(maxInFlightStorage, inFlight)
                return failingStorage.contains(job.originalFileName)
            }
            defer { lock.withLock { inFlight -= 1 } }
            // Long enough that an overlapping second render would be seen.
            Thread.sleep(forTimeInterval: 0.005)
            if shouldFail { throw FakeFailure() }
            try FileManager.default.createDirectory(
                at: job.destinationDirectory, withIntermediateDirectories: true)
            let name = ExportNaming.fileName(
                template: job.settings.namingTemplate,
                originalFileName: job.originalFileName, index: job.index,
                format: job.settings.format)
            let url = ExportNaming.uniqueURL(in: job.destinationDirectory, fileName: name)
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            var timings = ExportTimings()
            timings.total = 10
            return ExportResult(
                url: url, pixelSize: CGSize(width: 40, height: 40),
                renderedSize: CGSize(width: 40, height: 40), byteCount: 3,
                format: job.settings.format, writtenBitsPerComponent: 8, profileName: "sRGB",
                stages: [.decode, .upload, .graph, .encode, .write], nodes: [],
                timings: timings, notes: [])
        }
    }

    /// Plays back `levels` one read at a time, then stays on the last one.
    final class ScriptedThermal: ThermalStateProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [ThermalLevel]
        private var readsStorage = 0

        init(_ levels: [ThermalLevel]) { self.levels = levels }

        var reads: Int { lock.withLock { readsStorage } }

        var thermalLevel: ThermalLevel {
            lock.withLock {
                readsStorage += 1
                return levels.count > 1 ? levels.removeFirst() : levels[0]
            }
        }
    }

    /// Answers with one fake face on a fixed preview size and records which
    /// shots it was asked about.
    final class RecordingFaceSource: ExportFaceSource, @unchecked Sendable {
        private let lock = NSLock()
        private var askedStorage: [String] = []
        var asked: [String] { lock.withLock { askedStorage } }

        func faces(for shot: Shot, originalURL: URL) async throws -> ExportFaces {
            lock.withLock { askedStorage.append(shot.originalFileName) }
            return ExportFaces(faces: [], referenceSize: CGSize(width: 2048, height: 1365))
        }
    }

    static func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-batch-\(UUID().uuidString)", isDirectory: true)
    }

    static func items(_ names: [String], folder: URL) -> [BatchExportItem] {
        names.map { name in
            BatchExportItem(shotID: ShotID(name)!, fileName: name) { index in
                ExportJob(
                    sourceURL: URL(fileURLWithPath: "/nonexistent/\(name)"),
                    originalFileName: name, index: index, destinationDirectory: folder)
            }
        }
    }

    // MARK: - The queue

    @Test("Photos run in the given order, one at a time, numbered 1…N")
    func orderAndIndex() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner()
        let queue = BatchQueue(runner: runner, thermal: ScriptedThermal([.nominal]))

        let summary = await queue.run(
            Self.items(["c.png", "a.png", "b.png"], folder: folder), folder: folder)

        #expect(runner.jobs.map(\.originalFileName) == ["c.png", "a.png", "b.png"])
        #expect(runner.jobs.map(\.index) == [1, 2, 3])
        // The GPU memory bound: never two renders in flight.
        #expect(runner.maxInFlight == 1)
        #expect(summary.succeededCount == 3)
        #expect(summary.failures.isEmpty)
        #expect(!summary.wasCancelled)
        #expect(summary.exported.map(\.fileName) == ["c_retouch.jpg", "a_retouch.jpg", "b_retouch.jpg"])
        #expect(summary.headline == "Đã xuất 3/3 ảnh")
        #expect(!queue.isRunning)
    }

    @Test("A photo that fails is recorded by name and the rest still export")
    func failureIsolation() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner()
        runner.failing = ["b.png"]
        var items = Self.items(["a.png", "b.png", "c.png", "d.png"], folder: folder)
        // A failure while *preparing* the job (edit state unreadable, preview
        // will not decode) is isolated the same way as a render failure.
        items[3] = BatchExportItem(shotID: ShotID("d")!, fileName: "d.png") { _ in
            throw FakeFailure()
        }
        let queue = BatchQueue(runner: runner, thermal: ScriptedThermal([.nominal]))

        let summary = await queue.run(items, folder: folder)

        #expect(summary.succeededCount == 2)
        #expect(summary.exported.map(\.fileName) == ["a_retouch.jpg", "c_retouch.jpg"])
        #expect(
            summary.failures == [
                BatchExportFailure(fileName: "b.png", reason: "fake failure"),
                BatchExportFailure(fileName: "d.png", reason: "fake failure"),
            ])
        #expect(summary.headline == "Đã xuất 2/4 ảnh · 2 lỗi")
        #expect(summary.folder == folder)
    }

    @Test("Progress counts go 0…N and name the photo being worked on")
    func progressCounts() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = BatchQueue(runner: RecordingRunner(), thermal: ScriptedThermal([.nominal]))
        var updates: [ExportProgress] = []

        _ = await queue.run(Self.items(["a.png", "b.png"], folder: folder), folder: folder) {
            updates.append($0)
        }

        #expect(
            updates == [
                ExportProgress(currentFileName: "a.png", completed: 0, total: 2),
                ExportProgress(currentFileName: "a.png", completed: 1, total: 2),
                ExportProgress(currentFileName: "b.png", completed: 1, total: 2),
                ExportProgress(currentFileName: "b.png", completed: 2, total: 2),
            ])
        #expect(updates.allSatisfy { !$0.isThermalPaused })
    }

    @Test("Cancel stops after the photo in flight; the rest are not started")
    func cancellation() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner()
        let queue = BatchQueue(runner: runner, thermal: ScriptedThermal([.nominal]))

        let summary = await queue.run(
            Self.items(["a.png", "b.png", "c.png", "d.png"], folder: folder), folder: folder
        ) { update in
            // Pressed while b.png is starting.
            if update.currentFileName == "b.png", update.completed == 1 { queue.cancel() }
        }

        #expect(runner.jobs.map(\.originalFileName) == ["a.png", "b.png"])
        #expect(summary.succeededCount == 2)
        #expect(summary.notStarted == 2)
        #expect(summary.wasCancelled)
        #expect(summary.headline == "Đã dừng — xuất 2/4 ảnh")
        // The flag does not leak into the next batch.
        let next = await queue.run(Self.items(["e.png"], folder: folder), folder: folder)
        #expect(next.succeededCount == 1)
    }

    @Test("Cancel with nothing running is a no-op")
    func cancelIdle() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = BatchQueue(runner: RecordingRunner(), thermal: ScriptedThermal([.nominal]))
        queue.cancel()
        let summary = await queue.run(Self.items(["a.png"], folder: folder), folder: folder)
        #expect(summary.succeededCount == 1)
    }

    @Test("At serious/critical heat the queue pauses between photos, then resumes")
    func thermalPauseAndResume() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner()
        // a.png: nominal. Before b.png: serious, critical, fair → resume.
        let thermal = ScriptedThermal([.nominal, .serious, .critical, .fair])
        let queue = BatchQueue(
            runner: runner, thermal: thermal, thermalPollInterval: .milliseconds(1))
        var updates: [ExportProgress] = []

        let summary = await queue.run(
            Self.items(["a.png", "b.png"], folder: folder), folder: folder
        ) { updates.append($0) }

        #expect(summary.succeededCount == 2)
        let paused = updates.filter(\.isThermalPaused)
        // One "paused" update per poll while hot: serious, then critical.
        #expect(paused.count == 2)
        #expect(paused.allSatisfy { $0.currentFileName == "b.png" && $0.completed == 1 })
        #expect(paused.first?.statusText == "Máy đang nóng, tạm dừng…")
        // Never paused *inside* a photo: every paused update precedes b.png's start.
        let startB = try #require(
            updates.firstIndex {
                $0.currentFileName == "b.png" && $0.completed == 1 && !$0.isThermalPaused
            })
        #expect(updates.lastIndex(where: \.isThermalPaused)! < startB)
        #expect(thermal.reads >= 4)
    }

    @Test("Fair is not hot: no pause at .fair")
    func fairDoesNotPause() {
        #expect(!ThermalLevel.nominal.requiresPause)
        #expect(!ThermalLevel.fair.requiresPause)
        #expect(ThermalLevel.serious.requiresPause)
        #expect(ThermalLevel.critical.requiresPause)
        #expect(ThermalLevel(.critical) == .critical)
    }

    @Test("Cancel during a heat pause ends the batch without rendering")
    func cancelWhilePaused() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = RecordingRunner()
        let queue = BatchQueue(
            runner: runner, thermal: ScriptedThermal([.critical]),
            thermalPollInterval: .milliseconds(1))

        let summary = await queue.run(
            Self.items(["a.png", "b.png"], folder: folder), folder: folder
        ) { update in
            if update.isThermalPaused { queue.cancel() }
        }

        #expect(runner.jobs.isEmpty)
        #expect(summary.notStarted == 2)
        #expect(summary.succeededCount == 0)
    }

    // MARK: - The controller: scope → shots → jobs

    @MainActor
    struct Harness {
        let temp: TempProject
        let model: EditorModel
        let runner: RecordingRunner
        let faces: RecordingFaceSource
        let controller: ExportController
        let destination: URL

        init(shots: Int = 3) async throws {
            temp = try TempProject(shots: shots)
            model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
            runner = RecordingRunner()
            faces = RecordingFaceSource()
            controller = ExportController(
                runner: runner, thermal: ScriptedThermal([.nominal]), faceSource: faces)
            destination = temp.root.appendingPathComponent("out", isDirectory: true)
        }

        var options: ExportOptions {
            var options = ExportOptions()
            options.destinationFolder = destination
            return options
        }

        func cleanUp() { temp.cleanUp() }
    }

    @Test("Scope: the selection in project order, or every shot")
    func scopeResolution() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let shots = harness.model.shots
        #expect(ExportScope.selection.shots(in: harness.model).map(\.id) == [shots[0].id])

        // ⌘-click the third: selected in click order 0, 2 — exported in project order.
        harness.model.selection.toggle(shots[2].id, in: shots)
        #expect(
            ExportScope.selection.shots(in: harness.model).map(\.id) == [shots[0].id, shots[2].id])
        #expect(ExportScope.allShots.shots(in: harness.model).map(\.id) == shots.map(\.id))
        #expect(ExportOptions().scope == .selection)
    }

    @Test("A batch reads each shot's own edits — in-memory for the open one, disk for the rest")
    func editStatesPerShot() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let shots = harness.model.shots
        // Shot 1 edited earlier (on disk only); shot 0 open with an uncommitted drag.
        var onDisk = EditState()
        onDisk.setSlider("smooth", in: EditState.SectionKey.skin, to: 17)
        try harness.temp.store.saveEditState(onDisk, for: shots[1].id)
        harness.model.setSlider("smooth", in: EditState.SectionKey.skin, to: 55)

        var options = harness.options
        options.scope = .allShots
        await harness.controller.export(scope: options.scope, of: harness.model, options: options)

        let jobs = harness.runner.jobs
        #expect(jobs.map(\.originalFileName) == shots.map(\.originalFileName))
        #expect(jobs.map(\.index) == [1, 2, 3])
        #expect(jobs[0].editState.slider("smooth", in: EditState.SectionKey.skin) == 55)
        #expect(jobs[1].editState.slider("smooth", in: EditState.SectionKey.skin) == 17)
        #expect(jobs[2].editState.slider("smooth", in: EditState.SectionKey.skin) == 0)
        #expect(jobs.allSatisfy { $0.sourceURL.path.contains("/originals/") })
        #expect(jobs.allSatisfy { $0.destinationDirectory == harness.destination })
        // The open shot's drag was committed, as the single export always did.
        let committed = try harness.temp.store.loadEditState(for: shots[0].id)
        #expect(committed.slider("smooth", in: EditState.SectionKey.skin) == 55)

        let batch = try #require(harness.controller.lastBatch)
        #expect(batch.succeededCount == 3)
        #expect(harness.controller.lastSummary?.fileName == "DSC00002_retouch.jpg")
        #expect(harness.controller.progress == nil)
        #expect(!harness.controller.isExporting)
    }

    @Test("Shots not open on the canvas get faces from the face source, with its preview size")
    func facesForNonOpenShots() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        var options = harness.options
        options.scope = .allShots
        await harness.controller.export(scope: .allShots, of: harness.model, options: options)

        // No live canvas in this test, so the open shot is measured the same
        // way as the others — every shot asked once, in order.
        #expect(harness.faces.asked == harness.model.shots.map(\.originalFileName))
        #expect(
            harness.runner.jobs.allSatisfy {
                $0.faceReferenceSize == CGSize(width: 2048, height: 1365)
            })
    }

    @Test("A failed photo in a batch is listed; the others land; no single-error banner")
    func controllerFailureIsolation() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.runner.failing = ["DSC00001.png"]
        await harness.controller.export(scope: .allShots, of: harness.model, options: harness.options)

        let batch = try #require(harness.controller.lastBatch)
        #expect(batch.succeededCount == 2)
        #expect(batch.failures.map(\.fileName) == ["DSC00001.png"])
        #expect(harness.controller.lastErrorMessage == nil)
        let written = try FileManager.default.contentsOfDirectory(atPath: harness.destination.path)
        #expect(Set(written) == ["DSC00000_retouch.jpg", "DSC00002_retouch.jpg"])
    }

    @Test("The single-photo button is a batch of one and keeps its old contract")
    func singleIsBatchOfOne() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.runner.jobs.count == 1)
        #expect(harness.controller.lastBatch?.total == 1)
        #expect(harness.controller.lastSummary?.fileName == "DSC00000_retouch.jpg")

        harness.runner.failing = ["DSC00000.png"]
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.controller.lastErrorMessage == "fake failure")
        #expect(harness.controller.lastSummary == nil)
    }

    @Test("Stop on the controller outside a run does nothing")
    func controllerCancelIdle() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.controller.cancel()
        #expect(!harness.controller.isCancelling)
        await harness.controller.export(scope: .allShots, of: harness.model, options: harness.options)
        #expect(harness.controller.lastBatch?.succeededCount == 3)
    }
}
