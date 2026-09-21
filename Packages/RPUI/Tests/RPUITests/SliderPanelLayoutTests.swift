import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

@Suite("Slider panel structure")
struct SliderPanelLayoutTests {
    /// The panel must cover every namespace RPCore declares. If Phase 2 adds a
    /// section key without giving it a home in the UI, this fails rather than
    /// the section silently never appearing.
    ///
    /// Asserted on ``SliderPanelLayout/storageKeys`` rather than on the panels'
    /// own keys since the 2026-09-18 Mắt / Răng split: the invariant that matters
    /// is *"every namespace has a panel, in RPCore's order"*, not *"exactly one
    /// panel per namespace"* — a UI grouping and a storage namespace are
    /// different things, and `eyesTeeth` now has two panels over it.
    @Test("The panels cover exactly EditState.SectionKey.all, in that order")
    func coversEverySection() {
        #expect(SliderPanelLayout.storageKeys == EditState.SectionKey.all)
        for section in SliderPanelLayout.sections {
            #expect(EditState.SectionKey.all.contains(section.storageKey), "\(section.key)")
        }
    }

    /// The split itself (2026-09-18): tapping "Răng" must open **one** slider.
    /// The bug this replaces was a single four-slider panel shared by both rail
    /// items, so the three eye sliders appeared under "Răng".
    @Test("Mắt and Răng are two panels, 3 sliders and 1, over the one namespace")
    func eyesAndTeethAreSeparatePanels() throws {
        let eyes = try #require(SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.eyes))
        let teeth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.teeth))

        #expect(eyes.title == "Mắt")
        #expect(teeth.title == "Răng")
        #expect(eyes.parameters.map(\.label) == ["Sáng mắt", "Trắng lòng trắng", "Nét mắt"])
        #expect(teeth.parameters.map(\.label) == ["Trắng răng"])
        #expect(teeth.parameters.map(\.key) == [EyesTeethSliders.Key.teethWhiten])

        // Different icons: sharing `eye` is what let the rail say "Răng" and
        // show the eye panel. SF Symbols has no tooth glyph on macOS 15 / iOS 18.
        #expect(eyes.systemImage == "eye")
        #expect(teeth.systemImage != eyes.systemImage)
        #expect(teeth.systemImage == "mouth")

        // UI-only: the storage namespace, and therefore every saved document and
        // preset, is untouched.
        #expect(eyes.storageKey == EditState.SectionKey.eyesTeeth)
        #expect(teeth.storageKey == EditState.SectionKey.eyesTeeth)
        #expect(SliderPanelLayout.sections(forStorageKey: EditState.SectionKey.eyesTeeth)
            .map(\.key) == [SliderPanelLayout.PanelKey.eyes, SliderPanelLayout.PanelKey.teeth])
        // …and the namespace is not itself a panel key any more, so a caller
        // that means "the eyesTeeth panel" fails loudly instead of guessing.
        #expect(SliderPanelLayout.section(forKey: EditState.SectionKey.eyesTeeth) == nil)
    }

    /// The second split of the same day, for the second instance of the same
    /// bug: "Mịn da" and "Kiềm dầu" were two `sparkles` rail entries opening one
    /// unfiltered eight-slider panel, so "Kiềm dầu" answered a question about
    /// oil with seven controls that are not about oil.
    @Test("Mịn da and Kiềm dầu are two panels, 7 sliders and 1, over the one namespace")
    func skinIsTwoPanels() throws {
        let smooth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.smooth))
        let shine = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.shine))

        #expect(smooth.title == "Mịn da")
        #expect(shine.title == "Kiềm dầu")
        #expect(smooth.parameters.count == 7)
        #expect(!smooth.parameters.contains { $0.key == SkinSliders.Key.shine })
        #expect(shine.parameters.map(\.label) == ["Khử bóng dầu"])
        #expect(shine.parameters.map(\.key) == [SkinSliders.Key.shine])

        // Different icons: sharing `sparkles` is half of what the user reported.
        #expect(smooth.systemImage == "sparkles")
        #expect(shine.systemImage != smooth.systemImage)
        #expect(shine.systemImage == "humidity")

        // UI-only: the storage namespace, and therefore every saved document and
        // preset, is untouched.
        #expect(smooth.storageKey == EditState.SectionKey.skin)
        #expect(shine.storageKey == EditState.SectionKey.skin)
        #expect(SliderPanelLayout.sections(forStorageKey: EditState.SectionKey.skin)
            .map(\.key) == [SliderPanelLayout.PanelKey.smooth, SliderPanelLayout.PanelKey.shine])
        #expect(SliderPanelLayout.section(forKey: EditState.SectionKey.skin) == nil)

        // Each panel counts only its own sliders, so "Đặt lại" on Kiềm dầu
        // cannot clear the seven it does not show.
        var state = EditState()
        state.setSlider(SkinSliders.Key.shine, in: EditState.SectionKey.skin, to: 55)
        #expect(shine.activeParameterCount(in: state) == 1)
        #expect(smooth.activeParameterCount(in: state) == 0)
        #expect(smooth.isNeutral(in: state))
        #expect(SliderPanelLayout.sections(touchedBy: state.sections).map(\.title) == ["Kiềm dầu"])
    }

    /// The two panels together are still exactly the engine's key list, in the
    /// engine's order — a ninth `SkinSliders` key would land in "Mịn da"
    /// (everything that is not `shine`) rather than fall out of the UI.
    @Test("The Mịn da and Kiềm dầu panels partition SkinSliders.Key.all")
    func theSkinPanelsCoverTheEngineList() throws {
        let smooth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.smooth))
        let shine = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.shine))
        // Interleaved, not concatenated: `shine` sits in the middle of the
        // engine's order, so the two panels' keys are checked as a set plus the
        // count rather than as a join.
        #expect(Set(smooth.parameters.map(\.key) + shine.parameters.map(\.key))
            == Set(SkinSliders.Key.all))
        #expect(smooth.parameters.count + shine.parameters.count == SkinSliders.Key.all.count)
        #expect(
            smooth.parameters.map(\.key)
                == SkinSliders.Key.all.filter { $0 != SkinSliders.Key.shine })
    }

    /// The two panels together are still exactly the engine's key list, in the
    /// engine's order — a fifth `EyesTeethSliders` key would land in "Mắt"
    /// (everything that is not `teethWhiten`) rather than fall out of the UI.
    @Test("The eyes and teeth panels partition EyesTeethSliders.Key.all")
    func theEyesAndTeethPanelsCoverTheEngineList() throws {
        let eyes = try #require(SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.eyes))
        let teeth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.teeth))
        #expect(
            eyes.parameters.map(\.key) + teeth.parameters.map(\.key)
                == EyesTeethSliders.Key.all)
    }

    /// Each panel counts and resets **its own** sliders. Before the split
    /// "Đặt lại" cleared the whole namespace, which from the Răng panel would now
    /// silently wipe three eye sliders the user never touched there.
    @Test("A panel's active count and neutrality ignore the other panel's sliders")
    func perPanelCounting() throws {
        let eyes = try #require(SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.eyes))
        let teeth = try #require(
            SliderPanelLayout.section(forKey: SliderPanelLayout.PanelKey.teeth))

        var state = EditState()
        #expect(eyes.isNeutral(in: state))
        #expect(teeth.isNeutral(in: state))

        state.setSlider(
            EyesTeethSliders.Key.teethWhiten, in: EditState.SectionKey.eyesTeeth, to: 60)
        #expect(teeth.activeParameterCount(in: state) == 1)
        #expect(eyes.activeParameterCount(in: state) == 0)
        #expect(!teeth.isNeutral(in: state))
        #expect(eyes.isNeutral(in: state))

        state.setSlider(
            EyesTeethSliders.Key.eyeBrighten, in: EditState.SectionKey.eyesTeeth, to: 40)
        #expect(eyes.activeParameterCount(in: state) == 1)
        #expect(teeth.activeParameterCount(in: state) == 1)

        // The preset/edit summary names the panels the document actually moved.
        #expect(
            SliderPanelLayout.sections(touchedBy: state.sections).map(\.title) == ["Mắt", "Răng"])
        var teethOnly = EditState()
        teethOnly.setSlider(
            EyesTeethSliders.Key.teethWhiten, in: EditState.SectionKey.eyesTeeth, to: 60)
        #expect(SliderPanelLayout.sections(touchedBy: teethOnly.sections).map(\.title) == ["Răng"])
    }

    @Test("Every group has a title, an icon, a phase and planned parameters")
    func descriptorsAreComplete() {
        for section in SliderPanelLayout.sections {
            #expect(!section.title.isEmpty)
            #expect(!section.systemImage.isEmpty)
            #expect(section.phase.hasPrefix("Phase "))
            #expect(!section.plannedParameters.isEmpty)
        }
        #expect(SliderPanelLayout.plannedParameterCount > 40)
    }

    @Test("Lookup by key works for every panel, and every namespace has one")
    func lookup() {
        for section in SliderPanelLayout.sections {
            #expect(SliderPanelLayout.section(forKey: section.key)?.key == section.key)
        }
        for key in EditState.SectionKey.all {
            #expect(!SliderPanelLayout.sections(forStorageKey: key).isEmpty, "\(key)")
        }
        #expect(SliderPanelLayout.section(forKey: "nope") == nil)
        #expect(SliderPanelLayout.sections(forStorageKey: "nope").isEmpty)
    }

    /// Phase 1 ships no working sliders on purpose ("panel slider trống").
    @Test("The panel writes nothing: the placeholder value is the documented default 0")
    func placeholderUsesTheDocumentedDefault() {
        #expect(RPCore.Slider.defaultValue == 0)
        #expect(RPCore.Slider.range == 0...100)
    }

    /// docs/ADR-0016. The panel does not decide the range — it reads it from
    /// `RPCore.Slider` — so this checks the reading, and that only the "Màu"
    /// group got the wider one.
    @Test("Only the Màu group's sliders span −100…100")
    func onlyTheColorGroupIsBidirectional() throws {
        var bidirectional = 0
        for section in SliderPanelLayout.sections {
            for parameter in section.parameters {
                let expected = RPCore.Slider.range(for: parameter.key, in: section.storageKey)
                #expect(parameter.range == expected, "\(section.key).\(parameter.key)")
                if parameter.isBidirectional {
                    bidirectional += 1
                    #expect(section.key == EditState.SectionKey.color, "\(parameter.key)")
                    #expect(parameter.range == -100...100)
                } else {
                    #expect(parameter.range == 0...100, "\(section.key).\(parameter.key)")
                }
            }
        }
        // 18 Color sliders, of which curves and autoDodgeBurn stayed 0…100.
        #expect(bidirectional == 16)

        let color = try #require(SliderPanelLayout.section(forKey: EditState.SectionKey.color))
        let oneDirectional = color.parameters.filter { !$0.isBidirectional }.map(\.key)
        #expect(oneDirectional == [ColorSliders.Key.curves, ColorSliders.Key.autoDodgeBurn])
    }

    /// The neutral value has to sit where the fill starts, or the track lies
    /// about which way the picture moved.
    @Test("The track's neutral position is the left edge, or the centre when signed")
    func trackGeometryFollowsTheRange() {
        #expect(RPSliderTrack.fraction(of: 0, in: 0...100) == 0)
        #expect(RPSliderTrack.fraction(of: 50, in: 0...100) == 0.5)
        #expect(RPSliderTrack.fraction(of: 100, in: 0...100) == 1)
        #expect(RPSliderTrack.fraction(of: 0, in: -100...100) == 0.5)
        #expect(RPSliderTrack.fraction(of: -100, in: -100...100) == 0)
        #expect(RPSliderTrack.fraction(of: 100, in: -100...100) == 1)
        // Out of range values are pinned to the ends rather than drawn outside.
        #expect(RPSliderTrack.fraction(of: -500, in: 0...100) == 0)
        #expect(RPSliderTrack.fraction(of: 500, in: -100...100) == 1)

        // …and the inverse, which is what a tap or a drag writes.
        #expect(RPSliderTrack.value(atFraction: 0.5, in: 0...100) == 50)
        #expect(RPSliderTrack.value(atFraction: 0.5, in: -100...100) == 0)
        #expect(RPSliderTrack.value(atFraction: 0.25, in: -100...100) == -50)
        #expect(RPSliderTrack.value(atFraction: 1, in: -100...100) == 100)
        #expect(RPSliderTrack.value(atFraction: -2, in: -100...100) == -100)
    }

    /// A bidirectional row has to name both ends; a one-directional one still
    /// names the only end it has.
    @Test("Every Màu slider's direction line names the ends it actually has")
    func colorDirectionsNameBothEnds() throws {
        let color = try #require(SliderPanelLayout.section(forKey: EditState.SectionKey.color))
        for parameter in color.parameters {
            #expect(!parameter.direction.isEmpty, "\(parameter.key)")
            if parameter.isBidirectional {
                #expect(parameter.direction.contains("−"), "\(parameter.key) has no negative half")
                #expect(parameter.direction.contains("+"), "\(parameter.key) has no positive half")
            } else {
                #expect(parameter.direction.contains("một chiều"), "\(parameter.key)")
            }
        }
    }
}

@Suite("Preview image cache")
struct PreviewImageCacheTests {
    @Test("The same request decodes once and is served from memory afterwards")
    func cachesByRequest() async throws {
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-cache-\(UUID().uuidString).png"),
            size: 48)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = PreviewImageCache()
        let request = PreviewRequest(originalURL: url, maxPixelSize: 32)
        let first = try await cache.image(for: request)
        #expect(await cache.cachedImage(for: request) != nil)
        let second = try await cache.image(for: request)
        #expect(first == second)
    }

    /// While the renderer ignores `EditState`, the "before" and "after"
    /// requests are the same request — the cache says so instead of decoding
    /// the same file twice and pretending they differ.
    @Test("With a passthrough renderer, edited and original share one cache entry")
    func passthroughCollapsesBeforeAndAfter() async throws {
        let url = try TempProject.writePNG(
            at: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rpui-cache-\(UUID().uuidString).png"),
            size: 48)
        defer { try? FileManager.default.removeItem(at: url) }

        var edited = EditState()
        edited.setSlider("smooth", in: EditState.SectionKey.skin, to: 80)
        let request = PreviewRequest(originalURL: url, editState: edited, maxPixelSize: 32)

        let cache = PreviewImageCache()
        let after = try await cache.image(for: request)
        #expect(await cache.cachedImage(for: request.original) != nil)
        let before = try await cache.image(for: request.original)
        #expect(before == after)
    }

    @Test("The cache is bounded")
    func eviction() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpui-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = PreviewImageCache(capacity: 2)
        var requests: [PreviewRequest] = []
        for index in 0..<3 {
            let url = try TempProject.writePNG(
                at: directory.appendingPathComponent("\(index).png"), size: 16)
            let request = PreviewRequest(originalURL: url, maxPixelSize: 16)
            requests.append(request)
            _ = try await cache.image(for: request)
        }
        #expect(await cache.cachedImage(for: requests[0]) == nil)
        #expect(await cache.cachedImage(for: requests[2]) != nil)
    }
}
