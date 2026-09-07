import Foundation
import Testing

import RPCore
@testable import RPImport

@Suite("FolderWatcher — debounce, stability, availability")
struct FolderWatcherTests {
    /// Builds a watcher over `folder` writing into a real project bundle, with
    /// an injected clock so the stability rule can be driven without sleeping.
    private func makeWatcher(
        folder: URL,
        session: ProjectSession,
        clock: TestClock,
        stabilityInterval: TimeInterval = 1.5,
        importsPreexistingFiles: Bool = true,
        recursive: Bool = true,
        fileManager: sending FileManager = FileManager()
    ) -> FolderWatcher {
        FolderWatcher(
            configuration: FolderWatcher.Configuration(
                url: folder,
                stabilityInterval: stabilityInterval,
                pollInterval: 0.05,
                recursive: recursive,
                importsPreexistingFiles: importsPreexistingFiles,
                now: clock.now
            ),
            host: session,
            options: ImportOptions(usesSecurityScopedAccess: false),
            metadataExtractor: NullMetadataExtractor(),
            fileManager: fileManager
        )
    }

    @Test("A file that is still growing is not imported until its size holds still")
    func waitsForTheWriteToFinish() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        // The card copy starts: the file exists at its final path with only
        // part of its bytes.
        try card.writeFile("DSC01234.ARW", bytes: Data(repeating: 0xAA, count: 1024))

        // Scan 1 — first sighting. Nothing is stable yet by definition.
        var report = await watcher.scanOnce()
        #expect(report.importedCount == 0)
        #expect(
            report.skips.first?.outcome.skipReason == .stillBeingWritten(observedBytes: 1024))

        // Time passes, but the copy is still running: the size changed, so the
        // stability window restarts even though 2 s have gone by.
        clock.advance(by: 2.0)
        try card.append("DSC01234.ARW", bytes: Data(repeating: 0xBB, count: 2048))
        report = await watcher.scanOnce()
        #expect(report.importedCount == 0)
        #expect(
            report.skips.first?.outcome.skipReason == .stillBeingWritten(observedBytes: 3072))
        #expect(await session.current.shots.isEmpty)

        // Copy finished. One scan inside the window still refuses…
        clock.advance(by: 0.5)
        report = await watcher.scanOnce()
        #expect(report.importedCount == 0)

        // …and one past it imports.
        clock.advance(by: 1.5)
        report = await watcher.scanOnce()
        #expect(report.importedCount == 1)

        let project = await session.current
        #expect(project.shots.map(\.originalFileName) == ["DSC01234.ARW"])

        // And the bytes that landed are the *whole* file, not the 1024 that
        // existed at first sighting. This is the failure the debounce exists
        // to prevent, and `originals/` is immutable so it would be permanent.
        let shot = try #require(project.shots.first)
        let imported = try Data(contentsOf: testProject.store.originalURL(for: shot))
        #expect(imported.count == 3072)
        #expect(imported.prefix(1024).allSatisfy { $0 == 0xAA })
        #expect(imported.suffix(2048).allSatisfy { $0 == 0xBB })
    }

    @Test("A file already stable when first seen still waits one full interval")
    func firstSightingIsNeverImmediate() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        try card.writeFile("a.jpg", contents: "complete")
        #expect(await watcher.scanOnce().importedCount == 0)
        clock.advance(by: 1.5)
        #expect(await watcher.scanOnce().importedCount == 1)
    }

    @Test("importExistingContents takes what is already there without waiting")
    func importsExistingContentsImmediately() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        try card.writeFile("DCIM/100MSDCF/DSC00001.ARW", contents: "1")
        try card.writeFile("DCIM/100MSDCF/DSC00002.ARW", contents: "2")

        let report = await watcher.importExistingContents()
        #expect(report.importedCount == 2)
        #expect(
            await session.current.shots.map(\.originalFileName) == ["DSC00001.ARW", "DSC00002.ARW"])
    }

    @Test("With importsPreexistingFiles off, only files that arrive after start() count")
    func ignoresPreexistingFilesByDefault() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        try card.writeFile("old.jpg", contents: "from last week")
        let watcher = makeWatcher(
            folder: card.url, session: session, clock: clock, importsPreexistingFiles: false)
        await watcher.start()
        await watcher.stop()

        try card.writeFile("new.jpg", contents: "just shot")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let report = await watcher.scanOnce()

        #expect(report.importedCount == 1)
        #expect(await session.current.shots.map(\.originalFileName) == ["new.jpg"])
    }

    @Test("An already-imported file is not re-imported on the next scan")
    func doesNotReimport() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        try card.writeFile("a.jpg", contents: "a")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        clock.advance(by: 2)
        let second = await watcher.scanOnce()
        #expect(second.isEmpty)
        #expect(await session.current.shots.count == 1)
    }

    @Test("An unmounted volume is reported, and a remount resumes without duplicating")
    func survivesUnmountAndRemount() async throws {
        let mountParent = TempDirectory("volumes")
        defer { mountParent.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        // Stand in for a card reader mount point: a directory that appears and
        // disappears underneath the watcher.
        let mountPoint = mountParent.url.appendingPathComponent("NO NAME", isDirectory: true)
        let card = TempDirectory("card-contents")
        defer { card.remove() }

        func mount() throws {
            try? FileManager.default.removeItem(at: mountPoint)
            try FileManager.default.copyItem(at: card.url, to: mountPoint)
        }
        func unmount() throws {
            try FileManager.default.removeItem(at: mountPoint)
        }

        try card.writeFile("DSC00001.ARW", contents: "one")
        try mount()

        let watcher = makeWatcher(folder: mountPoint, session: session, clock: clock)
        let events = await watcher.events()

        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        // Card pulled mid-session.
        try unmount()
        clock.advance(by: 2)
        let whileGone = await watcher.scanOnce()
        #expect(whileGone.isEmpty)

        // Card back in, now with one more frame on it.
        try card.writeFile("DSC00002.ARW", contents: "two")
        try mount()
        clock.advance(by: 2)
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let afterRemount = await watcher.scanOnce()

        // The frame that was already imported is not imported again — the
        // handled set survives the unmount — and the new one arrives.
        #expect(afterRemount.importedCount == 1)
        let names = await session.current.shots.map(\.originalFileName)
        #expect(names == ["DSC00001.ARW", "DSC00002.ARW"])

        await watcher.stop()

        var sawUnavailable = false
        var sawAvailable = false
        for await event in events {
            switch event {
            case .becameUnavailable: sawUnavailable = true
            case .becameAvailable: sawAvailable = true
            default: break
            }
        }
        #expect(sawUnavailable)
        #expect(sawAvailable)
    }

    /// The failure this guards against: a card reader gives the *next* card the
    /// same mount point when both volumes carry the same generic label
    /// (`/Volumes/NO NAME`), and a camera whose file counter was reset writes
    /// `DSC00001.ARW` again. Keyed by path alone, every one of card B's
    /// colliding frames was dropped before the stat — no import, and no report
    /// line saying anything happened.
    @Test("A different card at the same mount point with the same file names still imports")
    func differentCardReusingTheMountPoint() async throws {
        let mountParent = TempDirectory("volumes")
        defer { mountParent.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        let mountPoint = mountParent.url.appendingPathComponent("NO NAME", isDirectory: true)
        let watcher = makeWatcher(folder: mountPoint, session: session, clock: clock)

        // Card A.
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Data(repeating: 0xA1, count: 2048).write(
            to: mountPoint.appendingPathComponent("DSC00001.ARW"))
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        // Card A ejected.
        try FileManager.default.removeItem(at: mountPoint)
        _ = await watcher.scanOnce()

        // Card B, same volume label so the same mount path, same file name
        // after a counter reset — but a different photograph.
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Data(repeating: 0xB2, count: 5000).write(
            to: mountPoint.appendingPathComponent("DSC00001.ARW"))
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let afterSwap = await watcher.scanOnce()

        #expect(afterSwap.importedCount == 1)
        let shots = await session.current.shots
        #expect(shots.count == 2)

        // Both frames are in `originals/`, with their own bytes.
        let sizes = try shots.map {
            try Data(contentsOf: testProject.store.originalURL(for: $0)).count
        }
        #expect(sizes.sorted() == [2048, 5000])
    }

    /// The other half of the same rule: re-inserting the *same* card must not
    /// import the same frame twice, and must not be silent about it either.
    @Test("The same card re-inserted at the same path is not imported twice")
    func sameCardReinsertedIsNotDuplicated() async throws {
        let mountParent = TempDirectory("volumes")
        defer { mountParent.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        let mountPoint = mountParent.url.appendingPathComponent("NO NAME", isDirectory: true)
        let watcher = makeWatcher(folder: mountPoint, session: session, clock: clock)

        let frame = Data(repeating: 0xC3, count: 3333)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try frame.write(to: mountPoint.appendingPathComponent("DSC00001.ARW"))
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        try FileManager.default.removeItem(at: mountPoint)
        _ = await watcher.scanOnce()

        // Same bytes back at the same path. Whether or not the mtime survived
        // the round trip, at worst this reaches `ShotIngestor` and its content
        // hash refuses it.
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try frame.write(to: mountPoint.appendingPathComponent("DSC00001.ARW"))
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let afterRemount = await watcher.scanOnce()

        #expect(afterRemount.importedCount == 0)
        #expect(afterRemount.failedCount == 0)
        #expect(await session.current.shots.count == 1)
    }

    @Test("A half-written file interrupted by an unmount is re-observed from scratch")
    func unmountResetsStabilityObservations() async throws {
        let mountParent = TempDirectory("volumes")
        defer { mountParent.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        let mountPoint = mountParent.url.appendingPathComponent("NO NAME", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mounted = TempDirectory("unused")
        defer { mounted.remove() }

        let watcher = makeWatcher(folder: mountPoint, session: session, clock: clock)

        try Data(repeating: 1, count: 512).write(
            to: mountPoint.appendingPathComponent("DSC00001.ARW"))
        _ = await watcher.scanOnce()  // first sighting recorded

        // Volume disappears while the observation is pending.
        try FileManager.default.removeItem(at: mountPoint)
        _ = await watcher.scanOnce()

        // Back, with the same name but different (complete) content.
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(
            to: mountPoint.appendingPathComponent("DSC00001.ARW"))

        // The stale observation must not make this import instantly: the
        // interval has to be served again after the remount.
        clock.advance(by: 5)
        #expect(await watcher.scanOnce().importedCount == 0)
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        let shot = try #require(await session.current.shots.first)
        let bytes = try Data(contentsOf: testProject.store.originalURL(for: shot))
        #expect(bytes.count == 4096)
    }

    @Test("Non-image files in the watched folder are ignored entirely")
    func ignoresNonImages() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        try card.writeFile("DSC00001.ARW", contents: "raw")
        try card.writeFile("DSC00001.MP4", contents: "movie")
        try card.writeFile("index.bdm", contents: "junk")

        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let report = await watcher.scanOnce()
        #expect(report.importedCount == 1)
        #expect(report.items.count == 1)
    }

    @Test("A project bundle inside the watched folder is never imported into itself")
    func neverImportsItsOwnBundle() async throws {
        // The user watches a folder and keeps the .rpproj in it. Without the
        // guard, every file the watcher copies into originals/ would look like
        // a new file in the watched tree and be copied again, forever.
        let workspace = TempDirectory("workspace")
        defer { workspace.remove() }
        let created = try ProjectStore.create(name: "Shoot", in: workspace.url)
        let session = ProjectSession(store: created.store, project: created.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: workspace.url, session: session, clock: clock)

        try workspace.writeFile("DSC00001.ARW", contents: "raw")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        // Several more rounds; the copy now sitting in originals/ must not come
        // back round as a new file.
        for _ in 0..<3 {
            clock.advance(by: 2)
            #expect(await watcher.scanOnce().importedCount == 0)
        }
        #expect(await session.current.shots.count == 1)
    }

    @Test("Duplicate content arriving under a new name is skipped, not imported twice")
    func deduplicatesAcrossNames() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()
        let watcher = makeWatcher(folder: card.url, session: session, clock: clock)

        try card.writeFile("DSC00001.ARW", contents: "same bytes")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().importedCount == 1)

        try card.writeFile("DSC00001 copy.ARW", contents: "same bytes")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let report = await watcher.scanOnce()
        #expect(report.importedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(await session.current.shots.count == 1)
    }

    /// A file that vanishes between the watcher's stat and the ingestor's
    /// re-check is a race, not a defect. Blacklisting it means the frame is
    /// never imported however long the card stays plugged in.
    @Test("A transient sourceUnavailable failure is retried, not blacklisted")
    func transientFailureStaysEligible() async throws {
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)
        let clock = TestClock()

        let ghost = card.url.appendingPathComponent("DSC09999.ARW")
        let watcher = makeWatcher(
            folder: card.url, session: session, clock: clock,
            fileManager: GhostFileManager(ghost: ghost))

        _ = await watcher.scanOnce()  // first sighting of a file that is not there
        clock.advance(by: 2)
        let first = await watcher.scanOnce()
        #expect(first.failedCount == 1)
        #expect(first.failures.first?.outcome.failure == .sourceUnavailable(ghost.path))
        #expect(!(await watcher.handledPaths.contains(ghost.path)))

        // Still eligible: a later scan tries again rather than staying silent.
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        #expect(await watcher.scanOnce().failedCount == 1)

        // The copy that was in flight lands for real, and the ghost stops
        // haunting the moment a real file is at that path.
        try card.writeFile("DSC09999.ARW", contents: "the frame, finally complete")
        _ = await watcher.scanOnce()
        clock.advance(by: 2)
        let imported = await watcher.scanOnce()
        #expect(imported.importedCount == 1)
        #expect(await session.current.shots.map(\.originalFileName) == ["DSC09999.ARW"])
    }

    /// The classification behind the test above, stated directly: which
    /// outcomes are allowed to end a file's life in the watcher.
    @Test("Only unambiguously final outcomes are remembered as handled")
    func finalOutcomeClassification() {
        let shotID = ShotID("s-1")!
        #expect(
            FolderWatcher.isFinal(.imported(shotID: shotID, originalRelativePath: "originals/x")))
        #expect(FolderWatcher.isFinal(.skipped(.unsupportedFileType(pathExtension: "txt"))))
        #expect(FolderWatcher.isFinal(.skipped(.duplicateContent(existingShotID: shotID))))
        #expect(FolderWatcher.isFinal(.failed(.unreadable("corrupt"))))
        #expect(FolderWatcher.isFinal(.failed(.copyFailed("disk full"))))

        #expect(!FolderWatcher.isFinal(.failed(.sourceUnavailable("/Volumes/NO NAME/DSC1.ARW"))))
        #expect(!FolderWatcher.isFinal(.failed(.timedOut("slow card"))))
        #expect(!FolderWatcher.isFinal(.skipped(.stillBeingWritten(observedBytes: 10))))
    }

    @Test("start() and stop() run the real timer loop and import a new file")
    func liveLoopImportsWithoutManualScans() async throws {
        // The only test here that uses wall-clock time: it exists to prove the
        // loop, the kqueue arming and the stop path actually run, which the
        // deterministic tests above deliberately bypass.
        let card = TempDirectory("card")
        defer { card.remove() }
        let testProject = try TestProject()
        defer { testProject.remove() }
        let session = ProjectSession(store: testProject.store, project: testProject.project)

        let watcher = FolderWatcher(
            configuration: FolderWatcher.Configuration(
                url: card.url,
                stabilityInterval: 0.1,
                pollInterval: 0.1,
                importsPreexistingFiles: true
            ),
            host: session,
            options: ImportOptions(usesSecurityScopedAccess: false),
            metadataExtractor: NullMetadataExtractor()
        )
        await watcher.start()
        try card.writeFile("live.jpg", contents: "arrived while watching")

        var imported = 0
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            imported = await session.current.shots.count
            if imported > 0 { break }
        }
        await watcher.stop()
        #expect(imported == 1)
    }
}
