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
    @Test("The panel covers exactly EditState.SectionKey.all, in that order")
    func coversEverySection() {
        #expect(SliderPanelLayout.sections.map(\.key) == EditState.SectionKey.all)
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

    @Test("Lookup by key works for every declared namespace")
    func lookup() {
        for key in EditState.SectionKey.all {
            #expect(SliderPanelLayout.section(forKey: key)?.key == key)
        }
        #expect(SliderPanelLayout.section(forKey: "nope") == nil)
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
                let expected = RPCore.Slider.range(for: parameter.key, in: section.key)
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
