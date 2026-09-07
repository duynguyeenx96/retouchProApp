import Foundation
import ImageIO
import Testing

import RPCore
@testable import RPImport

@Suite("ImportReport — the shared per-file result type")
struct ImportReportTests {
    private func item(_ outcome: ImportOutcome, name: String = "DSC01234.ARW") -> ImportItemResult {
        ImportItemResult(
            source: .files, displayName: name, sourceIdentifier: "/tmp/\(name)", outcome: outcome)
    }

    @Test("Counts split imported / skipped / failed, and skips are not failures")
    func countsAndSuccess() {
        let shotID = ShotID.generate()
        var report = ImportReport(source: .files)
        report.append(item(.imported(shotID: shotID, originalRelativePath: "originals/a.ARW")))
        report.append(item(.skipped(.unsupportedFileType(pathExtension: "txt")), name: "n.txt"))
        report.append(item(.skipped(.duplicateContent(existingShotID: shotID)), name: "dup.ARW"))

        #expect(report.importedCount == 1)
        #expect(report.skippedCount == 2)
        #expect(report.failedCount == 0)
        #expect(report.succeeded, "a skip is a decision, not an error")
        #expect(report.importedShotIDs == [shotID])
        #expect(report.summary == "1 imported, 2 skipped")

        report.append(item(.failed(.copyFailed("disk full")), name: "bad.ARW"))
        #expect(!report.succeeded)
        #expect(report.summary == "1 imported, 2 skipped, 1 failed")
    }

    @Test("Every outcome has readable text a UI or the app log can show")
    func summaryLines() {
        let shotID = ShotID.generate()
        #expect(
            item(.imported(shotID: shotID, originalRelativePath: "originals/a.ARW")).summaryLine
                == "DSC01234.ARW — imported to originals/a.ARW")
        #expect(
            item(.skipped(.unsupportedFileType(pathExtension: "txt"))).summaryLine
                == "DSC01234.ARW — skipped: .txt is not a supported image format")
        #expect(
            item(.skipped(.unsupportedFileType(pathExtension: ""))).summaryLine
                == "DSC01234.ARW — skipped: no file extension, so the format is unknown")
        #expect(
            item(.failed(.copyFailed("disk full"))).summaryLine
                == "DSC01234.ARW — failed: copy failed: disk full")
        #expect(
            item(.skipped(.stillBeingWritten(observedBytes: 2048))).summaryLine
                == "DSC01234.ARW — skipped: still being written (2048 bytes so far); will retry")
    }

    @Test("A report survives a JSON round trip, so it can be logged and re-read")
    func codableRoundTrip() throws {
        // Whole-millisecond timestamps: RPJSON writes ISO-8601 with
        // milliseconds (ADR-0002 §12), so a `Date()` would lose sub-ms
        // precision in the round trip and the equality would be about the date
        // format, not about the report.
        let start = Date(timeIntervalSince1970: 1_800_000_000.125)
        var report = ImportReport(
            source: .camera, startedAt: start, finishedAt: start.addingTimeInterval(2.5))
        report.append(
            item(.imported(shotID: .generate(), originalRelativePath: "originals/a.ARW")))
        report.append(item(.failed(.timedOut("60 s"))))
        report.append(item(.skipped(.cancelled)))

        let data = try RPJSON.encoder.encode(report)
        let decoded = try RPJSON.decoder.decode(ImportReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("ProjectStoreError keeps its own wording when wrapped")
    func wrapsStoreErrorsWithTheirMessage() {
        let storeError = ProjectStoreError.sourceFileNotFound(path: "/Volumes/CARD/a.ARW")
        let failure = ImportFailure.wrapping(storeError) { .copyFailed($0) }
        #expect(failure == .storeRejected(storeError.description))

        // An already-classified failure passes through unchanged.
        #expect(
            ImportFailure.wrapping(ImportFailure.timedOut("x")) { .copyFailed($0) }
                == .timedOut("x"))
    }

    @Test("Merging keeps every item and widens the time span")
    func merge() {
        let start = Date(timeIntervalSince1970: 1_000)
        var first = ImportReport(
            source: .folderWatch, startedAt: start, finishedAt: start.addingTimeInterval(5))
        first.append(item(.skipped(.cancelled)))
        var second = ImportReport(
            source: .folderWatch,
            startedAt: start.addingTimeInterval(3),
            finishedAt: start.addingTimeInterval(9))
        second.append(item(.failed(.unreadable("x"))))

        first.merge(second)
        #expect(first.items.count == 2)
        #expect(first.startedAt == start)
        #expect(first.duration == 9)
    }

    @Test("Every import source has a stable raw value for logs and settings")
    func sourceRawValues() {
        #expect(
            ImportSource.allCases.map(\.rawValue) == ["files", "photos", "camera", "folderWatch"])
    }
}

@Suite("ContentHash")
struct ContentHashTests {
    @Test("Hashing a file and hashing its bytes agree, and the algorithm is named")
    func fileAndDataAgree() throws {
        let dir = TempDirectory("hash")
        defer { dir.remove() }
        var bytes = Data()
        for value in 0..<100_000 { bytes.append(UInt8(value % 251)) }
        let url = try dir.writeFile("big.ARW", bytes: bytes)

        let digest = try ContentHash.of(fileAt: url)
        #expect(digest == ContentHash.of(bytes))
        #expect(digest.hasPrefix("sha256:"))
        #expect(digest.count == "sha256:".count + 64)
    }

    @Test("An empty file hashes to the known SHA-256 of nothing")
    func emptyFile() throws {
        let dir = TempDirectory("hash")
        defer { dir.remove() }
        let url = try dir.writeFile("empty.jpg", bytes: Data())
        #expect(
            try ContentHash.of(fileAt: url)
                == "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("A file larger than the read chunk hashes the same as one contiguous buffer")
    func spansMultipleChunks() throws {
        let dir = TempDirectory("hash")
        defer { dir.remove() }
        // Deliberately not a multiple of the chunk size, so the final short
        // read is exercised.
        let bytes = Data((0..<(ContentHash.chunkBytes + 12345)).map { UInt8($0 % 256) })
        let url = try dir.writeFile("chunky.ARW", bytes: bytes)
        #expect(try ContentHash.of(fileAt: url) == ContentHash.of(bytes))
    }

    @Test("A single flipped byte changes the hash")
    func detectsASingleBitFlip() throws {
        let dir = TempDirectory("hash")
        defer { dir.remove() }
        var bytes = Data(repeating: 7, count: 8192)
        let a = try dir.writeFile("a.ARW", bytes: bytes)
        bytes[4096] = 8
        let b = try dir.writeFile("b.ARW", bytes: bytes)
        #expect(try ContentHash.of(fileAt: a) != ContentHash.of(fileAt: b))
    }
}

@Suite("ImageIOMetadataExtractor")
struct MetadataExtractorTests {
    @Test("EXIF/TIFF dictionaries map onto CaptureMetadata")
    func mapsProperties() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 6000,
            kCGImagePropertyPixelHeight: 4000,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SONY",
                kCGImagePropertyTIFFModel: "ILCE-6300",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifLensModel: "E 35mm F1.8 OSS",
                kCGImagePropertyExifDateTimeOriginal: "2026:09:04 11:22:33",
            ] as [CFString: Any],
        ]

        let metadata = ImageIOMetadataExtractor.metadata(fromImageProperties: properties)
        #expect(metadata.pixelWidth == 6000)
        #expect(metadata.pixelHeight == 4000)
        #expect(metadata.orientation == 6)
        #expect(metadata.cameraMake == "SONY")
        #expect(metadata.cameraModel == "ILCE-6300")
        #expect(metadata.lens == "E 35mm F1.8 OSS")
        #expect(metadata.iso == 400)
        #expect(metadata.shutterSpeedSeconds == 0.004)
        #expect(metadata.aperture == 2.8)
        #expect(metadata.focalLengthMillimetres == 35.0)

        // EXIF has no time zone, so the string is read as local wall-clock time.
        let expected = ImageIOMetadataExtractor.exifDateFormatter.date(from: "2026:09:04 11:22:33")
        #expect(metadata.capturedAt == expected)
    }

    @Test("Empty properties give empty metadata rather than junk")
    func emptyProperties() {
        #expect(ImageIOMetadataExtractor.metadata(fromImageProperties: [:]).isEmpty)
    }

    @Test("A file that is not an image yields empty metadata instead of throwing")
    func unreadableFileIsNotAnError() throws {
        let dir = TempDirectory("meta")
        defer { dir.remove() }
        let url = try dir.writeFile("not-an-image.jpg", contents: "definitely not JPEG")
        #expect(ImageIOMetadataExtractor().metadata(forFileAt: url).isEmpty)
    }

    @Test("Real EXIF is read out of a generated JPEG")
    func readsRealFile() throws {
        // A 2×2 JPEG written by ImageIO with TIFF/EXIF tags attached, so the
        // whole path — CGImageSource, property dictionaries, mapping — is
        // exercised rather than just the mapping function.
        let dir = TempDirectory("meta")
        defer { dir.remove() }
        let url = dir.url.appendingPathComponent("exif.jpg")
        try #require(ImportTestImage.writeJPEG(to: url, make: "SONY", model: "ILCE-6300", iso: 800))

        let metadata = ImageIOMetadataExtractor().metadata(forFileAt: url)
        #expect(metadata.cameraMake == "SONY")
        #expect(metadata.cameraModel == "ILCE-6300")
        #expect(metadata.iso == 800)
        #expect(metadata.pixelWidth == 2)
        #expect(metadata.pixelHeight == 2)
    }
}
