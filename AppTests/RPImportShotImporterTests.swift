import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import RPCore
import RPImport
import RPUI

/// Tests for `App/RPImportShotImporter.swift` — the adapter that joins RPUI's
/// `ShotImporting` seam to RPImport's importers (docs/ADR-0014).
///
/// ## Why here and not in a package
///
/// Same reason as `FaceAnalysisRenderBridgeTests`: the code under test is in the
/// app target because it is the only place that links both sides. `RPUI` has no
/// `RPImport` edge (docs/ADR-0004 amendment, asserted by
/// `LayeringAuditTests.noUpwardImports`), so no package test can reach this file.
/// The target has no `TEST_HOST`; it compiles `App/RPImportShotImporter.swift`
/// into itself and links RPImport + RPUI once.
///
/// ## What is and is not covered
///
/// Covered: real files really landing in `originals/` through the real
/// `FilesImporter`, the report → `ShotImportSummary` narrowing, de-duplication
/// surviving the seam, an unsupported file coming back as a skip rather than an
/// error, and the Photos path driven through a fake `PhotoLibrarySource`.
///
/// **Not covered, and it cannot be:** PhotoKit itself. `PhotoKitLibrarySource`
/// needs a signed bundle, an `NSPhotoLibraryUsageDescription` and a user tapping
/// Allow (docs/ADR-0003 §5), so the fake below stands in for it exactly as
/// `PhotosImporterTests` does inside RPImport.
@Suite("App — RPUI ShotImporting → RPImport adapter")
struct RPImportShotImporterTests {

    // MARK: - Fixtures

    /// A temporary `.rpproj` plus a scratch folder to import from.
    struct Fixture {
        let root: URL
        let store: ProjectStore
        let session: ProjectSession

        init(name: String = "Adapter") throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rp-adapter-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let created = try ProjectStore.create(name: name, in: root)
            store = created.store
            session = ProjectSession(store: created.store, project: created.project)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func reloadedProject() throws -> Project { try store.load().project }

        @discardableResult
        func writePNG(named name: String, size: Int = 24) throws -> URL {
            let url = root.appendingPathComponent(name)
            let context = try #require(
                CGContext(
                    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
    }

    /// Stands in for `PhotoKitLibrarySource`; exports by copying a file that is
    /// already on disk, which is what the real one does after PhotoKit hands it
    /// the resource.
    struct FakeLibrary: PhotoLibrarySource {
        var status: PhotoAuthorization = .authorized
        /// `localIdentifier -> (file name the user knows, bytes on disk)`.
        var assets: [String: (name: String, url: URL)]

        func authorizationStatus() async -> PhotoAuthorization { status }
        func requestAuthorization() async -> PhotoAuthorization { status }

        func assets(withLocalIdentifiers identifiers: [String]) async throws
            -> [PhotoAssetDescriptor]
        {
            identifiers.compactMap { id in
                assets[id].map {
                    PhotoAssetDescriptor(
                        id: id, originalFileName: $0.name,
                        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                        pixelWidth: 24, pixelHeight: 24)
                }
            }
        }

        func exportOriginal(_ asset: PhotoAssetDescriptor, to directory: URL) async throws -> URL {
            guard let source = assets[asset.id] else {
                throw PhotoLibraryError.assetNotFound(asset.id)
            }
            let destination = directory.appendingPathComponent(source.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source.url, to: destination)
            return destination
        }
    }

    /// Collects what the adapter would have written to the app log.
    final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func write(_ line: String) {
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

    // MARK: - Files

    @Test("Picked files reach originals/ and come back as a summary")
    func filesImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sink = LogSink()
        let importer = RPImportShotImporter(log: { sink.write($0) })

        let a = try fixture.writePNG(named: "DSC00001.png")
        let b = try fixture.writePNG(named: "DSC00002.png", size: 26)

        let summary = await importer.importFiles(at: [a, b], into: fixture.session)

        #expect(summary.importedCount == 2)
        #expect(summary.failedCount == 0)
        #expect(summary.importedShotIDs.count == 2)
        #expect(summary.message == "2 imported")

        let project = try fixture.reloadedProject()
        #expect(project.shots.map(\.originalFileName) == ["DSC00001.png", "DSC00002.png"])
        for shot in project.shots {
            let url = fixture.store.originalURL(for: shot)
            #expect(FileManager.default.fileExists(atPath: url.path))
            // RPImport's default options hash the content; the UI relies on that
            // for the duplicate check below and RPEngine's preview cache keys on
            // it (docs/ADR-0013).
            #expect(shot.contentHash != nil)
        }
        // The run is written to the log in full, so a failed import can be read
        // out of session.log rather than guessed at from a banner.
        #expect(sink.all.count == 1)
        #expect(sink.all[0].contains("import(files)"))
        #expect(sink.all[0].contains("DSC00001.png"))
    }

    @Test("Importing the same file twice adds one shot and reports a skip")
    func duplicatesAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let importer = RPImportShotImporter(log: { _ in })
        let file = try fixture.writePNG(named: "same.png")

        let first = await importer.importFiles(at: [file], into: fixture.session)
        let second = await importer.importFiles(at: [file], into: fixture.session)

        #expect(first.importedCount == 1)
        #expect(second.importedCount == 0)
        // A skip is not a failure — the banner must not go red for re-picking a
        // file that is already in the project (docs/ADR-0003 §2).
        #expect(second.skippedCount == 1)
        #expect(second.failedCount == 0)
        #expect(try fixture.reloadedProject().shots.count == 1)
    }

    @Test("A file type the project cannot hold is a skip, not a failure")
    func unsupportedTypeIsASkip() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let importer = RPImportShotImporter(log: { _ in })
        let notes = fixture.root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)

        let summary = await importer.importFiles(at: [notes], into: fixture.session)
        #expect(summary.importedCount == 0)
        #expect(summary.skippedCount == 1)
        #expect(summary.failedCount == 0)
        #expect(try fixture.reloadedProject().shots.isEmpty)
    }

    @Test("A file that is not there is a failure the UI can show")
    func missingFileIsAFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let importer = RPImportShotImporter(log: { _ in })

        let summary = await importer.importFiles(
            at: [fixture.root.appendingPathComponent("ghost.png")], into: fixture.session)
        #expect(summary.failedCount == 1)
        #expect(summary.importedCount == 0)
        #expect(summary.message.contains("failed"))
    }

    // MARK: - Photos

    @Test("Picked photos are staged, ingested and named after the asset")
    func photosImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.writePNG(named: "staged-source.png")
        let library = FakeLibrary(assets: ["asset-1": (name: "IMG_0042.png", url: source)])
        let importer = RPImportShotImporter(photoLibrary: library, log: { _ in })

        let summary = await importer.importPhotos(
            withLocalIdentifiers: ["asset-1"], into: fixture.session)

        #expect(summary.importedCount == 1)
        let project = try fixture.reloadedProject()
        // The name the user knows, not the staging file's name.
        #expect(project.shots.map(\.originalFileName) == ["IMG_0042.png"])
        #expect(project.shots[0].capture.capturedAt != nil)
    }

    @Test("A denied photo library is a per-asset failure, not an empty success")
    func photosDenied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = FakeLibrary(status: .denied, assets: [:])
        let importer = RPImportShotImporter(photoLibrary: library, log: { _ in })

        let summary = await importer.importPhotos(
            withLocalIdentifiers: ["asset-1", "asset-2"], into: fixture.session)
        #expect(summary.importedCount == 0)
        #expect(summary.failedCount == 2)
        #expect(try fixture.reloadedProject().shots.isEmpty)
    }

    // MARK: - Seam

    /// The adapter is what the app hands to RPUI, so it has to satisfy the
    /// protocol RPUI declares — asserted rather than assumed.
    @Test("The adapter is usable as RPUI's ShotImporting")
    func conformsToTheSeam() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seam: any ShotImporting = RPImportShotImporter(log: { _ in })
        let file = try fixture.writePNG(named: "via-seam.png")

        let summary = await seam.importFiles(at: [file], into: fixture.session)
        #expect(summary.importedCount == 1)
        #expect(summary.isEmpty == false)
    }
}
