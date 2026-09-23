import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// Phase 3, first slice — the wiring between the export sheet and
/// `RPEngine.ExportRenderer`.
///
/// The renderer's own claims (a file exists, it has the size / depth / profile
/// asked for, passthrough PSNR) are `RPEngineTests/ExportRendererTests` and are
/// not repeated here. What these tests pin is the part that only exists in RPUI
/// and that a GPU test cannot see:
///
/// * the four pills become the right `ExportSettings` — the one place a "TIFF"
///   tap can quietly turn into a JPEG;
/// * the job carries the **active shot's** file, its `EditState` and its faces,
///   with the reference size that makes the rescale correct;
/// * the states around the call — no shot, no renderer, a failure, and a second
///   press while the first is still running.
///
/// All of it runs with a fake ``ExportRunning``, so there is no Metal device, no
/// 24 MP decode and no GPU contention in the unit-test run.
@MainActor
@Suite("Phase 3 export wiring")
struct ExportWiringTests {

    /// Records the job and writes a small file where the real renderer would.
    final class RecordingRunner: ExportRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ExportJob] = []
        /// When set, `run` throws it instead of writing.
        var failure: (any Error)?

        var jobs: [ExportJob] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func run(_ job: ExportJob) throws -> ExportResult {
            lock.lock()
            storage.append(job)
            lock.unlock()
            if let failure { throw failure }
            try FileManager.default.createDirectory(
                at: job.destinationDirectory, withIntermediateDirectories: true)
            let name = ExportNaming.fileName(
                template: job.settings.namingTemplate,
                originalFileName: job.originalFileName, index: job.index,
                format: job.settings.format)
            let url = ExportNaming.uniqueURL(in: job.destinationDirectory, fileName: name)
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            var timings = ExportTimings()
            timings.total = 12.5
            return ExportResult(
                url: url, pixelSize: CGSize(width: 40, height: 40),
                renderedSize: CGSize(width: 40, height: 40), byteCount: 3,
                format: job.settings.format, writtenBitsPerComponent: 8, profileName: "sRGB",
                stages: [.decode, .upload, .graph, .encode, .write], nodes: [],
                timings: timings, notes: [])
        }
    }

    /// `@MainActor` explicitly: a nested type does **not** inherit the suite's
    /// isolation, and `ExportController` is main-actor bound like every
    /// `@Observable` the views read.
    @MainActor
    struct Harness {
        let temp: TempProject
        let model: EditorModel
        let runner: RecordingRunner
        let controller: ExportController
        let destination: URL

        init() async throws {
            temp = try TempProject()
            model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
            runner = RecordingRunner()
            controller = ExportController(runner: runner)
            destination = temp.root.appendingPathComponent("out", isDirectory: true)
        }

        var options: ExportOptions {
            var options = ExportOptions()
            options.destinationFolder = destination
            return options
        }

        func cleanUp() { temp.cleanUp() }
    }

    // MARK: - The pills → the settings

    @Test("Every pill row lands on the matching ExportSettings field")
    func settingsMapping() {
        var options = ExportOptions()
        options.format = .tiff
        options.quality = .maximum
        options.size = .long4000
        options.colorSpace = .displayP3
        let tiff = options.engineSettings
        #expect(tiff.format == .tiff)
        #expect(tiff.quality == 100)
        #expect(tiff.resize == .longestEdge(4000))
        #expect(tiff.colorProfile == .displayP3)
        // TIFF is the one format anybody picks *for* the depth.
        #expect(tiff.bitDepth == .sixteen)
        #expect(tiff.effectiveBitDepth == .sixteen)

        options.format = .jpeg
        options.quality = .low
        options.size = .long2048
        options.colorSpace = .sRGB
        let jpeg = options.engineSettings
        #expect(jpeg.format == .jpeg)
        #expect(jpeg.quality == 80)
        #expect(jpeg.resize == .longestEdge(2048))
        #expect(jpeg.colorProfile == .sRGB)
        #expect(jpeg.bitDepth == .eight)

        options.format = .heif
        options.size = .original
        #expect(options.engineSettings.format == .heif)
        #expect(options.engineSettings.resize == .original)
    }

    @Test("Output sharpening stays off — no pill raises it")
    func sharpenStaysOff() {
        for format in ExportOptions.Format.allCases {
            for size in ExportOptions.Size.allCases {
                var options = ExportOptions()
                options.format = format
                options.size = size
                #expect(options.engineSettings.sharpen == 0)
                #expect(!options.engineSettings.sharpensOutput)
            }
        }
    }

    // MARK: - The default destination

    @Test("The default destination is a folder this build can actually write to")
    func defaultDestinationIsWritable() throws {
        let directory = ExportDestination.defaultDirectory()
        #expect(directory.lastPathComponent == ExportDestination.folderName)
        // The claim that matters: creating and writing there succeeds. A
        // sandboxed build without the pictures entitlement fails this for
        // `~/Pictures`, which is what the old placeholder pointed at.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent("rpui-probe-\(UUID().uuidString)")
        try Data([0]).write(to: probe)
        #expect(FileManager.default.fileExists(atPath: probe.path))
        try FileManager.default.removeItem(at: probe)
    }

    @Test("A picked folder wins over the default, and the row shows the real one")
    func pickedFolderWins() {
        var options = ExportOptions()
        #expect(ExportDestination.resolve(options) == ExportDestination.defaultDirectory())
        let picked = URL(fileURLWithPath: "/tmp/rp-export-target", isDirectory: true)
        options.destinationFolder = picked
        #expect(ExportDestination.resolve(options) == picked)
        #expect(options.destinationDisplayPath == picked.path)
    }

    // MARK: - One export

    @Test("Exporting writes a file and reports it")
    func exportWritesAFile() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }

        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)

        let summary = try #require(harness.controller.lastSummary)
        #expect(FileManager.default.fileExists(atPath: summary.url.path))
        #expect(summary.url.deletingLastPathComponent() == harness.destination)
        #expect(summary.fileName == "DSC00000_retouch.jpg")
        #expect(harness.controller.lastErrorMessage == nil)
        #expect(!harness.controller.isExporting)
        #expect(harness.controller.progress == nil)
    }

    @Test("The job is the active shot, its edits and its faces")
    func jobCarriesTheActiveShot() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }

        await harness.model.selectNextShot()
        harness.model.setSlider("smooth", in: EditState.SectionKey.skin, to: 42)
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)

        let job = try #require(harness.runner.jobs.first)
        #expect(job.sourceURL == harness.model.activeOriginalURL)
        #expect(job.originalFileName == "DSC00001.png")
        #expect(job.editState.slider("smooth", in: EditState.SectionKey.skin) == 42)
        #expect(job.index == 1)
        #expect(job.destinationDirectory == harness.destination)
        // No GPU canvas in this test, so no faces — and the reference size is
        // then zero, which `ExportJob` reads as "do not rescale".
        #expect(job.faces.isEmpty)
        #expect(job.faceReferenceSize == .zero)
    }

    @Test("The sliders that were on screen are on disk after an export")
    func exportCommitsTheDocument() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let id = try #require(harness.model.activeShot?.id)

        harness.model.setSlider("smooth", in: EditState.SectionKey.skin, to: 30)
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)

        let onDisk = try harness.temp.store.loadEditState(for: id)
        #expect(onDisk.slider("smooth", in: EditState.SectionKey.skin) == 30)
    }

    @Test("Two exports of the same shot are two files, not one overwritten")
    func repeatedExportsDoNotOverwrite() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }

        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        let first = try #require(harness.controller.lastSummary?.url)
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        let second = try #require(harness.controller.lastSummary?.url)

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - The states around it

    @Test("A renderer-less controller refuses instead of pretending")
    func noRendererIsAState() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        let controller = ExportController(runner: nil)
        #expect(!controller.isAvailable)

        await controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(controller.lastSummary == nil)
        #expect(controller.lastErrorMessage != nil)
    }

    @Test("With no shot selected nothing is written")
    func noShotIsAState() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        await harness.model.select(shotID: nil)
        #expect(harness.model.activeShot == nil)

        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.runner.jobs.isEmpty)
        #expect(harness.controller.lastSummary == nil)
        #expect(harness.controller.lastErrorMessage != nil)
    }

    @Test("A renderer failure becomes a message, not a crash or a half file")
    func failureIsReported() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.runner.failure = ExportError.encodeFailed(format: .jpeg)

        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.controller.lastSummary == nil)
        #expect(harness.controller.lastErrorMessage != nil)
        #expect(!harness.controller.isExporting)
        // The folder was never created, so there is nothing half-written in it.
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))
    }

    @Test("A successful export clears the previous failure message")
    func successClearsTheError() async throws {
        let harness = try await Harness()
        defer { harness.cleanUp() }
        harness.runner.failure = ExportError.cannotCreateContext
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.controller.lastErrorMessage != nil)

        harness.runner.failure = nil
        await harness.controller.exportActiveShot(of: harness.model, options: harness.options)
        #expect(harness.controller.lastErrorMessage == nil)
        #expect(harness.controller.lastSummary != nil)
    }

    // MARK: - The device self-test hook

    @Test("RP_EXPORT_SELFTEST is off unless it is set, and reads its two forms")
    func selfTestTarget() {
        #expect(ExportSelfTest.target(environment: [:]) == nil)
        #expect(ExportSelfTest.target(environment: [ExportSelfTest.environmentKey: ""]) == nil)
        #expect(
            ExportSelfTest.target(environment: [ExportSelfTest.environmentKey: "1"])
                == .firstShot)
        #expect(
            ExportSelfTest.target(
                environment: [ExportSelfTest.environmentKey: "first-shot"]) == .firstShot)
        #expect(
            ExportSelfTest.target(
                environment: [ExportSelfTest.environmentKey: "DSC05259.jpg"])
                == .fileName("DSC05259.jpg"))
        #expect(
            ExportSelfTest.target(environment: [ExportSelfTest.environmentKey: "batch"])
                == .batch(project: nil))
        #expect(
            ExportSelfTest.target(
                environment: [ExportSelfTest.environmentKey: "batch:Shoot 2026-09-07 2"])
                == .batch(project: "Shoot 2026-09-07 2"))
    }

    @Test("The self-test resolves a real library, and says why when it cannot")
    func selfTestResolution() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }
        // `TempProject` puts the bundle inside its own root, which is the
        // library root as far as `ProjectLibrary` is concerned.
        let root = temp.root

        // Compared by last component, not by whole URL: `ProjectLibrary` hands
        // back a directory URL under the resolved `/private/var` prefix while
        // `TempProject` holds the `/var` one, and both name the same folder.
        let bundleName = temp.store.bundleURL.lastPathComponent
        guard case .resolved(let first) = ExportSelfTest.resolve(.firstShot, libraryRoot: root)
        else {
            Issue.record("the first shot did not resolve")
            return
        }
        #expect(first.bundleURL.lastPathComponent == bundleName)
        #expect(first.originalFileName == nil)

        guard
            case .resolved(let named) = ExportSelfTest.resolve(
                .fileName("DSC00001.png"), libraryRoot: root)
        else {
            Issue.record("a named original did not resolve")
            return
        }
        #expect(named.bundleURL.lastPathComponent == bundleName)
        #expect(named.originalFileName == "DSC00001.png")

        guard
            case .resolved(let batch) = ExportSelfTest.resolve(
                .batch(project: "Test Shoot"), libraryRoot: root)
        else {
            Issue.record("a named batch project did not resolve")
            return
        }
        #expect(batch.bundleURL.lastPathComponent == bundleName)
        if case .resolved = ExportSelfTest.resolve(.batch(project: "nope"), libraryRoot: root) {
            Issue.record("a missing batch project resolved to something")
        }

        // The two ways it can have nothing to do, both explained rather than
        // silently skipped.
        if case .resolved = ExportSelfTest.resolve(.fileName("nope.jpg"), libraryRoot: root) {
            Issue.record("a missing file resolved to something")
        }
        if case .resolved = ExportSelfTest.resolve(.firstShot, libraryRoot: nil) {
            Issue.record("a missing library resolved to something")
        }
    }

    @Test("The finished row says how big, how large and how long")
    func summaryText() {
        let summary = ExportSummary(
            url: URL(fileURLWithPath: "/tmp/DSC05123_retouch.jpg"), byteCount: 4_200_000,
            pixelSize: CGSize(width: 4000, height: 6000), milliseconds: 3140, notes: [])
        #expect(summary.fileName == "DSC05123_retouch.jpg")
        #expect(summary.detailText.contains("4000×6000"))
        #expect(summary.detailText.contains("3.1 s"))
    }
}
