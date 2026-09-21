#if os(macOS)

    import Metal
    import RPEngine
    import SwiftUI
    import Testing

    @testable import RPUI

    /// Phase 6 — the canvas histogram's UI half (docs/ADR-0024).
    ///
    /// Two kinds of assertion, both of which run without a click-through:
    /// the plot geometry (pure `static` functions, no rendering) and the
    /// controller's coalescing policy, which is the throttling decision and is
    /// therefore the thing most worth pinning.
    @Suite("Phase 6 canvas histogram (UI)")
    @MainActor
    struct HistogramOverlayTests {
        // MARK: - Geometry

        @Test("The plot closes along the baseline and spans the full width")
        func plotSpansTheFrame() {
            let bins = [Double](repeating: 1, count: 256)
            let size = CGSize(width: 164, height: 88)
            let path = HistogramOverlayView.path(of: bins, in: size, scale: 1)
            #expect(!path.isEmpty)
            let box = path.boundingRect
            #expect(box.minX == 0)
            #expect(abs(box.maxX - size.width) < 0.001)
            // A full-height bin reaches the top; the closing line is on the
            // baseline.
            #expect(abs(box.minY) < 0.001)
            #expect(abs(box.maxY - size.height) < 0.001)
        }

        /// The square-root vertical scale, asserted rather than described: a bin
        /// at a quarter of the peak must draw at **half** height, which is the
        /// whole reason shadow detail is visible at all.
        @Test("The vertical scale is square-root, not linear")
        func verticalScaleIsSquareRoot() {
            var bins = [Double](repeating: 0, count: 256)
            bins[128] = 0.25
            let size = CGSize(width: 256, height: 100)
            let path = HistogramOverlayView.path(of: bins, in: size, scale: 1)
            // Highest point of the path = smallest y.
            let top = path.boundingRect.minY
            #expect(abs(top - 50) < 0.001, "0.25 of the peak should draw at half height, got \(top)")
        }

        @Test("An empty histogram draws a flat baseline, not a crash")
        func emptyHistogramIsFlat() {
            let path = HistogramOverlayView.path(
                of: ImageHistogram.empty.normalised(.red),
                in: CGSize(width: 164, height: 88), scale: 1)
            #expect(abs(path.boundingRect.height) < 0.001)
            let none = HistogramOverlayView.path(
                of: [], in: CGSize(width: 164, height: 88), scale: 1)
            #expect(none.isEmpty)
        }

        @Test("Out-of-range normalised values clamp instead of overflowing the frame")
        func normalisedValuesAboveOneClamp() {
            // `normalised(.luma)` can legitimately exceed 1 — it is scaled by the
            // RGB peak, not its own.
            var bins = [Double](repeating: 0, count: 256)
            bins[10] = 3.0
            let size = CGSize(width: 100, height: 50)
            let path = HistogramOverlayView.path(of: bins, in: size, scale: 1)
            #expect(path.boundingRect.minY >= -0.001)
        }

        // MARK: - Accessibility

        @Test("VoiceOver gets the clipping figure, in words")
        func accessibilityValueDescribesClipping() {
            #expect(HistogramOverlayView.accessibilityValue(of: .empty) == "Chưa có dữ liệu")

            var counts = [UInt32](repeating: 0, count: ImageHistogram.channelCount * 256)
            counts[0 * 256 + 128] = 100
            let clean = ImageHistogram(counts: counts, sampleCount: 100)
            #expect(HistogramOverlayView.accessibilityValue(of: clean) == "Không có vùng cháy sáng")

            counts[0 * 256 + 255] = 25
            let blown = ImageHistogram(counts: counts, sampleCount: 100)
            #expect(HistogramOverlayView.accessibilityValue(of: blown) == "25% điểm ảnh cháy sáng")
        }

        // MARK: - The controller's throttling policy

        /// Without a Metal context the controller has no sampler, and every
        /// entry point must be a no-op rather than a crash — the state RPUI's
        /// tests and SwiftUI previews run in.
        @Test("With no sampler the controller stays silent")
        func noSamplerIsInert() {
            let controller = HistogramController()
            #expect(!controller.isReady)
            #expect(!controller.hasReading)
            #expect(controller.histogram == .empty)
            #expect(!controller.isSamplingNow)
        }

        @Test("Preparing twice builds one sampler and survives no device")
        func prepareIsIdempotent() throws {
            guard let context = try Self.requireContext() else { return }
            let controller = HistogramController()
            controller.prepare(context: context)
            #expect(controller.isReady)
            #expect(controller.failureMessage == nil)
            controller.prepare(context: context)
            #expect(controller.isReady)
        }

        /// The policy itself: one reading in flight, a second redraw during it
        /// sets the pending flag rather than queueing, and the reading that
        /// lands publishes. Uses a real (tiny) texture because the coalescing
        /// only happens on the path that actually samples.
        @Test("A redraw during an outstanding reading coalesces, then lands")
        func samplingCoalescesAndPublishes() async throws {
            guard let context = try Self.requireContext() else { return }
            let controller = HistogramController()
            controller.prepare(context: context)
            try #require(controller.isReady)

            let width = 64
            let height = 64
            let pixels = [Float](repeating: 1, count: width * height * 4)
            let texture = try SpikeTextureIO.makeTexture(
                fromFloatPixels: pixels, width: width, height: height, device: context.device,
                usage: [.shaderRead])

            controller.sample(texture)
            #expect(controller.isSamplingNow)
            // A second redraw while the first is outstanding.
            controller.sample(texture)
            #expect(controller.hasPendingSample)

            // The completion hops back to the main actor; give it room to land.
            for _ in 0..<200 where !controller.hasReading {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(controller.hasReading)
            #expect(controller.histogram.sampleCount == width * height)
            // Pure white in, so every channel piles into the top bin.
            #expect(controller.histogram[.red, 255] == UInt32(width * height))

            controller.reset()
            #expect(!controller.hasReading)
            #expect(controller.histogram == .empty)
        }

        // MARK: - Helpers

        /// `MetalContext.shared`, but **failing** when this machine has a GPU
        /// and the context is nil anyway — i.e. when the shader library did not
        /// compile. The plain `else { return }` would turn that into a green
        /// vacuous pass, which is exactly how a broken kernel slipped through
        /// once during this item's development (see
        /// `RPEngineTests.HistogramTests.requireContext`).
        static func requireContext() throws -> MetalContext? {
            if let context = MetalContext.shared { return context }
            if MTLCreateSystemDefaultDevice() != nil {
                let message =
                    "This machine has a Metal device but MetalContext.shared is nil — the "
                    + "RPEngine shader library failed to compile."
                Issue.record(Comment(rawValue: message))
                throw MetalContext.Failure.noDevice
            }
            return nil
        }

        // MARK: - The view builds

        @Test("The overlay and the Mac canvas construct")
        func viewsConstruct() {
            let view = HistogramOverlayView(histogram: .empty)
            #expect(HistogramOverlayView.channels.count == 3)
            _ = view.body
        }
    }

#endif
