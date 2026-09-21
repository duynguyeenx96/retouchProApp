#if os(macOS)

    import RPEngine
    import SwiftUI

    /// The floating RGB histogram over the edited pane — docs/ADR-0024.
    ///
    /// **macOS only** (the user's own framing: "trong không gian hiển thị hình
    /// trên MacOS"), which is why the whole file is inside `#if os(macOS)` rather
    /// than the body alone: on iOS none of this compiles, so there is no dormant
    /// phone layout to keep in step.
    ///
    /// ## What it draws
    ///
    /// The Lightroom convention, unchanged because it is the one a working
    /// photographer already reads: three overlapping translucent channel
    /// distributions, 256 bins, R / G / B in their own hues at low opacity so the
    /// overlaps blend lighter — grey where all three agree, yellow where red and
    /// green do, and so on. The luma distribution is in the reading too
    /// (`ImageHistogram.Channel.luma`) and is drawn as a faint outline behind the
    /// three, because it is free and it is what tells a blown highlight from a
    /// saturated one.
    ///
    /// All three are scaled by ``RPEngine/ImageHistogram/rgbPeak`` — one divisor
    /// for the three, so their relative heights are real — and the curve is drawn
    /// with a **square-root** vertical scale. That is not decoration: a linear
    /// scale on a normal portrait is one spike in the midtones and a flat line
    /// everywhere else, which hides exactly the shadow and highlight detail the
    /// plot exists to show. Every photo application does the same thing.
    ///
    /// ## What it is not
    ///
    /// Not interactive: no click-to-set-black-point, no channel toggles, no
    /// clipping badges. It reports. `ImageHistogram.clippedHighlightFraction`
    /// exists for the day a clipping indicator is asked for.
    struct HistogramOverlayView: View {
        let histogram: ImageHistogram

        /// Corner-accessory sizing: wide enough that 256 bins are more than one
        /// pixel each at the Mac's 2x scale, short enough to stay out of the
        /// picture. Lightroom's own panel is a similar ratio.
        static let plotSize = CGSize(width: 164, height: 88)

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .frame(width: Self.plotSize.width, height: Self.plotSize.height)
                .background(RPTheme.imageBackground.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(RPTheme.hairlineStrong, lineWidth: 1)
                }
            }
            .padding(8)
            .background(RPTheme.overlayBadge, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(RPTheme.overlayPillBorder, lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Biểu đồ màu")
            .accessibilityValue(Self.accessibilityValue(of: histogram))
        }

        // MARK: - Drawing

        private func draw(in context: inout GraphicsContext, size: CGSize) {
            // Luma first and faint: it sits *behind* the three colour curves, so
            // an eye looking for a channel is never reading the grey one by
            // mistake.
            let luma = Self.path(
                of: histogram.normalised(.luma), in: size,
                // Luma is normalised against the RGB peak too, and on a neutral
                // frame that makes it roughly three times taller than any one
                // channel. Scale it back so it stays a backdrop.
                scale: 1.0 / 3.0)
            context.fill(luma, with: .color(.white.opacity(0.10)))

            for (channel, colour) in Self.channels {
                let path = Self.path(of: histogram.normalised(channel), in: size, scale: 1)
                // `.plusLighter` is what makes the overlaps read the way every
                // photo application's histogram does: red over green shows
                // yellow, all three show grey-white.
                context.blendMode = .plusLighter
                context.fill(path, with: .color(colour.opacity(0.52)))
                context.blendMode = .normal
                context.stroke(path, with: .color(colour.opacity(0.85)), lineWidth: 0.75)
            }
        }

        static let channels: [(ImageHistogram.Channel, Color)] = [
            (.red, Color(red: 1, green: 0.25, blue: 0.25)),
            (.green, Color(red: 0.30, green: 1, blue: 0.40)),
            (.blue, Color(red: 0.36, green: 0.55, blue: 1)),
        ]

        /// The filled area under one channel's curve, in view coordinates.
        ///
        /// `sqrt` on the height, for the reason in the type's doc comment. Pure
        /// and `static` so `HistogramOverlayTests` can assert on the geometry
        /// without rendering anything.
        static func path(of bins: [Double], in size: CGSize, scale: Double) -> Path {
            var path = Path()
            guard !bins.isEmpty, size.width > 0, size.height > 0 else { return path }
            let step = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let height = (min(max(value, 0), 1) * scale).squareRoot()
                path.addLine(
                    to: CGPoint(
                        x: CGFloat(index) * step,
                        y: size.height - CGFloat(height) * size.height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            return path
        }

        /// What VoiceOver reads: the shape of the distribution in words, because
        /// a picture of a curve is not available to it. Pure, so it is tested.
        static func accessibilityValue(of histogram: ImageHistogram) -> String {
            guard histogram.sampleCount > 0 else { return "Chưa có dữ liệu" }
            let clipped = histogram.clippedHighlightFraction
            let percent = Int((clipped * 100).rounded())
            guard percent >= 1 else { return "Không có vùng cháy sáng" }
            return "\(percent)% điểm ảnh cháy sáng"
        }
    }

#endif
