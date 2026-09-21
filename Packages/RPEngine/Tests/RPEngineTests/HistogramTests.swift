import Foundation
import Metal
import Testing

@testable import RPEngine

/// Phase 6 — the canvas histogram kernel (docs/ADR-0024).
///
/// Every assertion here is against **real GPU output** on a texture whose
/// correct answer is known by construction, which is the standard the other
/// Metal kernels in this package are held to (`ColorRenderNodeTests`,
/// `ContourRenderTests`): "it compiles and runs" is not a measurement.
///
/// The four things that can be wrong with an atomic histogram, and the test
/// that catches each:
///
/// * **the counts** — half red / half black has one arithmetic answer
///   (``halfRedHalfBlackHasTheExactCounts``);
/// * **the bucket boundaries** — a ramp of bucket-centre values must put
///   exactly one column in each of the 256 bins
///   (``everyBucketGetsItsOwnValue``);
/// * **out-of-range float values** — an rgba16Float texture can hold 2.0 and
///   -0.5, and those must clamp into the end bins rather than corrupt memory
///   (``valuesOutsideZeroOneClampIntoTheEndBins``);
/// * **the threadgroup merge** — if the local-to-device merge dropped a
///   threadgroup, the totals would be short, so every test also checks
///   `sum(bins) == sampleCount`.
@Suite("Phase 6 histogram kernel")
struct HistogramTests {
    // MARK: - Layout

    @Test("The params struct matches the shader's")
    func parameterStructsMatchShaderLayout() {
        // 2 x uint2 = 16 bytes, already a multiple of its 8-byte alignment.
        #expect(MemoryLayout<HistogramParams>.stride == 16)
        #expect(ImageHistogram.binCount == 256)
        #expect(ImageHistogram.channelCount == 4)
    }

    // MARK: - Counts

    /// Left half pure red (1, 0, 0), right half pure black — both exactly
    /// representable in float16, so the expected counts are arithmetic, not
    /// approximate.
    @Test("Half pure red, half black gives the exact bucket counts")
    func halfRedHalfBlackHasTheExactCounts() throws {
        guard let context = try Self.requireContext() else { return }
        let width = 64
        let height = 32
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width / 2) {
                pixels[(y * width + x) * 4 + 0] = 1
            }
        }
        for index in 0..<(width * height) { pixels[index * 4 + 3] = 1 }

        let reading = try Self.histogram(of: pixels, width: width, height: height, context: context)
        let half = UInt32(width * height / 2)

        // Red: half the pixels at the top bin, half at the bottom, nothing else.
        #expect(reading[.red, 255] == half)
        #expect(reading[.red, 0] == half)
        #expect(reading.bins(.red).enumerated().allSatisfy { bin, count in
            bin == 0 || bin == 255 || count == 0
        })
        // Green and blue: every pixel is 0.
        #expect(reading[.green, 0] == UInt32(width * height))
        #expect(reading[.blue, 0] == UInt32(width * height))
        // Luma of pure red is 0.2126 (kRPLuma, Rec. 709) -> floor(0.2126 * 256).
        #expect(reading[.luma, Int(0.2126 * 256)] == half)
        #expect(reading[.luma, 0] == half)

        #expect(reading.sampleCount == width * height)
        for channel in ImageHistogram.Channel.allCases {
            #expect(reading.bins(channel).reduce(0, +) == UInt32(width * height))
        }
    }

    /// One column per bucket, each holding that bucket's centre value. If the
    /// bucket arithmetic were `v * 255` instead of `v * 256`, or the clamp were
    /// off by one, several columns would share a bin and others would be empty.
    @Test("Every one of the 256 buckets gets its own value")
    func everyBucketGetsItsOwnValue() throws {
        guard let context = try Self.requireContext() else { return }
        let width = 256
        let height = 4
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // Bucket centre: safely inside the bucket even after the
                // float32 -> float16 conversion the upload does (half's step
                // near 1.0 is 2^-11, a bucket is 2^-8).
                let value = (Float(x) + 0.5) / 256
                let base = (y * width + x) * 4
                pixels[base + 0] = value
                pixels[base + 1] = value
                pixels[base + 2] = value
                pixels[base + 3] = 1
            }
        }

        let reading = try Self.histogram(of: pixels, width: width, height: height, context: context)
        for bin in 0..<256 {
            #expect(
                reading[.red, bin] == UInt32(height),
                "bin \(bin) got \(reading[.red, bin]), expected \(height)")
        }
        // Grey in, grey out: luma of (v, v, v) is v, so the luma histogram is
        // the same shape.
        for bin in 0..<256 {
            #expect(reading[.luma, bin] == UInt32(height))
        }
    }

    @Test("Values outside 0...1 clamp into the end bins")
    func valuesOutsideZeroOneClampIntoTheEndBins() throws {
        guard let context = try Self.requireContext() else { return }
        let width = 8
        let height = 8
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            // Half blown past white, half pushed below black.
            let value: Float = index < (width * height / 2) ? 2.5 : -0.75
            pixels[index * 4 + 0] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 1
        }
        let reading = try Self.histogram(of: pixels, width: width, height: height, context: context)
        let half = UInt32(width * height / 2)
        #expect(reading[.red, 255] == half)
        #expect(reading[.red, 0] == half)
        #expect(reading.bins(.red).reduce(0, +) == UInt32(width * height))
        #expect(reading.clippedHighlightFraction == 0.5)
    }

    /// The threadgroup-local histogram is merged per threadgroup; a frame far
    /// larger than one 16x16 group is what proves the merge adds up.
    @Test("A preview-sized frame counts every pixel exactly once")
    func previewSizedFrameCountsEveryPixel() throws {
        guard let context = try Self.requireContext() else { return }
        let width = 2048
        let height = 1365
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 4242)
        let reading = try Self.histogram(of: pixels, width: width, height: height, context: context)
        #expect(reading.sampleCount == width * height)
        for channel in ImageHistogram.Channel.allCases {
            #expect(reading.bins(channel).reduce(0, +) == UInt32(width * height))
        }
        #expect(reading.rgbPeak > 0)
    }

    @Test("A stride samples the pixels it says it samples")
    func strideSamplesWhatItClaims() throws {
        guard let context = try Self.requireContext() else { return }
        let width = 101
        let height = 37
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 7)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let sampler = try HistogramSampler(context: context)
        let reading = try sampler.sampleSynchronously(texture: texture, step: 3)
        let expected = HistogramSampler.sampleCount(width: width, height: height, step: 3)
        #expect(expected == 34 * 13)
        #expect(reading.sampleCount == expected)
        for channel in ImageHistogram.Channel.allCases {
            #expect(reading.bins(channel).reduce(0, +) == UInt32(expected))
        }
    }

    // MARK: - The asynchronous path

    /// The interactive path: `sample` returns before the GPU is done and the
    /// counts arrive in the completion handler. Asserted to equal the blocking
    /// path's answer on the same texture, so "non-blocking" costs no accuracy.
    @Test("The async sample returns the same counts as the blocking one")
    func asyncSampleMatchesTheBlockingOne() async throws {
        guard let context = try Self.requireContext() else { return }
        let width = 512
        let height = 341
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 99)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let sampler = try HistogramSampler(context: context)
        let blocking = try sampler.sampleSynchronously(texture: texture)

        let asynchronous: ImageHistogram = try await withCheckedThrowingContinuation { cont in
            do {
                try sampler.sample(texture: texture) { reading in
                    cont.resume(returning: reading)
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
        #expect(asynchronous.counts == blocking.counts)
        #expect(asynchronous.sampleCount == blocking.sampleCount)
    }

    /// The ring has a floor: past `bufferCount` outstanding readings the
    /// sampler refuses rather than letting a completion handler read counters
    /// another dispatch is writing.
    @Test("Issuing more samples than the ring holds throws .busy, not garbage")
    func ringRefusesWhenFull() async throws {
        guard let context = try Self.requireContext() else { return }
        let width = 2048
        let height = 1365
        let pixels = SpikeS3Support.syntheticImage(width: width, height: height, seed: 5)
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let sampler = try HistogramSampler(context: context)

        // Issue one more than the ring can hold, back to back. Whether the
        // earlier ones have completed by then is a race, so the assertion is
        // one-sided: *if* anything throws it must be `.busy`, and the readings
        // that do arrive must still be complete.
        let box = Counter()
        var thrown: (any Error)?
        for _ in 0..<(HistogramSampler.bufferCount + 1) {
            do {
                try sampler.sample(texture: texture) { reading in
                    box.record(reading.bins(.red).reduce(0, +) == UInt32(width * height))
                }
            } catch {
                thrown = error
            }
        }
        if let thrown {
            #expect(thrown is HistogramSampler.Failure)
        }
        // Drain: a blocking sample on the same queue waits for everything
        // already committed.
        _ = try sampler.sampleSynchronously(texture: texture)
        #expect(box.allGood)
    }

    /// A tiny thread-safe tally, because the completion handler runs off the
    /// test's thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var good = true
        func record(_ value: Bool) {
            lock.lock()
            good = good && value
            lock.unlock()
        }
        var allGood: Bool {
            lock.lock()
            defer { lock.unlock() }
            return good
        }
    }

    // MARK: - The value type, with no GPU

    @Test("Normalisation scales against the RGB peak, not luma's")
    func normalisationUsesTheRGBPeak() {
        var counts = [UInt32](repeating: 0, count: ImageHistogram.channelCount * 256)
        counts[0 * 256 + 10] = 50  // red
        counts[1 * 256 + 20] = 100  // green — the RGB peak
        counts[2 * 256 + 30] = 25  // blue
        counts[3 * 256 + 40] = 1000  // luma, deliberately far higher
        let reading = ImageHistogram(counts: counts, sampleCount: 175)
        #expect(reading.rgbPeak == 100)
        #expect(reading.normalised(.red)[10] == 0.5)
        #expect(reading.normalised(.green)[20] == 1.0)
        #expect(reading.normalised(.blue)[30] == 0.25)
        // Luma is allowed to exceed 1 under this scaling; the overlay clamps
        // when it draws, and the alternative (luma setting the scale) would
        // squash all three colour curves.
        #expect(reading.normalised(.luma)[40] == 10.0)
    }

    @Test("An empty histogram normalises to zeros instead of dividing by zero")
    func emptyHistogramIsSafe() {
        #expect(ImageHistogram.empty.rgbPeak == 0)
        #expect(ImageHistogram.empty.normalised(.red).allSatisfy { $0 == 0 })
        #expect(ImageHistogram.empty.clippedHighlightFraction == 0)
    }

    // MARK: - Helpers

    /// `SpikeS3Support.context`, but **failing the test** when this machine has
    /// a Metal device and the context is `nil` anyway.
    ///
    /// The plain `guard let context = … else { return }` every other suite uses
    /// skips on a machine with no GPU, which is right — and it also skips,
    /// silently and greenly, when `MetalContext.shared` is nil because
    /// `makeLibrary(source:)` **threw**. That happened during this item's own
    /// development: a `uint3 [[threads_per_threadgroup]]` next to a `uint2`
    /// `[[thread_position_in_grid]]` is a compile error in MSL, the whole
    /// library failed to build, and all ten of these tests reported a pass
    /// without ever dispatching anything. A shader that does not compile must
    /// not look like a shader that is correct.
    static func requireContext() throws -> MetalContext? {
        if let context = SpikeS3Support.context { return context }
        if MTLCreateSystemDefaultDevice() != nil {
            let message =
                "This machine has a Metal device but MetalContext.shared is nil — the shader "
                + "library failed to compile. Run Scripts/test.sh macos and read the error."
            Issue.record(Comment(rawValue: message))
            throw MetalContext.Failure.noDevice
        }
        return nil
    }

    static func histogram(
        of pixels: [Float], width: Int, height: Int, context: MetalContext
    ) throws -> ImageHistogram {
        let texture = try SpikeTextureIO.makeTexture(
            fromFloatPixels: pixels, width: width, height: height, device: context.device,
            usage: [.shaderRead])
        let sampler = try HistogramSampler(context: context)
        return try sampler.sampleSynchronously(texture: texture)
    }
}
