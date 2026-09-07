import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import RPCore
@testable import RPEngine

/// Phase 1 stub coverage: the decode path the UI stands on, and the explicit
/// promise that the passthrough renderer does not apply edits.
@Suite("Preview renderer stub")
struct PreviewRendererStubTests {
    /// Writes a `width × height` PNG and returns its URL. Caller deletes it.
    static func writePNG(width: Int, height: Int) throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpengine-\(UUID().uuidString).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("Decodes an image and reports the full-resolution source size")
    func decodesAndReportsSize() throws {
        let url = try Self.writePNG(width: 400, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try ImageDecoder.decode(contentsOf: url, maxPixelSize: 100)
        #expect(preview.pixelSize == CGSize(width: 100, height: 50))
        #expect(preview.sourcePixelSize == CGSize(width: 400, height: 200))
        #expect(ImageDecoder.pixelSize(ofImageAt: url) == CGSize(width: 400, height: 200))
    }

    @Test("A non-image file is reported, not crashed on")
    func nonImageFails() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rpengine-\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try ImageDecoder.decode(contentsOf: url, maxPixelSize: 64)
        }
    }

    /// The load-bearing property: RPUI's before/after control reads
    /// `appliesEditState` to decide whether it may claim the two sides differ.
    @Test("Passthrough renderer declares that it ignores EditState, and does")
    func passthroughIgnoresEditState() async throws {
        let url = try Self.writePNG(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = PassthroughPreviewRenderer()
        #expect(renderer.appliesEditState == false)

        var edited = EditState()
        edited.setSlider("smooth", in: EditState.SectionKey.skin, to: 100)

        let before = try await renderer.renderPreview(
            PreviewRequest(originalURL: url, maxPixelSize: 64))
        let after = try await renderer.renderPreview(
            PreviewRequest(originalURL: url, editState: edited, maxPixelSize: 64))
        #expect(before.pixelSize == after.pixelSize)
        #expect(pixelData(before.cgImage) == pixelData(after.cgImage))
    }

    @Test("`original` strips the edits from a request")
    func originalRequestHasDefaultEditState() {
        var edited = EditState()
        edited.setSlider("smooth", in: EditState.SectionKey.skin, to: 40)
        let request = PreviewRequest(
            originalURL: URL(fileURLWithPath: "/tmp/a.jpg"), editState: edited, maxPixelSize: 512)
        #expect(request.original.editState.isDefault)
        #expect(request.original.maxPixelSize == 512)
        #expect(request.original.originalURL == request.originalURL)
    }

    private func pixelData(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
