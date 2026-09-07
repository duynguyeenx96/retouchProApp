import Foundation

/// Decodes the original file and **ignores `PreviewRequest.editState`
/// completely**.
///
/// It arrived in Phase 1 as a stand-in and **stayed on purpose** once the render
/// graph landed: "the untouched file" is exactly what the filmstrip thumbnails
/// and the canvas's before/after "before" side want, and `appliesEditState ==
/// false` is what keeps `PreviewImageCache` from re-decoding every thumbnail on
/// every slider tick. The edited canvas is ``LivePreviewRenderer`` +
/// `MTKView` and does not go through this type at all (docs/ADR-0013).
public struct PassthroughPreviewRenderer: PreviewRendering {
    public var appliesEditState: Bool { false }
    public let preferredPreviewPixelSize: Int

    public init(preferredPreviewPixelSize: Int = 2048) {
        self.preferredPreviewPixelSize = preferredPreviewPixelSize
    }

    public func renderPreview(_ request: PreviewRequest) async throws -> PreviewImage {
        let url = request.originalURL
        let maxPixelSize = request.maxPixelSize
        // Decoding is synchronous and can take hundreds of ms on a 24 MP file,
        // so it must not run on whatever actor the caller happens to be on.
        return try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.decode(contentsOf: url, maxPixelSize: maxPixelSize)
        }.value
    }
}
