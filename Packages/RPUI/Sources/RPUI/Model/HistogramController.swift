#if os(macOS)

    import Foundation
    import Metal
    import Observation
    import OSLog
    import RPEngine

    /// The canvas histogram's state — docs/ADR-0024.
    ///
    /// **macOS only.** The user asked for a histogram "trong không gian hiển thị
    /// hình trên MacOS", and the phone canvas is a single full-bleed pane with no
    /// room for a floating accessory, so the whole file is inside
    /// `#if os(macOS)`: on iOS this type does not exist, no pipeline is built and
    /// no dispatch is ever encoded.
    ///
    /// ## What it owns
    ///
    /// One ``RPEngine/HistogramSampler`` (two compute pipelines and four 4 KB
    /// buffers) and the last reading that came back. It does **not** own the
    /// texture it reads: that is `LivePreviewRenderer.outputTexture`, the graph's
    /// result, handed in by the canvas after each redraw.
    ///
    /// ## The throttling policy, and why there is no timer
    ///
    /// A slider drag issues tens of redraws a second and each one could ask for a
    /// histogram. The rule here is **one reading in flight at a time, with a
    /// trailing re-sample**:
    ///
    /// * a redraw while nothing is outstanding issues a sample immediately;
    /// * a redraw while one is outstanding sets ``isPending`` and returns —
    ///   nothing is queued and no buffer is contended;
    /// * when the outstanding reading lands, a pending flag re-issues once, so the
    ///   histogram always ends up showing the *last* state of the picture rather
    ///   than whatever frame happened to win the race.
    ///
    /// That is self-throttling to whatever rate the GPU can actually sustain, and
    /// it needs no `Date` arithmetic and no debounce constant to tune. A fixed
    /// "every N ms" timer was considered and rejected: it would have to be chosen
    /// for the slowest machine, and it can still leave the plot stale at the end
    /// of a drag unless a trailing fire is added anyway — at which point the timer
    /// is doing nothing the coalescing flag does not already do.
    ///
    /// The measured justification (`Research/bench/p6-histogram-macos.json`,
    /// M1 Pro, Release, 2048x1365 preview): the pass is **1.07 ms** on the GPU and
    /// costs a drag **+0.60 ms per redraw** against a control run of the same
    /// renderer with no sample issued — 1.55 ms/redraw, 646 fps, against a 30 fps
    /// bar. Encoding and committing costs the main thread **0.00095 ms**, i.e.
    /// 7400x less than `LivePreviewRenderer.readOutputPixels()`'s 7.08 ms, which is
    /// the stalling path this type exists not to be.
    @MainActor
    @Observable
    public final class HistogramController {
        /// The last reading, or ``RPEngine/ImageHistogram/empty`` before the first
        /// one lands.
        public private(set) var histogram: ImageHistogram = .empty
        /// `true` once any reading has arrived — the overlay draws nothing until
        /// then rather than showing a flat empty plot.
        public private(set) var hasReading = false
        /// Set when the sampler could not be built; the overlay then simply does
        /// not appear. A histogram is an accessory, so its failure must never
        /// become a canvas failure.
        public private(set) var failureMessage: String?

        @ObservationIgnored private var sampler: HistogramSampler?
        @ObservationIgnored private var isSampling = false
        @ObservationIgnored private var isPending = false
        @ObservationIgnored private var pendingTexture: (any MTLTexture)?

        @ObservationIgnored
        nonisolated static let log = Logger(
            subsystem: "com.duynguyen.RetouchPro", category: "histogram")

        public init() {}

        /// Builds the two pipelines, once per editor. Off the interaction path on
        /// purpose: `MTLDevice.makeComputePipelineState` on an already-compiled
        /// library is sub-millisecond, but it is still work that does not belong
        /// inside a draw callback.
        public func prepare(context: MetalContext) {
            guard sampler == nil, failureMessage == nil else { return }
            do {
                sampler = try HistogramSampler(context: context)
            } catch {
                failureMessage = String(describing: error)
                Self.log.error(
                    "histogram sampler unavailable: \(String(describing: error), privacy: .public)")
            }
        }

        /// Forgets the current reading — call when the shot changes, so the plot
        /// never describes the previous picture.
        public func reset() {
            histogram = .empty
            hasReading = false
            isPending = false
            pendingTexture = nil
        }

        /// Asks for a reading of `texture`, coalescing as described above.
        ///
        /// Returns immediately in every case. Called from the `MTKView` draw
        /// callback after the graph has run, with `renderer.outputTexture`.
        public func sample(_ texture: any MTLTexture) {
            guard let sampler else { return }
            guard !isSampling else {
                isPending = true
                pendingTexture = texture
                return
            }
            isSampling = true
            pendingTexture = nil
            do {
                try sampler.sample(texture: texture) { [weak self] reading in
                    Task { @MainActor in self?.receive(reading) }
                }
            } catch {
                // `.busy` is a legitimate answer (every ring buffer outstanding),
                // not a failure to report: the next redraw asks again.
                isSampling = false
                if !(error is HistogramSampler.Failure) {
                    Self.log.error(
                        "histogram sample failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        private func receive(_ reading: ImageHistogram) {
            // One line per shot, on the first reading only: enough to confirm
            // from `log stream` that the pass really ran and really counted the
            // whole frame, without a per-frame log storm. The same reasoning as
            // `LivePreviewController`'s face-analysis line — a fact that exists
            // only inside a SwiftUI overlay is a fact nobody can check.
            if !hasReading {
                Self.log.log(
                    """
                    histogram: \(reading.sampleCount, privacy: .public) px, peak \
                    \(reading.rgbPeak, privacy: .public), clipped \
                    \(String(format: "%.4f", reading.clippedHighlightFraction), privacy: .public)
                    """)
            }
            histogram = reading
            hasReading = true
            isSampling = false
            // The trailing sample: a redraw arrived while this one was in flight,
            // so the plot on screen is one state behind. Ask once more.
            if isPending, let texture = pendingTexture {
                isPending = false
                sample(texture)
            } else {
                isPending = false
            }
        }

        // MARK: - Test seams

        /// `true` while a reading is outstanding. For the wiring tests, which
        /// assert the coalescing rule without a GPU.
        public var isSamplingNow: Bool { isSampling }
        /// `true` when a redraw arrived during an outstanding reading.
        public var hasPendingSample: Bool { isPending }
        /// `true` when ``prepare(context:)`` produced a working sampler.
        public var isReady: Bool { sampler != nil }
    }

#endif
