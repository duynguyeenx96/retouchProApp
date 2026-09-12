import CoreGraphics
import Foundation
import Metal
import Testing

@testable import RPEngine

/// The two conversions the export path added, checked against the ones the
/// preview path already used.
///
/// Both exist only because of memory: at 24 MP the preview's full-frame
/// conversions allocate 384 MB (float32 draw) and 192 MB (float16 copy) at once,
/// which is not a shape an iPhone export can take. Banding changes *how much*
/// memory is live, and these tests exist to prove it changes nothing else.
@Suite("Phase 3 export image conversions")
struct ExportImageBuilderTests {

    @Test("The banded upload is bit-identical to the full-frame upload")
    func bandedUploadMatchesTheFullFrameUpload() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 67
        let height = 130
        let floats = SpikeS3Support.syntheticImage(width: width, height: height)
        let image = try ExportRendererTests.makeCGImage(floats, width: width, height: height)

        let reference = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
        let referenceTexture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: reference.pixels, width: width, height: height,
            device: context.device, usage: [.shaderRead, .shaderWrite])
        // A band height that is not a divisor of the height, so the short last
        // band is exercised.
        let banded = try ExportImageBuilder.makeTexture(
            from: image, space: .sRGBEncoded, device: context.device,
            queue: context.commandQueue, bandRows: 48)

        let a = try SpikeTextureIO.floatPixels(
            of: referenceTexture, queue: context.commandQueue)
        let b = try SpikeTextureIO.floatPixels(of: banded, queue: context.commandQueue)
        #expect(a.count == b.count)
        #expect(SpikeTextureIO.maxAbsoluteDifference(a, b) == 0)
    }

    @Test("The banded read-back is the texture, at 8 and at 16 bits")
    func readBackQuantisesAndNothingElse() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 40
        let height = 71
        let floats = SpikeS3Support.syntheticImage(width: width, height: height)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: floats, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let space = SpikeTextureIO.PixelSpace.sRGBEncoded.cgColorSpace

        for (bits, tolerance) in [(8, 1.0 / 255), (16, 1.0 / 65535)] {
            let image = try ExportImageBuilder.makeCGImage(
                from: texture, queue: context.commandQueue, bitsPerComponent: bits,
                colorSpace: space, bandRows: 16)
            #expect(image.width == width)
            #expect(image.height == height)
            #expect(image.bitsPerComponent == bits)
            let read = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
            // The texture itself is float16, so compare against what the GPU
            // holds rather than against the float32 the test started from.
            let onGPU = try SpikeTextureIO.floatPixels(of: texture, queue: context.commandQueue)
            let worst = SpikeTextureIO.maxAbsoluteDifference(onGPU, read.pixels)
            #expect(
                worst <= tolerance * 1.5,
                "\(bits)-bit read-back differs by \(worst), more than one quantisation step")
        }
    }

    @Test("Values outside 0…1 are clamped, not wrapped")
    func readBackClamps() throws {
        guard let context = SpikeS3Support.context else { return }
        let width = 4
        let height = 2
        var floats = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            floats[i * 4] = i % 2 == 0 ? -0.5 : 1.8
            floats[i * 4 + 1] = 0.5
            floats[i * 4 + 2] = 2.0
            floats[i * 4 + 3] = 1
        }
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: floats, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let image = try ExportImageBuilder.makeCGImage(
            from: texture, queue: context.commandQueue, bitsPerComponent: 8,
            colorSpace: SpikeTextureIO.PixelSpace.sRGBEncoded.cgColorSpace)
        let read = try SpikeTextureIO.floatPixels(of: image, space: .sRGBEncoded)
        for i in 0..<(width * height) {
            #expect(read.pixels[i * 4] >= 0)
            #expect(read.pixels[i * 4] <= 1.001)
            #expect(read.pixels[i * 4 + 2] <= 1.001)
        }
    }
}
