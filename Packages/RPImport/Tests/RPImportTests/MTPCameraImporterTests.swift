import Foundation
import Testing

import RPCore
@testable import RPImport

/// These tests swap ImageCaptureCore for ``FakeCameraSource``. Say it plainly:
/// **no test here talks to a camera.** `ICDeviceBrowser`, `requestOpenSession`
/// and `requestDownloadFile` need an a6300 on a cable, and that is what PLAN
/// Phase 0 spike S5 and a manual smoke test are for.
///
/// What is pinned down here is the half that can silently rot: that downloaded
/// bytes reach `originals/` unchanged under the camera's own file name, that a
/// movie is rejected *before* it is pulled over USB, that one bad frame does
/// not abort a card, and that the session is always closed.
@Suite("MTPCameraImporter — wiring, with ImageCaptureCore faked out")
struct MTPCameraImporterTests {
    private func makeImporter(source: FakeCameraSource, staging: URL) -> MTPCameraImporter {
        MTPCameraImporter(
            source: source,
            options: ImportOptions(usesSecurityScopedAccess: false),
            metadataExtractor: NullMetadataExtractor(),
            stagingDirectory: staging
        )
    }

    @Test("Every importable file on the card lands in originals/")
    func importsWholeCard() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        camera.add(name: "DSC00001.ARW", bytes: Data("raw-1".utf8))
        camera.add(name: "DSC00001.JPG", bytes: Data("jpg-1".utf8))
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(report.source == .camera)
        #expect(report.importedCount == 2)
        #expect(report.succeeded)
        #expect(
            await session.current.shots.map(\.originalFileName) == [
                "DSC00001.ARW", "DSC00001.JPG",
            ])

        let reloaded = try testProject.store.load()
        #expect(reloaded.project.shots.count == 2)
        #expect(reloaded.report.isClean)
    }

    @Test("ARW bytes survive the download → staging → originals/ round trip")
    func rawBytesArePreserved() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        var bytes = Data()
        for value in 0..<16384 { bytes.append(UInt8((value * 13) % 256)) }
        let camera = FakeCameraSession()
        camera.add(name: "DSC09999.ARW", bytes: bytes)
        let source = FakeCameraSource(session: camera)

        _ = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        let shot = try #require(await session.current.shots.first)
        #expect(try Data(contentsOf: testProject.store.originalURL(for: shot)) == bytes)
        #expect(shot.contentHash == ContentHash.of(bytes))
    }

    @Test("Nothing is ever deleted from the camera")
    func neverDeletesFromTheCamera() async throws {
        // `CameraSession` has no delete method to call, which is the real
        // guarantee. This asserts the observable consequence: after a full
        // import the card still lists every file.
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        for index in 1...5 { camera.add(name: "DSC0000\(index).ARW", bytes: Data("f\(index)".utf8)) }
        let source = FakeCameraSource(session: camera)

        _ = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(
            camera.remainingFileNames == [
                "DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW", "DSC00004.ARW", "DSC00005.ARW",
            ])
    }

    @Test("A movie is skipped before it is downloaded, not after")
    func filtersBeforeDownloading() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        camera.add(name: "DSC00001.ARW", bytes: Data("raw".utf8))
        camera.add(name: "C0001.MP4", bytes: Data(repeating: 0, count: 4096))
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(report.importedCount == 1)
        #expect(report.skippedCount == 1)
        #expect(
            report.skips.first?.outcome.skipReason == .unsupportedFileType(pathExtension: "MP4"))
        // The point of the test: no USB time was spent on the movie.
        #expect(camera.downloadedItemIDs == ["100MSDCF/DSC00001.ARW"])
    }

    @Test("One failed download does not abort the card")
    func oneBadFrameDoesNotAbortTheCard() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        camera.add(name: "DSC00001.ARW", bytes: Data("one".utf8))
        camera.add(
            name: "DSC00002.ARW", bytes: Data("two".utf8),
            downloadError: CameraImportError.downloadFailed(
                item: "DSC00002.ARW", message: "I/O error"))
        camera.add(name: "DSC00003.ARW", bytes: Data("three".utf8))
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(report.importedCount == 2)
        #expect(report.failedCount == 1)
        #expect(report.failures.first?.displayName == "DSC00002.ARW")
        #expect(
            await session.current.shots.map(\.originalFileName) == [
                "DSC00001.ARW", "DSC00003.ARW",
            ])
    }

    @Test("Only the requested items are downloaded, in the requested order")
    func importsASelection() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        for index in 1...4 { camera.add(name: "DSC0000\(index).ARW", bytes: Data("f\(index)".utf8)) }
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(
                from: source.device,
                itemIDs: ["100MSDCF/DSC00003.ARW", "100MSDCF/DSC00001.ARW"],
                into: session)

        #expect(report.importedCount == 2)
        #expect(
            await session.current.shots.map(\.originalFileName) == [
                "DSC00003.ARW", "DSC00001.ARW",
            ])
        #expect(camera.downloadedItemIDs == ["100MSDCF/DSC00003.ARW", "100MSDCF/DSC00001.ARW"])
    }

    @Test("A requested item that is no longer on the card is a failure")
    func missingSelectionIsReported() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        camera.add(name: "DSC00001.ARW")
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(
                from: source.device,
                itemIDs: ["100MSDCF/DSC00001.ARW", "100MSDCF/GONE.ARW"], into: session)

        #expect(report.importedCount == 1)
        #expect(report.failedCount == 1)
        #expect(report.failures.first?.displayName == "100MSDCF/GONE.ARW")
    }

    @Test("A camera that will not open a session produces one failure, not a crash")
    func sessionFailureIsReported() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let source = FakeCameraSource(
            session: FakeCameraSession(),
            openError: CameraImportError.sessionFailed("device is busy"))

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(report.failedCount == 1)
        #expect(report.importedCount == 0)
        #expect(!report.succeeded)
        #expect(report.failures.first?.displayName == "ILCE-6300")
        #expect(await session.current.shots.isEmpty)
    }

    @Test("A camera that cannot list its files produces one failure")
    func enumerationFailureIsReported() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession(
            contentsError: CameraImportError.enumerationFailed("PTP timeout"))
        let source = FakeCameraSource(session: camera)

        let report = await makeImporter(source: source, staging: staging.url)
            .importItems(from: source.device, into: session)

        #expect(report.failedCount == 1)
        #expect(report.importedCount == 0)
    }

    @Test("Re-plugging the same card imports nothing the second time")
    func reimportingACardIsIdempotent() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        for index in 1...3 { camera.add(name: "DSC0000\(index).ARW", bytes: Data("f\(index)".utf8)) }
        let source = FakeCameraSource(session: camera)
        let importer = makeImporter(source: source, staging: staging.url)

        let first = await importer.importItems(from: source.device, into: session)
        let second = await importer.importItems(from: source.device, into: session)

        #expect(first.importedCount == 3)
        #expect(second.importedCount == 0)
        #expect(second.skippedCount == 3)
        #expect(await session.current.shots.count == 3)
    }

    @Test("listContents shows the card without importing anything")
    func listContentsDoesNotImport() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }

        let camera = FakeCameraSession()
        camera.add(name: "DSC00001.ARW")
        camera.add(name: "DSC00002.ARW")
        let source = FakeCameraSource(session: camera)

        let items = try await makeImporter(source: source, staging: staging.url)
            .listContents(of: source.device)

        #expect(items.map(\.name) == ["DSC00001.ARW", "DSC00002.ARW"])
        #expect(camera.downloadedItemIDs.isEmpty)
        #expect(try testProject.store.originalFileRelativePaths().isEmpty)
    }

    @Test("availableCameras surfaces the attached device")
    func discoversCameras() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let source = FakeCameraSource(session: FakeCameraSession())
        let cameras = await makeImporter(source: source, staging: staging.url).availableCameras()
        #expect(cameras.map(\.name) == ["ILCE-6300"])
    }

    @Test("The session is closed on every path — success, enumeration failure, listing")
    func alwaysClosesTheSession() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        // An ImageCaptureCore session left open holds the camera against the
        // next attempt, so this is not cosmetic.
        let happy = FakeCameraSession()
        happy.add(name: "DSC00001.ARW")
        let happySource = FakeCameraSource(session: happy)
        _ = await makeImporter(source: happySource, staging: staging.url)
            .importItems(from: happySource.device, into: session)
        #expect(happy.closeCount == 1)

        _ = try await makeImporter(source: happySource, staging: staging.url)
            .listContents(of: happySource.device)
        #expect(happy.closeCount == 2)

        let broken = FakeCameraSession(
            contentsError: CameraImportError.enumerationFailed("PTP timeout"))
        let brokenSource = FakeCameraSource(session: broken)
        _ = await makeImporter(source: brokenSource, staging: staging.url)
            .importItems(from: brokenSource.device, into: session)
        #expect(broken.closeCount == 1)

        await #expect(throws: CameraImportError.self) {
            _ = try await makeImporter(source: brokenSource, staging: staging.url)
                .listContents(of: brokenSource.device)
        }
        #expect(broken.closeCount == 2)
    }

    @Test("Progress is reported once per downloaded item")
    func reportsProgress() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let camera = FakeCameraSession()
        for index in 1...3 { camera.add(name: "DSC0000\(index).ARW", bytes: Data("f\(index)".utf8)) }
        let source = FakeCameraSource(session: camera)

        final class Box: @unchecked Sendable { var seen: [Int] = [] }
        let box = Box()
        _ = await makeImporter(source: source, staging: staging.url)
            .importItems(
                from: source.device, into: session,
                progress: { _, done, _ in box.seen.append(done) })
        #expect(box.seen == [1, 2, 3])
    }
}
