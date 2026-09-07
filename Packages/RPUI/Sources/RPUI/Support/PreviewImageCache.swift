import CoreGraphics
import Foundation
import RPCore
import RPEngine

/// A small in-memory cache in front of ``RPEngine/PreviewRendering``.
///
/// Two reasons it exists rather than each view calling the renderer:
///
/// - a filmstrip scrolling over 400 shots would otherwise re-decode the same
///   JPEG on every appearance;
/// - the before/after control asks for the same image twice (once with the
///   edits, once without) and, while the Phase 1 renderer ignores `EditState`,
///   those are literally the same request.
///
/// Bounded by *count*, not bytes: everything in it is a thumbnail or one
/// preview-sized image, and counting bytes would mean touching `CGImage`
/// internals for no practical gain at this size.
public actor PreviewImageCache {
    public struct Key: Hashable, Sendable {
        var path: String
        var maxPixelSize: Int
        var editStateFingerprint: String
    }

    private let renderer: any PreviewRendering
    private let capacity: Int
    private var storage: [Key: PreviewImage] = [:]
    /// Most-recently-used last.
    private var order: [Key] = []
    /// In-flight loads, so two views asking for the same image decode once.
    private var inFlight: [Key: Task<PreviewImage, any Error>] = [:]

    public init(renderer: any PreviewRendering = PassthroughPreviewRenderer(), capacity: Int = 120) {
        self.renderer = renderer
        self.capacity = max(1, capacity)
    }

    public func image(for request: PreviewRequest) async throws -> PreviewImage {
        let key = Self.key(for: request, renderer: renderer)
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let renderer = self.renderer
        let task = Task<PreviewImage, any Error> {
            try await renderer.renderPreview(request)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        store(image, for: key)
        return image
    }

    public func cachedImage(for request: PreviewRequest) -> PreviewImage? {
        storage[Self.key(for: request, renderer: renderer)]
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    // MARK: - Private

    /// The cache key folds in the `EditState` only when the renderer actually
    /// honours it. With the Phase 1 passthrough renderer the fingerprint is
    /// constant, so the "before" and "after" requests share one entry — the
    /// same fact the before/after UI states out loud.
    private static func key(for request: PreviewRequest, renderer: any PreviewRendering) -> Key {
        Key(
            path: request.originalURL.standardizedFileURL.path,
            maxPixelSize: request.maxPixelSize,
            editStateFingerprint: renderer.appliesEditState
                ? fingerprint(of: request.editState)
                : "passthrough"
        )
    }

    private static func fingerprint(of state: EditState) -> String {
        guard let data = try? RPJSON.encoder.encode(state) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func store(_ image: PreviewImage, for key: Key) {
        storage[key] = image
        touch(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage[oldest] = nil
        }
    }
}
