import Foundation
import Testing

import RPCore
@testable import RPImport

@Suite("FilesImporter — picker and drag-drop")
struct FilesImporterTests {
    /// Every test uses a real `ProjectStore` on a real temp directory. There is
    /// no mock of RPCore anywhere in this suite: the thing worth checking is
    /// that the bundle on disk is right afterwards.
    private func makeImporter(
        options: ImportOptions = ImportOptions(usesSecurityScopedAccess: false)
    ) -> FilesImporter {
        FilesImporter(options: options, metadataExtractor: NullMetadataExtractor())
    }

    @Test("Imports picked files into originals/ and registers them in the manifest")
    func importsIntoBundle() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let a = try source.writeFile("DSC01234.ARW", contents: "raw-a")
        let b = try source.writeFile("DSC01235.JPG", contents: "jpeg-b")

        let report = makeImporter().importFiles(
            at: [a, b], into: &testProject.project, using: testProject.store)

        #expect(report.source == .files)
        #expect(report.importedCount == 2)
        #expect(report.failedCount == 0)
        #expect(report.succeeded)
        #expect(testProject.project.shots.count == 2)

        // The manifest on disk, not just the in-memory struct.
        let reloaded = try testProject.reload()
        #expect(reloaded.project.shots.count == 2)
        #expect(reloaded.report.isClean)
        #expect(
            reloaded.project.shots.map(\.originalRelativePath) == [
                "originals/DSC01234.ARW", "originals/DSC01235.JPG",
            ])
    }

    @Test("RAW bytes are copied verbatim — no re-encode, source untouched")
    func rawIsPreservedByteForByte() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        // A byte pattern that no image encoder would reproduce, so any
        // round-trip through a codec would show up immediately.
        var bytes = Data()
        for value in 0..<4096 { bytes.append(UInt8(value % 256)) }
        let arw = try source.writeFile("DSC09999.ARW", bytes: bytes)
        let sourceDigest = ContentHash.of(bytes)

        let report = makeImporter().importFiles(
            at: [arw], into: &testProject.project, using: testProject.store)
        let shot = try #require(testProject.project.shots.first)

        let copied = try Data(contentsOf: testProject.store.originalURL(for: shot))
        #expect(copied == bytes)
        #expect(shot.contentHash == sourceDigest)
        #expect(report.importedCount == 1)

        // The file the user picked is still exactly where and what it was.
        #expect(try Data(contentsOf: arw) == bytes)
    }

    @Test("Disallowed extensions are reported as skips, not dropped silently")
    func rejectsDisallowedExtensions() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let good = try source.writeFile("keep.jpg")
        let bad = try source.writeFile("notes.txt")
        let noExtension = try source.writeFile("README")

        let report = makeImporter().importFiles(
            at: [good, bad, noExtension], into: &testProject.project, using: testProject.store)

        #expect(report.items.count == 3)
        #expect(report.importedCount == 1)
        #expect(report.skippedCount == 2)
        #expect(report.failedCount == 0)
        #expect(report.skips.map(\.displayName).sorted() == ["README", "notes.txt"])
        #expect(
            report.skips.contains {
                $0.outcome.skipReason == .unsupportedFileType(pathExtension: "txt")
            })
        #expect(
            report.skips.contains {
                $0.outcome.skipReason == .unsupportedFileType(pathExtension: "")
            })
        #expect(testProject.project.shots.count == 1)
    }

    @Test("A missing file is a failure with the path in it, and does not stop the run")
    func missingFileDoesNotAbortTheRun() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let present = try source.writeFile("present.jpg", contents: "one")
        let absent = source.url.appendingPathComponent("ejected.ARW")
        let alsoPresent = try source.writeFile("present2.jpg", contents: "two")

        let report = makeImporter().importFiles(
            at: [absent, present, alsoPresent], into: &testProject.project, using: testProject.store
        )

        #expect(report.importedCount == 2)
        #expect(report.failedCount == 1)
        #expect(!report.succeeded)
        let failure = try #require(report.failures.first)
        #expect(failure.displayName == "ejected.ARW")
        #expect(failure.outcome.failure == .sourceUnavailable(absent.standardizedFileURL.path))
        // The two good files still landed, in order.
        #expect(testProject.project.shots.map(\.originalFileName) == ["present.jpg", "present2.jpg"])
    }

    @Test("Re-importing the same bytes is skipped as a duplicate")
    func deduplicatesByContentHash() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let original = try source.writeFile("DSC01234.ARW", contents: "identical")
        let renamedCopy = try source.writeFile("copy/DSC01234.ARW", contents: "identical")

        let importer = makeImporter()
        let first = importer.importFiles(
            at: [original], into: &testProject.project, using: testProject.store)
        let second = importer.importFiles(
            at: [renamedCopy], into: &testProject.project, using: testProject.store)

        let shotID = try #require(first.importedShotIDs.first)
        #expect(second.importedCount == 0)
        #expect(second.skippedCount == 1)
        #expect(
            second.skips.first?.outcome.skipReason == .duplicateContent(existingShotID: shotID))
        #expect(testProject.project.shots.count == 1)
    }

    @Test("With hashing off, the same file imports twice under a suffixed name")
    func withoutHashingDuplicatesAreAllowed() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let file = try source.writeFile("DSC01234.ARW", contents: "identical")
        let importer = makeImporter(
            options: ImportOptions(
                computeContentHash: false, skipDuplicates: false,
                usesSecurityScopedAccess: false))

        importer.importFiles(at: [file], into: &testProject.project, using: testProject.store)
        importer.importFiles(at: [file], into: &testProject.project, using: testProject.store)

        #expect(testProject.project.shots.count == 2)
        // ProjectStore's collision suffix; the camera's name is kept on the shot.
        #expect(
            testProject.project.shots.map(\.originalRelativePath) == [
                "originals/DSC01234.ARW", "originals/DSC01234-2.ARW",
            ])
        #expect(testProject.project.shots.allSatisfy { $0.originalFileName == "DSC01234.ARW" })
        #expect(testProject.project.shots.allSatisfy { $0.contentHash == nil })
    }

    @Test("A dropped folder is walked, in name order, ignoring non-images")
    func expandsDroppedDirectories() throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        try card.writeFile("DCIM/100MSDCF/DSC00002.JPG", contents: "2")
        try card.writeFile("DCIM/100MSDCF/DSC00001.ARW", contents: "1")
        try card.writeFile("DCIM/100MSDCF/DSC00003.MP4", contents: "movie")
        try card.writeFile("DCIM/MISC/notes.txt", contents: "x")
        try card.writeFile("PRIVATE/AVCHD/index.bdm", contents: "x")

        let report = makeImporter().importFiles(
            at: [card.url], into: &testProject.project, using: testProject.store)

        #expect(report.items.count == 2)
        #expect(report.importedCount == 2)
        #expect(
            testProject.project.shots.map(\.originalFileName) == [
                "DSC00001.ARW", "DSC00002.JPG",
            ])
    }

    @Test("The same file picked twice is imported once and the repeat is reported")
    func duplicateInputIsReportedNotImportedTwice() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let file = try source.writeFile("DSC01234.ARW")

        // File plus its own parent folder: the classic double-drop.
        let report = makeImporter().importFiles(
            at: [file, source.url], into: &testProject.project, using: testProject.store)

        #expect(report.importedCount == 1)
        #expect(report.skippedCount == 1)
        #expect(report.skips.first?.outcome.skipReason == .alreadyHandledInThisRun)
        #expect(testProject.project.shots.count == 1)
    }

    @Test("Directory recursion stops at maximumDirectoryDepth")
    func respectsDepthLimit() throws {
        let root = TempDirectory("deep")
        defer { root.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        try root.writeFile("a/shallow.jpg")
        try root.writeFile("a/b/c/deep.jpg")

        let importer = makeImporter(
            options: ImportOptions(maximumDirectoryDepth: 2, usesSecurityScopedAccess: false))
        importer.importFiles(at: [root.url], into: &testProject.project, using: testProject.store)

        #expect(testProject.project.shots.map(\.originalFileName) == ["shallow.jpg"])
    }

    @Test("EXIF is read into Shot.capture through the injected extractor")
    func fillsCaptureMetadata() throws {
        struct StubExtractor: CaptureMetadataExtracting {
            func metadata(forFileAt url: URL) -> CaptureMetadata {
                CaptureMetadata(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    cameraMake: "SONY",
                    cameraModel: "ILCE-6300",
                    iso: 400,
                    pixelWidth: 6000,
                    pixelHeight: 4000
                )
            }
        }
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }
        let file = try source.writeFile("DSC01234.ARW")

        let importer = FilesImporter(
            options: ImportOptions(usesSecurityScopedAccess: false),
            metadataExtractor: StubExtractor())
        importer.importFiles(at: [file], into: &testProject.project, using: testProject.store)

        let shot = try #require(testProject.project.shots.first)
        #expect(shot.capture.cameraModel == "ILCE-6300")
        #expect(shot.capture.iso == 400)
        // And it survives the manifest round trip.
        let reloaded = try testProject.reload()
        #expect(reloaded.project.shots.first?.capture.cameraMake == "SONY")
    }

    @Test("Progress is reported once per item with a running count")
    func reportsProgress() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }
        for index in 1...3 { try source.writeFile("shot\(index).jpg") }

        final class Box: @unchecked Sendable {
            var seen: [(Int, Int)] = []
        }
        let box = Box()
        makeImporter().importFiles(
            at: [source.url], into: &testProject.project, using: testProject.store,
            progress: { _, done, total in box.seen.append((done, total)) })

        #expect(box.seen.map(\.0) == [1, 2, 3])
        #expect(box.seen.allSatisfy { $0.1 == 3 })
    }

    @Test("Interrupting after a copy leaves an orphan that load() adopts")
    func orphanFromInterruptedImportIsAdopted() throws {
        // ADR-0002 documents this seam explicitly: RPImport must go through
        // addShot so an interrupted import is recoverable by load(). Simulate
        // the interruption by copying into originals/ without a manifest write
        // — exactly the state a crash between the two steps leaves behind.
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }

        let file = try source.writeFile("DSC04242.ARW", contents: "orphaned")
        try FileManager.default.copyItem(
            at: file, to: testProject.store.originalsURL.appendingPathComponent("DSC04242.ARW"))

        let reloaded = try testProject.reload()
        #expect(reloaded.report.adoptedOriginals == ["originals/DSC04242.ARW"])
        #expect(reloaded.project.shots.count == 1)
    }

    @Test("importFile returns the single item's result")
    func singleFileConvenience() throws {
        let source = TempDirectory("source")
        defer { source.remove() }
        var testProject = try TestProject()
        defer { testProject.remove() }
        let file = try source.writeFile("one.heic")

        let item = makeImporter().importFile(
            at: file, into: &testProject.project, using: testProject.store)
        #expect(item.outcome.isImported)
        #expect(item.displayName == "one.heic")
    }
}
