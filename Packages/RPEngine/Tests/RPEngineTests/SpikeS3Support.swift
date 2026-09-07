import CoreGraphics
import Foundation
import Metal

@testable import RPEngine

/// Shared fixtures for the Phase 0 spike S3 suites.
enum SpikeS3Support {
    /// `nil` when this machine/runtime has no Metal device, so the suites skip
    /// instead of failing spuriously.
    static let context: MetalContext? = MetalContext.shared

    /// A deterministic synthetic test image: a smooth diagonal ramp (so the
    /// guided filter has a gradient to preserve), a hard vertical step (an edge
    /// that must survive), and reproducible fine noise (the "pore texture" the
    /// filter is supposed to be able to remove *or* keep). Interleaved RGBA
    /// float32, alpha 1, row 0 at the top.
    static func syntheticImage(width: Int, height: Int, seed: UInt64 = 12345) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        for y in 0..<height {
            for x in 0..<width {
                let ramp = (Double(x) / Double(width) + Double(y) / Double(height)) * 0.35 + 0.1
                let step = x > width / 2 ? 0.35 : 0.0
                for c in 0..<3 {
                    let noise = (next() - 0.5) * 0.06
                    let value = min(max(ramp + step + noise + Double(c) * 0.05, 0), 1)
                    pixels[(y * width + x) * 4 + c] = Float(value)
                }
                pixels[(y * width + x) * 4 + 3] = 1
            }
        }
        return pixels
    }

    /// One RGB channel of an interleaved buffer, as `Double`.
    static func channel(_ pixels: [Float], _ c: Int) -> [Double] {
        stride(from: c, to: pixels.count, by: 4).map { Double(pixels[$0]) }
    }

    /// Textbook guided filter (He, Sun & Tang 2010) in `Double`, self-guided,
    /// one channel, clamp-to-edge box. This is the control the Metal kernel is
    /// checked against — deliberately written from the paper's five lines rather
    /// than from the shader, so a transcription error in the shader cannot be
    /// reproduced here.
    static func referenceGuidedFilter(
        _ image: [Double], width: Int, height: Int, radius: Int, epsilon: Double
    ) -> [Double] {
        func box(_ src: [Double]) -> [Double] {
            var horizontal = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    var n = 0.0
                    for d in -radius...radius {
                        let xx = min(max(x + d, 0), width - 1)
                        sum += src[y * width + xx]
                        n += 1
                    }
                    horizontal[y * width + x] = sum / n
                }
            }
            var result = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    var n = 0.0
                    for d in -radius...radius {
                        let yy = min(max(y + d, 0), height - 1)
                        sum += horizontal[yy * width + x]
                        n += 1
                    }
                    result[y * width + x] = sum / n
                }
            }
            return result
        }
        let meanI = box(image)
        let meanII = box(image.map { $0 * $0 })
        var a = [Double](repeating: 0, count: image.count)
        var b = [Double](repeating: 0, count: image.count)
        for i in 0..<image.count {
            let variance = max(meanII[i] - meanI[i] * meanI[i], 0)
            a[i] = variance / max(variance + epsilon, 1e-20)
            b[i] = meanI[i] * (1 - a[i])
        }
        let meanA = box(a)
        let meanB = box(b)
        return (0..<image.count).map { meanA[$0] * image[$0] + meanB[$0] }
    }

    /// Runs the guided filter once and returns the destination as float32.
    /// The destination is RGBA32Float so the comparison is not limited by the
    /// half-float output quantisation (~5e-4).
    static func runGuidedFilter(
        _ context: MetalContext, pixels: [Float], width: Int, height: Int,
        options: GuidedFilter.Options
    ) throws -> [Float] {
        // Takes the shared flag lock (RPEngineTestFlags) for the whole run:
        // another suite flipping `guidedFilter` between the set and the
        // construction below would make this throw for no reason.
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.guidedFilter = true }
        defer { flags.leave { RPEngineFeatureFlags.guidedFilter = false } }
        let filter = try GuidedFilter(context: context)
        let source = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead, .shaderWrite])
        let destination = try SpikeTextureIO.makeTexture(
            width: width, height: height, device: context.device, pixelFormat: .rgba32Float,
            usage: [.shaderRead, .shaderWrite])
        let resources = try filter.makeResources(width: width, height: height, options: options)
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        filter.encode(
            into: commandBuffer, source: source, destination: destination,
            resources: resources, options: options)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try readFloat32(destination, queue: context.commandQueue)
    }

    /// Reads an RGBA32Float texture back as interleaved float32.
    static func readFloat32(_ texture: any MTLTexture, queue: any MTLCommandQueue) throws -> [Float] {
        let bytesPerRow = texture.width * 16
        guard
            let buffer = texture.device.makeBuffer(
                length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw MetalContext.Failure.noCommandQueue }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var out = [Float](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { raw in
            raw.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.contents(), count: bytesPerRow * texture.height))
        }
        return out
    }
}

/// Median / percentile helpers for the S3 benchmark.
enum S3BenchStats {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
