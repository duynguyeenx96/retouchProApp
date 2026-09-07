import CoreGraphics
import Foundation
import Testing

@testable import RPEngine

/// Phase 0 spike S3 — the texture I/O the measurement stands on.
///
/// If upload or download flips the image, every warp number in the spike is
/// still self-consistent and completely wrong. This suite is the guard.
@Suite("Spike S3 texture I/O")
struct SpikeTextureIOTests {
    /// `CGColor(red:green:blue:alpha:)` has **no colour space** and resolves to
    /// Generic RGB (gamma 1.8), so filling with 0.5 grey and reading back
    /// through an sRGB context gives 0.573, not 0.5. That is a correct
    /// conversion and it cost 20 minutes here; build colours in an explicit
    /// space instead.
    private static func sRGBColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [r, g, b, 1])!
    }

    /// A CGBitmapContext lays out row 0 at the top while its *drawing* origin is
    /// at the bottom-left. Draw a marker in the top-left of the picture and
    /// assert it lands at buffer index 0.
    @Test("CGImage → float pixels keeps row 0 at the top")
    func cgImageOrientation() throws {
        let width = 4, height = 3
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(Self.sRGBColor(0, 0, 0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(Self.sRGBColor(1, 0, 0))
        // Drawing origin is bottom-left, so y = height − 1 is the top row.
        context.fill(CGRect(x: 0, y: height - 1, width: 1, height: 1))
        let image = try #require(context.makeImage())

        let (pixels, w, h) = try SpikeTextureIO.floatPixels(
            of: image, space: .sRGBEncoded)
        #expect(w == width && h == height)
        #expect(pixels[0] > 0.9, "top-left red channel \(pixels[0])")
        #expect(pixels[1] < 0.1)
        // Bottom-left must still be black.
        let bottomLeft = (height - 1) * width * 4
        #expect(pixels[bottomLeft] < 0.1, "bottom-left red channel \(pixels[bottomLeft])")
    }

    @Test("Texture upload/download preserves orientation and values")
    func roundTripKeepsOrientation() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 5, height = 3
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 1 }
        pixels[0] = 1  // top-left red
        pixels[((height - 1) * width + (width - 1)) * 4 + 1] = 1  // bottom-right green

        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let back = try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
        #expect(back.count == pixels.count)
        for i in 0..<pixels.count {
            #expect(abs(back[i] - pixels[i]) < 1e-3, "index \(i): \(back[i]) vs \(pixels[i])")
        }
    }

    /// The two pixel spaces must actually differ, otherwise the colour-space
    /// experiment in the spike report is comparing a thing with itself.
    @Test("sRGB-encoded and linear-light decodes of the same image differ")
    func pixelSpacesDiffer() throws {
        let width = 4, height = 1
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(Self.sRGBColor(0.5, 0.5, 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let encoded = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded).pixels
        let linear = try SpikeTextureIO.floatPixels(of: image, space: .linearSRGB).pixels
        // sRGB 0.5 is ~0.214 in linear light. Assert the gap is real and in the
        // expected direction.
        #expect(abs(encoded[0] - 0.5) < 0.02, "encoded \(encoded[0])")
        #expect(abs(linear[0] - 0.214) < 0.02, "linear \(linear[0])")
    }

    @Test("PSNR is infinite for identical buffers and finite otherwise")
    func psnrSanity() {
        let a: [Float] = [0.5, 0.25, 0.75, 1, 0.1, 0.2, 0.3, 1]
        var b = a
        #expect(SpikeTextureIO.psnr(a, b) == .infinity)
        b[0] = 0.6
        let value = SpikeTextureIO.psnr(a, b)
        #expect(value.isFinite && value > 0)
        #expect(abs(SpikeTextureIO.maxAbsoluteDifference(a, b) - 0.1) < 1e-6)
    }
}
