import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import RPUI

/// Regression test for the filmstrip/library thumbnail overflow.
///
/// The bug: `Image.resizable().aspectRatio(contentMode: .fill)` *reports* the
/// size that covers the proposal, so a 6000×4000 shot in the 68×76 filmstrip
/// tile laid out at 114×76 and drew over its neighbour — the two cells in a
/// 2-shot project overlapped instead of sitting 8 pt apart, and the oversized
/// cell dragged its caption bar and mint selection outline out with it.
/// ``ScaledPreviewImage`` is the fix; this pins it in pixels rather than in
/// prose, because the failure is invisible to any assertion on the *outer*
/// frame (the frame was always 68×76 — only its content escaped).
///
/// `ImageRenderer` is used instead of a window because it is synchronous and
/// runs on both destinations. It does **not** run `.task`, which is why the
/// test renders ``ScaledPreviewImage`` directly instead of
/// ``AsyncPreviewImageView`` (whose image would never load in a snapshot).
@MainActor
@Suite("Thumbnail tile layout")
struct ThumbnailLayoutTests {
    private static let tile = CGSize(width: 68, height: 76)

    /// Two 68×76 tiles, 8 pt apart, both showing a 3:2 landscape picture. The
    /// gap column and the outside margins must stay background-coloured.
    @Test("A landscape picture stays inside its tile and out of the 8 pt gap")
    func landscapeDoesNotOverlapItsNeighbour() throws {
        let picture = try Self.solidImage(width: 300, height: 100)  // 3:2, wider than the tile
        let gap: CGFloat = 8
        let margin: CGFloat = 20
        let width = Self.tile.width * 2 + gap + margin * 2

        let pixels = try Self.render(
            width: width, height: Self.tile.height,
            content: HStack(spacing: gap) {
                tileView(picture)
                tileView(picture)
            }
            .frame(width: width, height: Self.tile.height)
        )

        let midRow = Int(Self.tile.height / 2)
        // Inside the tiles the picture is drawn...
        #expect(pixels.isPicture(x: Int(margin) + 4, y: midRow))
        #expect(pixels.isPicture(x: Int(margin + Self.tile.width + gap) + 4, y: midRow))
        // ...and nowhere else. Before the fix each tile was 114 pt wide, so the
        // gap and both margins were painted over.
        for x in Int(margin + Self.tile.width + 1)...Int(margin + Self.tile.width + gap - 1) {
            #expect(pixels.isBackground(x: x, y: midRow), "gap column \(x) was painted")
        }
        #expect(pixels.isBackground(x: Int(margin) - 4, y: midRow), "left margin was painted")
        #expect(pixels.isBackground(x: Int(width - margin) + 4, y: midRow), "right margin")
    }

    /// The same in the other axis: a portrait picture covers the tile by
    /// growing *taller*, which is how the selected filmstrip cell used to push
    /// its caption below the 104 pt strip.
    @Test("A portrait picture stays inside its tile vertically")
    func portraitDoesNotOverflowVertically() throws {
        let picture = try Self.solidImage(width: 100, height: 300)  // 2:3, taller than the tile
        let margin: CGFloat = 20
        let height = Self.tile.height + margin * 2

        let pixels = try Self.render(
            width: Self.tile.width, height: height,
            content: tileView(picture).frame(width: Self.tile.width, height: height))

        let midColumn = Int(Self.tile.width / 2)
        #expect(pixels.isPicture(x: midColumn, y: Int(height / 2)))
        #expect(pixels.isBackground(x: midColumn, y: Int(margin) - 4), "above the tile")
        #expect(pixels.isBackground(x: midColumn, y: Int(height - margin) + 4), "below the tile")
    }

    /// `.fit` was never the broken case; keep it honest anyway — it must still
    /// letterbox inside the tile rather than crop.
    @Test("contentMode .fit letterboxes inside the tile")
    func fitLeavesTheBars() throws {
        let picture = try Self.solidImage(width: 300, height: 100)
        let pixels = try Self.render(
            width: Self.tile.width, height: Self.tile.height,
            content: ScaledPreviewImage(cgImage: picture, contentMode: .fit)
                .frame(width: Self.tile.width, height: Self.tile.height)
                .background(Color.blue))

        #expect(pixels.isPicture(x: Int(Self.tile.width / 2), y: Int(Self.tile.height / 2)))
        // 68 pt of a 3:2 picture is ~23 pt tall, so the top row is a bar.
        #expect(pixels.isBackground(x: Int(Self.tile.width / 2), y: 2))
    }

    // MARK: - Harness

    /// One tile as the filmstrip builds it: a fixed 68×76 frame around a
    /// `.fill` picture, on a background that makes any overflow visible.
    private func tileView(_ picture: CGImage) -> some View {
        ScaledPreviewImage(cgImage: picture, contentMode: .fill)
            .frame(width: Self.tile.width, height: Self.tile.height)
    }

    /// A solid red picture — red is the "picture" sentinel, blue the
    /// "background" sentinel, so a single channel comparison tells them apart
    /// whatever colour management does to the exact values.
    private static func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private static func render(
        width: CGFloat, height: CGFloat, content: some View
    ) throws -> Bitmap {
        let renderer = ImageRenderer(
            content: content
                .frame(width: width, height: height)
                .background(Color.blue))
        renderer.scale = 1
        return try Bitmap(try #require(renderer.cgImage))
    }

    /// RGBA8 samples of a rendered view. `description` is deliberately short:
    /// a failed `#expect` prints the whole value, and a raw `[UInt8]` of a
    /// 68×116 render is ~2 MB of noise in the log.
    private struct Bitmap: CustomStringConvertible {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) throws {
            // Locals, not `self.width`/`self.height`: referring to a stored
            // property inside the closure would capture a half-initialised
            // `self`, which the compiler rejects.
            let w = image.width
            let h = image.height
            width = w
            height = h
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard
                    let context = CGContext(
                        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            bytes = buffer
            try #require(drew, "could not make an RGBA8 context for the rendered view")
        }

        var description: String { "Bitmap(\(width)×\(height))" }

        private func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            guard i + 2 < bytes.count else { return (0, 0, 0) }
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        func isPicture(x: Int, y: Int) -> Bool {
            let p = rgb(x: x, y: y)
            return p.r > p.b
        }

        func isBackground(x: Int, y: Int) -> Bool {
            let p = rgb(x: x, y: y)
            return p.b > p.r
        }
    }
}
