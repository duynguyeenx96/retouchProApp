import Foundation
import Metal

/// One reading of the edited picture's tonal distribution — 256 bins per
/// channel, counted on the **sRGB-encoded** values the user is looking at.
///
/// A plain value type with no Metal in it, so the drawing code (and its tests)
/// need no GPU. ``HistogramSampler`` is what produces one.
///
/// ## What "encoded" means here, and why it matters
///
/// The graph renders into an `rgba16Float` texture holding sRGB *code values*
/// (`RenderQuality.pixelSpace`, ADR-0007) — the same numbers that reach the
/// drawable. Bin `b` of a channel therefore counts the pixels whose 8-bit
/// display value would be `b`. That is the reading every photo application's
/// histogram gives, and it is the only one that lines up with the picture on
/// screen: binning linear light instead would push a normally-exposed frame's
/// mass into the bottom fifth of the plot.
///
/// Values outside `[0, 1]` — a slider can push a highlight past 1.0 in a float
/// texture — are clamped into bin 0 / bin 255 rather than dropped, so clipping
/// reads as the end spike a photographer expects.
public struct ImageHistogram: Sendable, Equatable {
    /// Bins per channel. 256, i.e. one bin per 8-bit code value.
    public static let binCount = 256
    /// Channels stored: red, green, blue, luma. Must match
    /// `kRPHistogramChannels` in HistogramShaders.metal.
    public static let channelCount = 4

    /// Which distribution a caller wants. `luma` is the Rec. 709 weighting of
    /// the same encoded values (`kRPLuma`), computed in the same pass because it
    /// costs one more atomic per pixel.
    public enum Channel: Int, Sendable, CaseIterable {
        case red = 0, green = 1, blue = 2, luma = 3
    }

    /// Bin counts, channel-major: `counts[channel.rawValue * 256 + bin]`.
    /// Always `channelCount * binCount` long.
    public private(set) var counts: [UInt32]
    /// How many pixels were binned — the dispatch's sampled-pixel count, which
    /// equals the texture's pixel count at stride 1.
    public let sampleCount: Int

    public init(counts: [UInt32], sampleCount: Int) {
        precondition(counts.count == Self.channelCount * Self.binCount)
        self.counts = counts
        self.sampleCount = sampleCount
    }

    /// An all-zero reading; what the overlay draws before the first sample
    /// lands.
    public static let empty = ImageHistogram(
        counts: [UInt32](repeating: 0, count: channelCount * binCount), sampleCount: 0)

    public subscript(channel: Channel, bin: Int) -> UInt32 {
        counts[channel.rawValue * Self.binCount + bin]
    }

    /// One channel's 256 counts.
    public func bins(_ channel: Channel) -> ArraySlice<UInt32> {
        let start = channel.rawValue * Self.binCount
        return counts[start..<(start + Self.binCount)]
    }

    /// Largest count across **red, green and blue** — the divisor the overlay
    /// normalises all three channels by, so their relative heights survive.
    ///
    /// Luma is deliberately excluded: it is a different distribution (it peaks
    /// wherever the three channels agree) and letting it set the scale would
    /// squash the colour curves for no reason.
    public var rgbPeak: UInt32 {
        var peak: UInt32 = 0
        for channel in [Channel.red, .green, .blue] {
            for value in bins(channel) where value > peak { peak = value }
        }
        return peak
    }

    /// `bins(channel)` scaled to `0...1` against ``rgbPeak``. Empty readings
    /// give all zeros rather than a divide by zero.
    public func normalised(_ channel: Channel) -> [Double] {
        let peak = Double(rgbPeak)
        guard peak > 0 else { return [Double](repeating: 0, count: Self.binCount) }
        return bins(channel).map { Double($0) / peak }
    }

    /// Fraction of sampled pixels in the top bin of any of R, G, B — "how much
    /// of this frame is clipped". Not drawn yet; it is the number a clipping
    /// indicator would read, and it is free here.
    public var clippedHighlightFraction: Double {
        guard sampleCount > 0 else { return 0 }
        let top = Self.binCount - 1
        let worst = max(self[.red, top], max(self[.green, top], self[.blue, top]))
        return Double(worst) / Double(sampleCount)
    }
}

/// Runs the 256-bin histogram kernel over a texture and hands the counts back
/// **without stalling the GPU** — docs/ADR-0024.
///
/// ## Why this is not `LivePreviewRenderer.readOutputPixels()`
///
/// That method exists and would give the same answer on the CPU, and its own
/// doc comment says what is wrong with it: it is test/bench only because it
/// blits the whole `rgba16Float` texture into a shared buffer and *waits*. At a
/// 2048 px preview that is 22 MB and a full pipeline stall, per frame, on the
/// path a slider drag hits tens of times a second. Here the GPU writes 4 KB of
/// counters, and the CPU learns about them in the command buffer's completion
/// handler — the interactive encode never waits for anything.
///
/// ## The ring of buffers
///
/// A completion handler runs after the caller has moved on, so a second sample
/// issued meanwhile must not be writing the counters the first one is about to
/// read. The sampler therefore rotates through ``bufferCount`` shared buffers
/// and refuses to issue a sample when all of them are in flight — the caller
/// (`RPUI.HistogramController`) also coalesces on its side, so in practice at
/// most one is ever outstanding.
///
/// Not `@MainActor`: it holds only Metal objects and serialises itself with a
/// lock, like ``LivePreviewRenderer``.
public final class HistogramSampler: @unchecked Sendable {
    public let context: MetalContext
    /// How many readings can be in flight at once. Three is one more than the
    /// two a "render, then render again immediately" pair needs, and the whole
    /// ring is 12 KB.
    public static let bufferCount = 3
    /// Threadgroup edge for the accumulate pass. Fixed at 16x16 = 256 threads
    /// rather than taken from `threadExecutionWidth`, because the kernel's
    /// threadgroup-local histogram is cleared and merged by *these* threads and
    /// a reproducible shape is what makes the bench number comparable between
    /// machines.
    public static let threadgroupEdge = 16

    private let clearPipeline: any MTLComputePipelineState
    private let accumulatePipeline: any MTLComputePipelineState
    private let lock = NSLock()
    private var buffers: [any MTLBuffer]
    private var nextBuffer = 0
    private var inFlight = 0
    /// ``sampleSynchronously(texture:step:)``'s own buffer, deliberately
    /// **outside** the ring.
    ///
    /// The blocking path waits on its own command buffer, not on anyone else's
    /// completion *handler*, so if it drew from the ring it could be writing
    /// the very counters an earlier async sample's handler was still reading —
    /// a real race, caught by `HistogramTests.ringRefusesWhenFull` on its first
    /// run. One extra 4 KB buffer removes the whole question.
    private let blockingBuffer: any MTLBuffer

    public enum Failure: Error, CustomStringConvertible {
        case cannotMakeBuffer
        case busy

        public var description: String {
            switch self {
            case .cannotMakeBuffer: "Could not allocate the histogram counter buffer."
            case .busy: "Every histogram counter buffer is still in flight."
            }
        }
    }

    public init(context: MetalContext) throws {
        self.context = context
        self.clearPipeline = try context.computePipeline("rp_histogram_clear")
        self.accumulatePipeline = try context.computePipeline("rp_histogram_accumulate")
        let length = ImageHistogram.channelCount * ImageHistogram.binCount
            * MemoryLayout<UInt32>.stride
        var made: [any MTLBuffer] = []
        for _ in 0..<(Self.bufferCount + 1) {
            // `.storageModeShared`: 4 KB the CPU reads straight out of the
            // completion handler, with no blit and no synchronise step. On
            // Apple silicon that is the same memory the GPU wrote.
            guard let buffer = context.device.makeBuffer(
                length: length, options: .storageModeShared)
            else { throw Failure.cannotMakeBuffer }
            made.append(buffer)
        }
        self.blockingBuffer = made.removeLast()
        self.buffers = made
    }

    /// Encodes clear + accumulate into `commandBuffer`, writing into `buffer`.
    ///
    /// Both dispatches go into **one** compute encoder. `makeComputeCommandEncoder()`
    /// is serial by default, so the clear is guaranteed to finish before the
    /// accumulate starts; a second encoder would only add an encoder switch.
    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        texture: any MTLTexture,
        buffer: any MTLBuffer,
        step: Int = 1
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "rp_histogram"
        let slots = ImageHistogram.channelCount * ImageHistogram.binCount

        encoder.setComputePipelineState(clearPipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        let clearWidth = min(clearPipeline.maxTotalThreadsPerThreadgroup, slots)
        encoder.dispatchThreadgroups(
            MTLSize(width: (slots + clearWidth - 1) / clearWidth, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: clearWidth, height: 1, depth: 1))

        let stride = max(1, step)
        let width = (texture.width + stride - 1) / stride
        let height = (texture.height + stride - 1) / stride
        var params = HistogramParams(
            size: SIMD2<UInt32>(UInt32(texture.width), UInt32(texture.height)),
            step: SIMD2<UInt32>(UInt32(stride), UInt32(stride)))
        encoder.setComputePipelineState(accumulatePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<HistogramParams>.stride, index: 1)
        let edge = Self.threadgroupEdge
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + edge - 1) / edge, height: (height + edge - 1) / edge, depth: 1),
            threadsPerThreadgroup: MTLSize(width: edge, height: edge, depth: 1))
        encoder.endEncoding()
    }

    /// Issues a reading and returns immediately; `completion` runs on Metal's
    /// completion queue (**not** the main thread) once the GPU is done.
    ///
    /// Throws ``Failure/busy`` when every ring buffer is still outstanding —
    /// a legitimate answer meaning "ask again after the next one lands", not an
    /// error to report to the user.
    public func sample(
        texture: any MTLTexture,
        step: Int = 1,
        completion: @escaping @Sendable (ImageHistogram) -> Void
    ) throws {
        lock.lock()
        guard inFlight < Self.bufferCount else {
            lock.unlock()
            throw Failure.busy
        }
        let buffer = buffers[nextBuffer]
        nextBuffer = (nextBuffer + 1) % Self.bufferCount
        inFlight += 1
        lock.unlock()

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            lock.lock()
            inFlight -= 1
            lock.unlock()
            throw MetalContext.Failure.noCommandQueue
        }
        commandBuffer.label = "rp_histogram"
        encode(into: commandBuffer, texture: texture, buffer: buffer, step: step)
        let sampleCount = Self.sampleCount(
            width: texture.width, height: texture.height, step: step)
        commandBuffer.addCompletedHandler { [weak self] _ in
            let reading = Self.histogram(from: buffer, sampleCount: sampleCount)
            if let self {
                self.lock.lock()
                self.inFlight -= 1
                self.lock.unlock()
            }
            completion(reading)
        }
        // No `waitUntilCompleted`: that is the whole point of this type.
        commandBuffer.commit()
    }

    /// The same reading, waiting for the GPU. **Tests and bench only** — it
    /// stalls, exactly like `LivePreviewRenderer.readOutputPixels()`.
    public func sampleSynchronously(texture: any MTLTexture, step: Int = 1) throws
        -> ImageHistogram
    {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        encode(into: commandBuffer, texture: texture, buffer: blockingBuffer, step: step)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Self.histogram(
            from: blockingBuffer,
            sampleCount: Self.sampleCount(
                width: texture.width, height: texture.height, step: step))
    }

    /// Number of pixels the dispatch actually reads at `step`.
    public static func sampleCount(width: Int, height: Int, step: Int) -> Int {
        let stride = max(1, step)
        return ((width + stride - 1) / stride) * ((height + stride - 1) / stride)
    }

    /// Reads the 1024 counters out of a shared buffer.
    public static func histogram(from buffer: any MTLBuffer, sampleCount: Int) -> ImageHistogram {
        let slots = ImageHistogram.channelCount * ImageHistogram.binCount
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: slots)
        let counts = Array(UnsafeBufferPointer(start: pointer, count: slots))
        return ImageHistogram(counts: counts, sampleCount: sampleCount)
    }
}

/// Must match `RPHistogramParams` in HistogramShaders.metal.
struct HistogramParams {
    var size: SIMD2<UInt32>
    var step: SIMD2<UInt32>
}
