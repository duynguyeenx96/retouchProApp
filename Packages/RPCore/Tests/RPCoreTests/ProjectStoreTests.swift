import Foundation
import Testing

@testable import RPCore

@Suite("ProjectStore — .rpproj bundle")
struct ProjectStoreTests {
    /// Writes a stand-in "photo" so tests never need real image data.
    @discardableResult
    private func makeSourceImage(
        _ name: String,
        in directory: URL,
        contents: String = "fake-pixels"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: Create

    @Test("Create lays out the bundle described in PLAN Phase 1")
    func createLayout() throws {
        let temp = try TemporaryDirectory("store")
        let (store, project) = try ProjectStore.create(name: "Wedding 2026", in: temp.url)

        #expect(store.bundleURL.lastPathComponent == "Wedding 2026.rpproj")
        #expect(store.bundleURL.pathExtension == ProjectBundle.pathExtension)
        #expect(
            try temp.entries(at: "Wedding 2026.rpproj")
                == ["edits", "manifest.json", "originals", "presets", "previews"])
        #expect(project.name == "Wedding 2026")
        #expect(project.shots.isEmpty)
    }

    @Test("Create refuses to overwrite an existing bundle")
    func createRefusesOverwrite() throws {
        let temp = try TemporaryDirectory("store")
        _ = try ProjectStore.create(name: "Shoot", in: temp.url)
        #expect(throws: ProjectStoreError.self) {
            _ = try ProjectStore.create(name: "Shoot", in: temp.url)
        }
    }

    @Test("A project name with a slash cannot escape the parent directory")
    func createSanitizesName() throws {
        let temp = try TemporaryDirectory("store")
        let (store, project) = try ProjectStore.create(name: "2026/09/04 Studio", in: temp.url)
        #expect(store.bundleURL.deletingLastPathComponent().path == temp.url.path)
        #expect(store.bundleURL.lastPathComponent == "2026-09-04 Studio.rpproj")
        #expect(project.name == "2026/09/04 Studio", "the displayed name is untouched")
    }

    @Test("An empty name is rejected")
    func createRejectsEmptyName() throws {
        let temp = try TemporaryDirectory("store")
        #expect(throws: ProjectStoreError.self) {
            _ = try ProjectStore.create(name: "   ", in: temp.url)
        }
    }

    // MARK: Load

    @Test("Create → add shots → reload gives back the same project")
    func roundTrip() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("DSC01234.ARW", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)

        let shot = try store.addShot(
            copyingOriginalAt: source,
            into: &project,
            capture: CaptureMetadata(
                capturedAt: Fixture.date(),
                cameraMake: "Sony",
                cameraModel: "ILCE-6300",
                iso: 400,
                pixelWidth: 6000,
                pixelHeight: 4000
            )
        )
        project.updateShot(id: shot.id) {
            $0.rating = 4
            $0.flag = .pick
        }
        project.autoApplyPresetID = PresetID.generate()
        try store.save(project)

        let reloaded = try ProjectStore(bundleURL: store.bundleURL).load()
        #expect(reloaded.report.isClean)
        #expect(reloaded.project.id == project.id)
        #expect(reloaded.project.name == "Shoot")
        #expect(reloaded.project.shots.count == 1)
        #expect(reloaded.project.autoApplyPresetID == project.autoApplyPresetID)

        let loadedShot = try #require(reloaded.project.shot(id: shot.id))
        #expect(loadedShot.originalFileName == "DSC01234.ARW")
        #expect(loadedShot.originalRelativePath == "originals/DSC01234.ARW")
        #expect(loadedShot.rating == 4)
        #expect(loadedShot.flag == .pick)
        #expect(loadedShot.capture.cameraModel == "ILCE-6300")
        #expect(loadedShot.capture.iso == 400)
        #expect(
            abs(
                (loadedShot.capture.capturedAt ?? .distantPast)
                    .timeIntervalSince(Fixture.date())) <= RPJSON.dateResolution)
    }

    @Test("Import copies the source file and does not touch it")
    func importCopies() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("DSC01234.ARW", in: temp.url, contents: "raw-bytes")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)

        let shot = try store.addShot(copyingOriginalAt: source, into: &project)

        #expect(FileManager.default.fileExists(atPath: source.path), "the card is not emptied")
        #expect(try String(contentsOf: store.originalURL(for: shot), encoding: .utf8) == "raw-bytes")
    }

    @Test("A duplicate file name is suffixed, and the camera's name is kept")
    func duplicateFileNames() throws {
        let temp = try TemporaryDirectory("store")
        let cardA = temp.url.appendingPathComponent("cardA", isDirectory: true)
        let cardB = temp.url.appendingPathComponent("cardB", isDirectory: true)
        for card in [cardA, cardB] {
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        }
        let first = try makeSourceImage("DSC01234.ARW", in: cardA, contents: "A")
        let second = try makeSourceImage("DSC01234.ARW", in: cardB, contents: "B")

        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shotA = try store.addShot(copyingOriginalAt: first, into: &project)
        let shotB = try store.addShot(copyingOriginalAt: second, into: &project)

        #expect(shotA.originalRelativePath == "originals/DSC01234.ARW")
        #expect(shotB.originalRelativePath == "originals/DSC01234-2.ARW")
        #expect(shotB.originalFileName == "DSC01234.ARW")
        #expect(try String(contentsOf: store.originalURL(for: shotA), encoding: .utf8) == "A")
        #expect(try String(contentsOf: store.originalURL(for: shotB), encoding: .utf8) == "B")
    }

    @Test("Importing a file that is not there fails cleanly")
    func importMissingSource() throws {
        let temp = try TemporaryDirectory("store")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        #expect(throws: ProjectStoreError.self) {
            _ = try store.addShot(
                copyingOriginalAt: temp.url.appendingPathComponent("nope.jpg"), into: &project)
        }
        #expect(project.shots.isEmpty)
    }

    @Test("Loading a directory that is not a project fails cleanly")
    func loadNonProject() throws {
        let temp = try TemporaryDirectory("store")
        #expect(throws: ProjectStoreError.manifestNotFound(path: temp.url.path)) {
            _ = try ProjectStore(bundleURL: temp.url).load()
        }
        let missing = temp.url.appendingPathComponent("gone.rpproj")
        #expect(throws: ProjectStoreError.bundleNotFound(path: missing.path)) {
            _ = try ProjectStore(bundleURL: missing).load()
        }
    }

    @Test("A manifest from a newer format version refuses to load rather than being rewritten")
    func rejectsNewerFormat() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let text = try String(contentsOf: store.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        try Data(text.utf8).write(to: store.manifestURL)

        #expect(
            throws: ProjectStoreError.unsupportedFormatVersion(
                found: 99, supported: ProjectManifest.currentFormatVersion)
        ) {
            _ = try store.load()
        }
    }

    @Test("Unknown manifest keys survive a load/save cycle by an older build")
    func manifestForwardCompatibility() throws {
        let temp = try TemporaryDirectory("store")
        let (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)

        var future = project
        future.additionalValues["cloudSyncToken"] = "abc123"
        var manifest = ProjectManifest(project: future)
        manifest.additionalValues["writtenBy"] = ["build": 4242]
        try store.writer.writeJSON(manifest, to: store.manifestURL)

        var loaded = try store.load().project
        #expect(loaded.additionalValues["cloudSyncToken"] == .string("abc123"))
        loaded.name = "Renamed by an older build"
        try store.save(loaded)

        let text = try String(contentsOf: store.manifestURL, encoding: .utf8)
        #expect(text.contains("cloudSyncToken"))
        #expect(try store.load().project.name == "Renamed by an older build")
    }

    // MARK: Reconciliation with disk

    @Test("A file dropped into originals/ is adopted on load, without writing to disk")
    func adoptsOrphanOriginals() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        try makeSourceImage("DSC09999.JPG", in: store.originalsURL)
        try makeSourceImage("notes.txt", in: store.originalsURL)
        try makeSourceImage(".DS_Store", in: store.originalsURL)

        let manifestBefore = try Data(contentsOf: store.manifestURL)
        let result = try store.load()

        #expect(result.report.adoptedOriginals == ["originals/DSC09999.JPG"])
        #expect(result.project.shots.map(\.originalFileName) == ["DSC09999.JPG"])
        #expect(
            try Data(contentsOf: store.manifestURL) == manifestBefore,
            "load must not write; adoption is only persisted when the caller saves")

        // Opting out leaves the project as the manifest describes it.
        let strict = try store.load(options: .init(adoptOrphanOriginals: false))
        #expect(strict.project.shots.isEmpty)
    }

    @Test("A missing original is reported but the shot and its edits are kept")
    func reportsMissingOriginals() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("DSC01234.ARW", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        var state = EditState()
        state.setSlider("smooth", in: "skin", to: 40)
        try store.saveEditState(state, for: shot.id)

        try FileManager.default.removeItem(at: store.originalURL(for: shot))

        let result = try store.load()
        #expect(result.report.missingOriginals == [shot.id])
        #expect(result.project.shots.count == 1, "edits are not thrown away because a file moved")
        #expect(try store.loadEditState(for: shot.id).slider("smooth", in: "skin") == 40)
    }

    @Test("Deleted bundle subdirectories are recreated on load")
    func repairsDirectories() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        try FileManager.default.removeItem(at: store.previewsURL)

        _ = try store.load()
        #expect(FileManager.default.fileExists(atPath: store.previewsURL.path))
    }

    // MARK: Edit states

    @Test("An untouched shot reads back a default EditState with no file on disk")
    func editStateDefaultsWhenAbsent() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("a.jpg", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)

        #expect(try store.editsRelativePathIsEmpty(for: shot))
        #expect(try store.loadEditState(for: shot.id).isDefault)
    }

    @Test("Saving an EditState writes edits/<shot id>.json and reads back identically")
    func editStateRoundTrip() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("a.jpg", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)

        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 42)
        state.perImage["crop"] = ["x": 0.1]
        try store.saveEditState(state, for: shot.id)

        #expect(try temp.entries(at: "Shoot.rpproj/edits") == ["\(shot.id.rawValue).json"])
        #expect(shot.editsRelativePath == "edits/\(shot.id.rawValue).json")
        #expect(try store.loadEditState(for: shot.id) == state)
    }

    @Test("Saving an EditState is atomic: an interrupted save keeps the previous version")
    func editStateSaveIsAtomic() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("a.jpg", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)

        var good = EditState()
        good.setSlider("smooth", in: "skin", to: 10)
        try store.saveEditState(good, for: shot.id)

        struct PowerCut: Error {}
        var crashing = store
        crashing.writer = AtomicFileWriter(beforeCommit: { _ in throw PowerCut() })
        var newer = good
        newer.setSlider("smooth", in: "skin", to: 99)
        #expect(throws: PowerCut.self) { try crashing.saveEditState(newer, for: shot.id) }

        #expect(try store.loadEditState(for: shot.id) == good)
        #expect(
            try temp.entries(at: "Shoot.rpproj/edits") == ["\(shot.id.rawValue).json"],
            "no temp file left behind")
    }

    // MARK: Add / remove

    @Test("Removing a shot keeps the original file and does not resurrect it on reload")
    func removeShotIsNonDestructive() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("DSC01234.ARW", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        try store.saveEditState(EditState(sections: ["skin": EditSection(sliders: ["smooth": 5])]),
            for: shot.id)

        try store.removeShot(id: shot.id, from: &project)

        #expect(project.shots.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: store.originalURL(for: shot).path),
            "originals/ is immutable — the RAW stays")
        #expect(try temp.entries(at: "Shoot.rpproj/edits").isEmpty)
        #expect(project.removedOriginalPaths == ["originals/DSC01234.ARW"])

        let reloaded = try store.load()
        #expect(reloaded.project.shots.isEmpty, "the tombstone prevents re-adoption")
        #expect(reloaded.report.adoptedOriginals.isEmpty)
    }

    @Test("Re-importing a removed file clears its tombstone")
    func reimportClearsTombstone() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("DSC01234.ARW", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let shot = try store.addShot(copyingOriginalAt: source, into: &project)
        try store.removeShot(id: shot.id, from: &project)

        let readded = try store.addShot(
            existingOriginalRelativePath: "originals/DSC01234.ARW", into: &project)
        #expect(project.removedOriginalPaths.isEmpty)
        #expect(readded.originalFileName == "DSC01234.ARW")
        #expect(try store.load().project.shots.count == 1)
    }

    @Test("Removing an unknown shot throws")
    func removeUnknownShot() throws {
        let temp = try TemporaryDirectory("store")
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let ghost = ShotID.generate()
        #expect(throws: ProjectStoreError.shotNotFound(ghost)) {
            try store.removeShot(id: ghost, from: &project)
        }
    }

    @Test("deleteOriginalFile refuses paths outside originals/")
    func deleteOriginalIsFenced() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        #expect(throws: ProjectStoreError.self) {
            try store.deleteOriginalFile(at: "manifest.json")
        }
        #expect(FileManager.default.fileExists(atPath: store.manifestURL.path))
    }

    @Test("Adding a shot stamps modifiedAt without touching createdAt")
    func addStampsModifiedAt() throws {
        let temp = try TemporaryDirectory("store")
        let source = try makeSourceImage("a.jpg", in: temp.url)
        var (store, project) = try ProjectStore.create(name: "Shoot", in: temp.url)
        let created = project.createdAt
        let before = project.modifiedAt

        _ = try store.addShot(copyingOriginalAt: source, into: &project)

        #expect(project.modifiedAt >= before)
        #expect(abs(project.createdAt.timeIntervalSince(created)) <= RPJSON.dateResolution)
    }

    // MARK: Presets

    @Test("Presets save, list and delete inside the bundle")
    func presetLibrary() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)

        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        state.perImage["crop"] = ["x": 0.5]

        let studio = Preset(name: "Studio", from: state)
        let outdoor = Preset(name: "Outdoor", sections: ["color": EditSection(sliders: ["exposure": 20])])
        try store.savePreset(studio)
        try store.savePreset(outdoor)

        let listed = try store.listPresets()
        #expect(listed.map(\.name) == ["Outdoor", "Studio"], "sorted by name")
        #expect(try store.loadPreset(id: studio.id).sections == studio.sections)
        #expect(
            try temp.entries(at: "Shoot.rpproj/presets")
                == ["\(outdoor.id.rawValue).json", "\(studio.id.rawValue).json"].sorted())

        try store.deletePreset(id: outdoor.id)
        #expect(try store.listPresets().map(\.name) == ["Studio"])
        #expect(throws: ProjectStoreError.presetNotFound(outdoor.id)) {
            _ = try store.loadPreset(id: outdoor.id)
        }
    }

    @Test("An unreadable preset file is skipped instead of breaking the library")
    func corruptPresetIsSkipped() throws {
        let temp = try TemporaryDirectory("store")
        let (store, _) = try ProjectStore.create(name: "Shoot", in: temp.url)
        try store.savePreset(Preset(name: "Good"))
        try Data("{ not json".utf8)
            .write(to: store.presetsURL.appendingPathComponent("broken.json"))

        #expect(try store.listPresets().map(\.name) == ["Good"])
    }

    @Test("A preset saved in one project loads and applies in another")
    func presetTransfersBetweenProjects() throws {
        let temp = try TemporaryDirectory("store")
        let (storeA, _) = try ProjectStore.create(name: "A", in: temp.url)
        let source = try makeSourceImage("b.jpg", in: temp.url)
        var (storeB, projectB) = try ProjectStore.create(name: "B", in: temp.url)
        let shotB = try storeB.addShot(copyingOriginalAt: source, into: &projectB)

        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        state.setSlider("jawWidth", in: EditState.SectionKey.face, to: 25)
        state.perImage["crop"] = ["x": 0.5]
        let preset = Preset(name: "Look", from: state)
        try storeA.savePreset(preset)

        let loaded = try storeA.loadPreset(id: preset.id)
        try storeB.savePreset(loaded)
        try storeB.saveEditState(EditState().applying(loaded), for: shotB.id)

        let applied = try storeB.loadEditState(for: shotB.id)
        #expect(applied.slider("smooth", in: EditState.SectionKey.skin) == 40)
        #expect(applied.slider("jawWidth", in: EditState.SectionKey.face) == 25)
        #expect(applied.perImage.isEmpty, "no crop from the other image came along")
    }
}

extension ProjectStore {
    /// `true` when no `edits/` document exists yet for `shot`.
    func editsRelativePathIsEmpty(for shot: Shot) throws -> Bool {
        !FileManager.default.fileExists(atPath: editsURL(for: shot.id).path)
    }
}
