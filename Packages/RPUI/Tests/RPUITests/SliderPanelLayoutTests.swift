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
