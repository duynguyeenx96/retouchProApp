import Foundation
import Testing

import RPCore
@testable import RPImport

/// These tests swap PhotoKit for ``FakePhotoLibrary``. That is a real
/// limitation and worth naming: **nothing here exercises `PHPhotoLibrary`,
/// `PHAssetResourceManager` or the permission prompt.** The real
/// ``PhotoKitLibrarySource`` needs a signed app, an
/// `NSPhotoLibraryUsageDescription` and a user tapping "Allow", and is verified
/// by hand.
///
/// What these tests *do* pin down is everything between the library and the
/// bundle: that the exported bytes reach `originals/` unchanged, that the
/// asset's own file name survives the staging round trip, that a denied
/// library produces failures rather than an empty success, and that a failing
/// export does not abort the batch.
@Suite("PhotosImporter — wiring, with PhotoKit faked out")
struct PhotosImporterTests {
    private func makeImporter(library: FakePhotoLibrary, staging: URL) -> PhotosImporter {
        PhotosImporter(
            library: library,
            options: ImportOptions(usesSecurityScopedAccess: false),
            metadataExtractor: NullMetadataExtractor(),
            stagingDirectory: staging
        )
    }

    @Test("Assets land in originals/ with their own file names and bytes")
    func importsAssetsIntoTheBundle() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "asset-1", fileName: "IMG_0001.DNG", bytes: Data("raw-one".utf8))
        library.add(id: "asset-2", fileName: "IMG_0002.HEIC", bytes: Data("heic-two".utf8))

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["asset-1", "asset-2"], into: session)

        #expect(report.source == .photos)
        #expect(report.importedCount == 2)
        #expect(report.succeeded)

        let project = await session.current
        #expect(project.shots.map(\.originalFileName) == ["IMG_0001.DNG", "IMG_0002.HEIC"])
        let first = try #require(project.shots.first)
        #expect(try Data(contentsOf: testProject.store.originalURL(for: first)) == Data("raw-one".utf8))

        // The manifest on disk agrees.
        let reloaded = try testProject.store.load()
        #expect(reloaded.project.shots.count == 2)
        #expect(reloaded.report.isClean)
    }

    @Test("A RAW asset is copied verbatim, not re-encoded")
    func rawAssetIsPreserved() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        var bytes = Data()
        for value in 0..<8192 { bytes.append(UInt8((value * 7) % 256)) }
        let library = FakePhotoLibrary()
        library.add(id: "raw", fileName: "DSC01234.ARW", bytes: bytes, hasRAWResource: true)

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["raw"], into: session)

        #expect(report.importedCount == 1)
        let shot = try #require(await session.current.shots.first)
        #expect(try Data(contentsOf: testProject.store.originalURL(for: shot)) == bytes)
        #expect(shot.contentHash == ContentHash.of(bytes))
    }

    @Test("The staged temp copy is cleaned up, and originals/ holds exactly one file")
    func stagingIsCleanedUp() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "a", fileName: "IMG_0001.JPG")

        _ = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["a"], into: session)

        let leftovers = FileManager.default.enumerator(
            at: staging.url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath } ?? []
        #expect(leftovers.isEmpty, "staged files left behind: \(leftovers.map(\.lastPathComponent))")

        let originals = try testProject.store.originalFileRelativePaths()
        #expect(originals == ["originals/IMG_0001.JPG"])
    }

    @Test("A denied library reports one permission failure per requested asset")
    func deniedLibraryFailsLoudly() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary(status: .denied)
        library.add(id: "a", fileName: "IMG_0001.JPG")

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["a", "b"], into: session)

        #expect(report.importedCount == 0)
        #expect(report.failedCount == 2)
        #expect(report.failures.allSatisfy { if case .permissionDenied = $0.outcome.failure! { true } else { false } })
        #expect(await session.current.shots.isEmpty)
        // Nothing was even asked for.
        #expect(library.exportedAssetIDs.isEmpty)
    }

    @Test("A limited library is allowed to read")
    func limitedLibraryStillImports() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary(status: .limited)
        library.add(id: "a", fileName: "IMG_0001.JPG")

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["a"], into: session)
        #expect(report.importedCount == 1)
    }

    @Test("One failing export does not stop the rest of the batch")
    func oneFailureDoesNotAbortTheBatch() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "ok-1", fileName: "IMG_0001.JPG", bytes: Data("one".utf8))
        library.add(
            id: "bad", fileName: "IMG_0002.JPG", bytes: Data("two".utf8),
            exportError: .exportFailed("iCloud download failed"))
        library.add(id: "ok-2", fileName: "IMG_0003.JPG", bytes: Data("three".utf8))

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["ok-1", "bad", "ok-2"], into: session)

        #expect(report.importedCount == 2)
        #expect(report.failedCount == 1)
        let failure = try #require(report.failures.first)
        #expect(failure.sourceIdentifier == "bad")
        #expect(failure.displayName == "IMG_0002.JPG")
        #expect(failure.outcome.failure == .sourceError("iCloud download failed"))
        #expect(await session.current.shots.count == 2)
    }

    @Test("An identifier the library does not know is a failure, not a silent gap")
    func unknownIdentifierIsReported() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "known", fileName: "IMG_0001.JPG")

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["known", "vanished"], into: session)

        #expect(report.importedCount == 1)
        #expect(report.failedCount == 1)
        #expect(report.failures.first?.sourceIdentifier == "vanished")
    }

    @Test("Report lines are keyed by asset identifier, not the staging path")
    func reportIsKeyedByAssetIdentifier() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "asset-42", fileName: "IMG_0042.JPG")

        let report = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["asset-42"], into: session)

        let item = try #require(report.items.first)
        #expect(item.sourceIdentifier == "asset-42")
        #expect(item.displayName == "IMG_0042.JPG")
        #expect(!item.sourceIdentifier.contains(staging.url.path))
    }

    @Test("The asset's creation date fills a shot with no EXIF date")
    func fillsCaptureDateFromTheAsset() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let creation = Date(timeIntervalSince1970: 1_700_000_000)
        let library = FakePhotoLibrary()
        library.add(id: "a", fileName: "IMG_0001.JPG", creationDate: creation)

        _ = await makeImporter(library: library, staging: staging.url)
            .importAssets(withLocalIdentifiers: ["a"], into: session)

        let shot = try #require(await session.current.shots.first)
        let capturedAt = try #require(shot.capture.capturedAt)
        #expect(abs(capturedAt.timeIntervalSince(creation)) < RPJSON.dateResolution)
        #expect(shot.capture.pixelWidth == 6000)
        #expect(shot.capture.pixelHeight == 4000)
    }

    @Test("ensureAuthorization only prompts when the status is undetermined")
    func promptsOnlyWhenUndetermined() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }

        let authorized = FakePhotoLibrary(status: .authorized)
        _ = await makeImporter(library: authorized, staging: staging.url).ensureAuthorization()
        #expect(authorized.requestAuthorizationCallCount == 0)

        let undetermined = FakePhotoLibrary(status: .notDetermined)
        _ = await makeImporter(library: undetermined, staging: staging.url).ensureAuthorization()
        #expect(undetermined.requestAuthorizationCallCount == 1)
    }

    @Test("Importing the same asset twice is skipped as a duplicate")
    func deduplicatesRepeatedAssets() async throws {
        let staging = TempDirectory("staging")
        defer { staging.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let library = FakePhotoLibrary()
        library.add(id: "a", fileName: "IMG_0001.JPG", bytes: Data("same".utf8))
        let importer = makeImporter(library: library, staging: staging.url)

        _ = await importer.importAssets(withLocalIdentifiers: ["a"], into: session)
        let second = await importer.importAssets(withLocalIdentifiers: ["a"], into: session)

        #expect(second.importedCount == 0)
        #expect(second.skippedCount == 1)
        #expect(await session.current.shots.count == 1)
    }
}
