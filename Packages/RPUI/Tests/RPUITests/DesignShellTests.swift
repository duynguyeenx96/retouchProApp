import CoreGraphics
import Foundation
import SwiftUI
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// The rebuilt shell (docs/design/SPEC.md, screens 1a/1b/2a/2b/2c/2d).
///
/// What is checkable without a window: the taxonomy the six group tabs draw,
/// the rules the mockup states in words ("locked groups must not switch",
/// "Đồng bộ maps onto the face selection"), the library's filtering, and the
/// EXIF strings the info panel shows. Pixel layout is not tested here — it is
/// looked at on a device, which is what step 6 of the workflow is for.
@MainActor
@Suite("Design shell")
struct DesignShellTests {

    // MARK: - Group taxonomy

    /// The six tab labels are the mockup's, in the mockup's order. The *keys*
    /// are RPCore's and are checked in `SliderPanelLayoutTests`; this is the
    /// half a reviewer reads off the screen.
    @Test("The six group tabs carry the design's Vietnamese labels, in order")
    func groupTabs() {
        #expect(
            SliderPanelLayout.sections.map(\.title) == [
                "Da", "Mặt", "Mắt & Răng", "Màu", "Trang điểm", "Tóc",
            ])
    }

    @Test("Only the two Phase 5 groups are locked, and they still list their names")
    func lockedGroups() {
        let locked = SliderPanelLayout.sections.filter(\.isLocked).map(\.key)
        #expect(locked == [EditState.SectionKey.makeup, EditState.SectionKey.hair])
        for section in SliderPanelLayout.sections where section.isLocked {
            #expect(section.sectionCaption == "Phase 5 · chưa khả dụng")
            #expect(!section.plannedParameters.isEmpty)
        }
    }

    @Test("Every group has a panel title and a section caption for the Mac panel header")
    func panelHeaders() {
        for section in SliderPanelLayout.sections {
            #expect(!section.panelTitle.isEmpty, "\(section.key)")
            #expect(!section.sectionCaption.isEmpty, "\(section.key)")
        }
        #expect(
            SliderPanelLayout.section(forKey: EditState.SectionKey.skin)?.panelTitle
                == "Làm mịn da")
        #expect(
            SliderPanelLayout.section(forKey: EditState.SectionKey.face)?.sectionCaption
                == "Hình học · 478 điểm")
    }

    /// Spot-check that the labels are the design's and are attached to the
    /// engine's keys — the nose is the one the mockup lists in a different
    /// order from RPEngine, so it is the one worth pinning.
    @Test("Design labels sit on the engine's keys, including the reordered nose")
    func labelsOnKeys() throws {
        let face = try #require(SliderPanelLayout.section(forKey: EditState.SectionKey.face))
        let byKey = Dictionary(uniqueKeysWithValues: face.parameters.map { ($0.key, $0.label) })
        #expect(byKey[FaceSliders.Key.noseShrink] == "Cánh mũi")
        #expect(byKey[FaceSliders.Key.noseBridge] == "Sống mũi")
        #expect(byKey[FaceSliders.Key.noseTip] == "Đầu mũi")

        let color = try #require(SliderPanelLayout.section(forKey: EditState.SectionKey.color))
        #expect(color.parameters.first?.label == "Phơi sáng")
        #expect(color.parameters.contains { $0.label == "HSL · Đỏ" })
        #expect(color.parameters.contains { $0.label == "Dodge & Burn tự động" })
    }

    // MARK: - Chrome

    @Test("Tapping a locked group does nothing; tapping a working one switches")
    func selectingGroups() {
        let chrome = EditorChrome()
        #expect(chrome.activeGroupKey == EditState.SectionKey.skin)
        chrome.selectGroup(EditState.SectionKey.color)
        #expect(chrome.activeGroupKey == EditState.SectionKey.color)
        chrome.selectGroup(EditState.SectionKey.makeup)
        #expect(chrome.activeGroupKey == EditState.SectionKey.color)
        chrome.selectGroup("nope")
        #expect(chrome.activeGroupKey == EditState.SectionKey.color)
    }

    @Test("The subject pill cycles Nữ → Nam → Trẻ em → Tất cả → Nữ")
    func subjectCycle() {
        let chrome = EditorChrome()
        #expect(chrome.subject == .female)
        let titles = (0..<4).map { _ -> String in
            defer { chrome.cycleSubject() }
            return chrome.subject.title
        }
        #expect(titles == ["Nữ", "Nam", "Trẻ em", "Tất cả"])
        #expect(chrome.subject == .female)
    }

    @Test("Export options default to the mockup's first pill in every row")
    func exportDefaults() {
        let options = ExportOptions()
        #expect(options.format == .jpeg)
        #expect(options.quality == .low)  // "80"
        #expect(options.size == .original)
        #expect(options.colorSpace == .sRGB)
        #expect(options.destinationDisplayPath == "~/Pictures/RetouchPro")
    }

    @Test("Export progress is a fraction that cannot divide by zero")
    func exportProgress() {
        #expect(ExportProgress(currentFileName: "a", completed: 2, total: 3).fraction > 0.66)
        #expect(ExportProgress(currentFileName: "a", completed: 1, total: 0).fraction == 0)
    }

    // MARK: - "Đồng bộ"

    /// The mockup's sync toggle is not new state: it is the presence of
    /// `perImage["selectedFace"]`. Turning it off pins the sliders to one face,
    /// turning it on gives them all of them.
    @Test("Đồng bộ is the face selection, not a new EditState field")
    func syncIsTheFaceSelection() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)

        // With no detected faces the toggle is inert and reads "on" — which is
        // what "apply to every face" means when there are none.
        #expect(model.isSyncingAllFaces)
        model.setSyncingAllFaces(false)
        #expect(model.isSyncingAllFaces)
        #expect(model.activeEditState.perImage.isEmpty)

        // Selecting a face is the same act as switching sync off.
        model.selectFace(1)
        #expect(model.activeEditState.perImage[FaceSelection.key] != nil)
        model.setSyncingAllFaces(true)
        #expect(model.activeEditState.perImage.isEmpty)
    }

    // MARK: - Library filtering

    @Test("The filter pills and the sidebar chips select real subsets")
    func filtering() throws {
        let jpeg = Shot(originalFileName: "A001.JPG", originalRelativePath: "originals/A001.JPG")
        var raw = Shot(originalFileName: "A002.ARW", originalRelativePath: "originals/A002.ARW")
        raw.rating = 4
        let heic = Shot(originalFileName: "B003.HEIC", originalRelativePath: "originals/B003.HEIC")
        let shots = [jpeg, raw, heic]
        let edited: (Shot) -> Bool = { $0.id == heic.id }

        #expect(
            LibraryFiltering.apply(shots, filter: .all, search: "", edited: edited).count == 3)
        #expect(
            LibraryFiltering.apply(shots, filter: .raw, search: "", edited: edited)
                .map(\.originalFileName) == ["A002.ARW"])
        #expect(
            LibraryFiltering.apply(shots, filter: .edited, search: "", edited: edited)
                .map(\.originalFileName) == ["B003.HEIC"])
        #expect(
            LibraryFiltering.apply(
                shots, filter: .all, search: "", threeStarsAndUp: true, edited: edited
            ).map(\.originalFileName) == ["A002.ARW"])
        #expect(
            LibraryFiltering.apply(shots, filter: .all, search: "a0", edited: edited).count == 2)
    }

    /// The sidebar rows of 2c are predicates over the real project, not four
    /// hard-coded numbers. `imported` and `all` coincide until Phase 4 adds a
    /// second way photos get in — that is a fact about the app, and stated.
    @Test("The macOS sidebar sources count real shots")
    func librarySources() throws {
        var project = Project(name: "Shoot")
        let today = Date()
        var recent = Shot(originalFileName: "A.JPG", originalRelativePath: "originals/A.JPG")
        recent.importedAt = today
        var older = Shot(originalFileName: "B.JPG", originalRelativePath: "originals/B.JPG")
        older.importedAt = today.addingTimeInterval(-60 * 60 * 24 * 3)
        project.shots = [recent, older]
        let edited: (Shot) -> Bool = { $0.id == older.id }

        #expect(LibrarySource.shoot.shots(in: project, edited: edited).map(\.id) == [recent.id])
        #expect(LibrarySource.imported.shots(in: project, edited: edited).count == 2)
        #expect(LibrarySource.all.shots(in: project, edited: edited).count == 2)
        #expect(LibrarySource.drafts.shots(in: project, edited: edited).map(\.id) == [older.id])
        #expect(LibrarySource.shoot.title(project: project).hasPrefix("Buổi chụp · "))
        #expect(LibrarySource.drafts.title(project: project) == "Nháp chưa xuất")
    }

    @Test("The 'đã chỉnh' index is read from disk and follows a commit")
    func editedIndex() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        await model.refreshEditedIndex()
        #expect(model.editedShotIDs.isEmpty)

        model.setSlider(ColorSliders.Key.exposure, in: EditState.SectionKey.color, to: 40)
        await model.commitEditState()
        #expect(model.editedShotIDs.contains(temp.project.shots[0].id))
        #expect(model.isEdited(temp.project.shots[0]))
        #expect(!model.isEdited(temp.project.shots[1]))

        model.resetAllSliders()
        await model.commitEditState()
        #expect(!model.isEdited(temp.project.shots[0]))
    }

    // MARK: - Thumbnail / EXIF strings

    @Test("Format tags fold the aliases and mark RAW")
    func formatTags() {
        func shot(_ name: String) -> Shot {
            Shot(originalFileName: name, originalRelativePath: "originals/\(name)")
        }
        #expect(ShotDisplay.formatTag(shot("A.ARW")) == "RAW")
        #expect(ShotDisplay.isRaw(shot("A.arw")))
        #expect(ShotDisplay.formatTag(shot("A.jpg")) == "JPEG")
        #expect(ShotDisplay.formatTag(shot("A.HEIF")) == "HEIC")
        #expect(ShotDisplay.formatTag(shot("A.png")) == "PNG")
        #expect(ShotDisplay.formatTag(shot("A")) == "—")
        // The info panel shows the file's own extension, not the RAW label.
        #expect(ShotDisplay.fileExtension(shot("A.ARW")) == "ARW")
    }

    @Test("EXIF rows format the way a camera does, and say '—' when unknown")
    func exifStrings() {
        var shot = Shot(originalFileName: "A.ARW", originalRelativePath: "originals/A.ARW")
        #expect(ShotDisplay.pixelSize(shot) == "—")
        #expect(ShotDisplay.iso(shot) == "—")
        #expect(ShotDisplay.aperture(shot) == "—")
        #expect(ShotDisplay.shutter(shot) == "—")

        shot.capture.pixelWidth = 6048
        shot.capture.pixelHeight = 4024
        shot.capture.iso = 400
        shot.capture.aperture = 1.8
        shot.capture.shutterSpeedSeconds = 1.0 / 200
        #expect(ShotDisplay.pixelSize(shot) == "6048×4024")
        #expect(ShotDisplay.iso(shot) == "400")
        #expect(ShotDisplay.aperture(shot) == "f/1.8")
        #expect(ShotDisplay.shutter(shot) == "1/200")

        shot.capture.shutterSpeedSeconds = 2
        #expect(ShotDisplay.shutter(shot) == "2s")
    }

    /// The face count in 2c's info panel is a real `FaceAnalyzer` output, so it
    /// is `nil` — drawn as "—" — for every shot the GPU canvas has not opened,
    /// rather than running Core ML per thumbnail.
    @Test("The info panel's face count is nil until that shot has been analysed")
    func faceCountIsPerOpenedShot() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(model.detectedFaceCount(for: temp.project.shots[0]) == nil)
    }

    // MARK: - View construction

    /// Every rebuilt screen builds. As with `ViewConstructionTests`, this
    /// catches "the view tree does not even build" and nothing about layout.
    @Test("All six design screens build for a real project")
    func screensBuild() async throws {
        let temp = try TempProject(shots: 2)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        let chrome = EditorChrome()
        let cache = PreviewImageCache()

        // 1a, 1b
        _ = PhoneEditorView(
            model: model, chrome: chrome, cache: cache, back: {}, importFromFiles: {},
            importFromPhotos: {}
        ).body
        _ = MacEditorView(
            model: model, chrome: chrome, cache: cache, back: {}, importFromFiles: {},
            importFromPhotos: {}
        ).body
        // 2a, 2c
        _ = PhoneLibraryView(
            model: model, chrome: chrome, cache: cache, back: {}, importFromFiles: {},
            importFromPhotos: {}, open: { _ in }
        ).body
        _ = MacLibraryView(
            model: model, chrome: chrome, cache: cache, back: {}, importFromFiles: {},
            importFromPhotos: {}, openInEditor: { _ in }
        ).body
        // 2b, 2d
        _ = PhoneExportSheet(chrome: chrome, shot: model.activeShot, dismiss: {}).body
        _ = MacExportDialog(
            chrome: chrome, shotCount: 3,
            progress: ExportProgress(currentFileName: "A012.ARW", completed: 2, total: 3),
            dismiss: {}
        ).body

        // …and the pieces they share, in every group including the locked ones.
        for section in SliderPanelLayout.sections {
            chrome.activeGroupKey = section.key
            _ = GroupSliderList(model: model, section: section).body
            _ = SliderPanelView(model: model, chrome: chrome).body
        }
        _ = GroupTabRow(chrome: chrome).body
        _ = GroupIconRail(chrome: chrome).body
        _ = FaceChipsView(model: model).body
        _ = EditorToolbar(
            model: model, chrome: chrome, back: {}, importFromFiles: {}, importFromPhotos: {}
        ).body
    }

    /// The router: the same `EditorView` is the phone layout under 900 pt and
    /// the three-pane one above it, on both platforms.
    @Test("The editor router builds in both tabs")
    func routerBuilds() async throws {
        let temp = try TempProject(shots: 1)
        defer { temp.cleanUp() }
        let model = try await EditorModel.open(bundleURL: temp.store.bundleURL)
        #expect(EditorLayout.forWidth(430) == .compact)
        #expect(EditorLayout.forWidth(1280) == .threePane)
        _ = EditorView(model: model, cache: PreviewImageCache(), close: {}).body
    }
}
