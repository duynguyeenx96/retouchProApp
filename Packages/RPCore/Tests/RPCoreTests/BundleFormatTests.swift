import Foundation
import Testing

@testable import RPCore

/// Pins the exact bytes of every document a `.rpproj` bundle contains.
///
/// This is the written specification of the on-disk format: if a change alters
/// what lands on a user's disk, these tests fail and the change has to be
/// deliberate. Everything here uses fixed ids and fixed dates, so the expected
/// text is stable.
@Suite("`.rpproj` document format")
struct BundleFormatTests {
    private let projectId = ProjectID("aaaaaaaa-0000-4000-8000-000000000001")!
    private let shotId = ShotID("bbbbbbbb-0000-4000-8000-000000000002")!
    private let presetId = PresetID("cccccccc-0000-4000-8000-000000000003")!
    /// 2025-09-04T15:33:20.500Z — exact milliseconds, so encoding is loss-free.
    private let fixedDate = Fixture.date()

    private func sampleEditState() -> EditState {
        var state = EditState()
        state.setSlider("smooth", in: EditState.SectionKey.skin, to: 42.5)
        state.setSlider("jawWidth", in: EditState.SectionKey.face, to: 30)
        state.perImage["crop"] = ["x": 0.1, "y": 0.0, "w": 0.9, "h": 1.0]
        return state
    }

    @Test("manifest.json")
    func manifestFormat() throws {
        let project = Project(
            id: projectId,
            name: "Wedding 2026-09-04",
            createdAt: fixedDate,
            modifiedAt: fixedDate,
            shots: [
                Shot(
                    id: shotId,
                    originalFileName: "DSC01234.ARW",
                    originalRelativePath: "originals/DSC01234.ARW",
                    importedAt: fixedDate,
                    capture: CaptureMetadata(
                        capturedAt: fixedDate,
                        cameraMake: "Sony",
                        cameraModel: "ILCE-6300",
                        iso: 400,
                        pixelWidth: 6000,
                        pixelHeight: 4000
                    ),
                    rating: 4,
                    flag: .pick
                )
            ]
        )

        let expected = """
            {
              "formatVersion" : 1,
              "generator" : "RetouchPro/RPCore 0.2.0",
              "project" : {
                "createdAt" : "2025-09-04T15:33:20.500Z",
                "id" : "aaaaaaaa-0000-4000-8000-000000000001",
                "modifiedAt" : "2025-09-04T15:33:20.500Z",
                "name" : "Wedding 2026-09-04",
                "shots" : [
                  {
                    "capture" : {
                      "cameraMake" : "Sony",
                      "cameraModel" : "ILCE-6300",
                      "capturedAt" : "2025-09-04T15:33:20.500Z",
                      "iso" : 400,
                      "pixelHeight" : 4000,
                      "pixelWidth" : 6000
                    },
                    "flag" : "pick",
                    "id" : "bbbbbbbb-0000-4000-8000-000000000002",
                    "importedAt" : "2025-09-04T15:33:20.500Z",
                    "originalFileName" : "DSC01234.ARW",
                    "originalRelativePath" : "originals/DSC01234.ARW",
                    "rating" : 4
                  }
                ]
              }
            }
            """
        #expect(try Fixture.string(ProjectManifest(project: project)) == expected)
    }

    @Test("edits/<shot id>.json")
    func editStateFormat() throws {
        let expected = """
            {
              "perImage" : {
                "crop" : {
                  "h" : 1,
                  "w" : 0.9,
                  "x" : 0.1,
                  "y" : 0
                }
              },
              "schemaVersion" : 1,
              "sections" : {
                "face" : {
                  "jawWidth" : 30
                },
                "skin" : {
                  "smooth" : 42.5
                }
              }
            }
            """
        #expect(try Fixture.string(sampleEditState()) == expected)
    }

    @Test("presets/<preset id>.json")
    func presetFormat() throws {
        let preset = Preset(
            id: presetId,
            name: "Studio soft",
            group: "Da",
            createdAt: fixedDate,
            from: sampleEditState()
        )
        let expected = """
            {
              "createdAt" : "2025-09-04T15:33:20.500Z",
              "group" : "Da",
              "id" : "cccccccc-0000-4000-8000-000000000003",
              "name" : "Studio soft",
              "schemaVersion" : 1,
              "sections" : {
                "face" : {
                  "jawWidth" : 30
                },
                "skin" : {
                  "smooth" : 42.5
                }
              }
            }
            """
        #expect(try Fixture.string(preset) == expected)
    }

    @Test("An untouched shot's EditState is three lines")
    func defaultEditStateFormat() throws {
        let expected = """
            {
              "schemaVersion" : 1,
              "sections" : {

              }
            }
            """
        #expect(try Fixture.string(EditState()) == expected)
    }

    @Test("Bundle layout constants match what create() produces")
    func layoutConstants() throws {
        let temp = try TemporaryDirectory("format")
        let (store, _) = try ProjectStore.create(name: "L", in: temp.url)
        #expect(
            try temp.entries(at: "L.rpproj").sorted()
                == (ProjectBundle.directories + [ProjectBundle.manifestFileName]).sorted())
        #expect(store.editsURL(for: ShotID("s")!).lastPathComponent == "s.json")
        #expect(store.presetURL(for: PresetID("p")!).lastPathComponent == "p.json")
        #expect(store.previewURL(for: ShotID("s")!).lastPathComponent == "s.jpg")
    }

    @Test("Numbers compare by value across .int and .double")
    func numericEqualityIsUnified() {
        // JSON has one number type: 40 written as a Double reads back as an Int.
        // Documents must not look modified because of that.
        #expect(JSONValue.int(40) == JSONValue.double(40))
        #expect(JSONValue.int(40).hashValue == JSONValue.double(40).hashValue)
        #expect(JSONValue.int(40) != JSONValue.double(40.5))
        #expect(JSONValue.number(40) == .int(40))
        #expect(JSONValue.number(42.5) == .double(42.5))
        #expect(JSONValue.int(1) != JSONValue.bool(true))
    }
}
