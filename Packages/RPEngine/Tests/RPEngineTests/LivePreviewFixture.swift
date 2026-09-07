import CoreGraphics
import Foundation

@testable import RPEngine

/// An 8-bit sRGB `CGImage` fixture — the shape `ImageDecoder` really hands the
/// canvas.
///
/// Built from `SpikeS3Support.syntheticImage` so the content is the same ramp +
/// step + noise every other Phase 2 suite measures on, and drawn through a
/// `CGBitmapContext` with the sRGB colour space so the round trip
/// `CGImage → SpikeTextureIO.floatPixels` has no conversion in it.
enum LivePreviewFixture {
    static func sRGBImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        let floats = SpikeS3Support.syntheticImage(width: width, height: height, seed: seed)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let v = max(0, min(1, floats[i * 4 + c]))
                bytes[i * 4 + c] = UInt8((v * 255).rounded())
            }
            bytes[i * 4 + 3] = 255
        }
        let context = bytes.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return context!.makeImage()!
    }
}
