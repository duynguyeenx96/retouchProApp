import CoreGraphics
import Foundation

@testable import RPEngine

/// A `Double`-precision, CPU-only reference for the whole "Color" render node,
/// plus the synthetic chart the golden and behavioural numbers are measured on.
///
/// The control for this group's golden tests, in the same arrangement as
/// `SkinReference` (the "Da" group), `WarpReference` (the "Mặt" group) and
/// `EyesTeethReference`: written from `ColorRenderNode`'s and
/// `ColorShaders.metal`'s **documented specification** — the step order, the
/// named constants, the formulas in the ADR — rather than transcribed from the
/// shader.
///
/// ### What that independence does and does not prove
/// It is a different language, a different precision and a separate pass over the
/// same written specification, so it catches a transcription error: a swapped
/// channel, a `min` for a `max`, a missing `saturate`, a gamma applied to the
/// wrong branch of the window. It does **not** catch a wrong specification: if the
/// documented film curve is an ugly curve, both implementations agree and both
/// are ugly. Same honest limit as `SkinReference` (ADR-0009), `WarpReference`
/// (ADR-0010) and `EyesTeethReference` (ADR-0011).
///
/// The curve LUT is deliberately *shared* rather than re-derived: the reference
/// reads the same `[Float]` table the node uploaded (`ColorRenderNode.curveTable`)
/// through `ColorToneCurve.lookup`, so the comparison measures the kernel's
/// lookup-and-mix and not a second transcription of the curve. `ColorToneCurve`
/// itself is checked separately (monotonicity, endpoints, per-channel split) in
/// `ColorRenderNodeTests`.
enum ColorReference {

    // MARK: - Fixture

    /// A synthetic grading chart. Everything the 18 sliders have to act on:
    ///
    /// * a **horizontal luminance ramp** 0.04 → 0.96 so Highlights, Shadows,
    ///   Contrast and Curves each have their own end of the range to work on and
    ///   a flat patch would not hide a window applied to the wrong side;
    /// * **eight saturated hue patches**, one per `HueBand` centre, so an HSL
    ///   band that lands on the wrong hue is visible;
    /// * a **skin patch** at the hue vibrance protects;
    /// * a **bright disc and a dark disc**, ~14 px across on a 320-wide frame,
    ///   i.e. between the Auto D&B analysis' two radii (4 px and 18 px) — the one
    ///   scale that produces a non-zero `small − big`. A frame without them would
    ///   let a broken Auto D&B pass as "no change".
    struct Chart {
        var width: Int
        var height: Int
        /// Interleaved RGBA, already quantised to half-float (the GPU reads an
        /// rgba16Float source, so a reference starting from unquantised values
        /// would be charged 5e-4 of upload rounding the kernel did not cause).
        var pixels: [Float]
        /// Per-pixel region labels, for the behavioural measurements.
        var regions: [Region]

        enum Region: UInt8 {
            case background, skin, brightDisc, darkDisc
            case red, orange, yellow, green, aqua, blue, purple, magenta

            static func band(_ band: HueBand) -> Region {
                switch band {
                case .red: .red
                case .orange: .orange
                case .yellow: .yellow
                case .green: .green
                case .aqua: .aqua
                case .blue: .blue
                case .purple: .purple
                case .magenta: .magenta
                }
            }
        }
    }

    static func chart(width: Int = 320, height: Int = 240) -> Chart {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var regions = [Chart.Region](repeating: .background, count: width * height)

        // Background: a horizontal luminance ramp, very slightly warm so a white
        // balance slider has something to neutralise.
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                let v = 0.04 + 0.92 * t
                let o = (y * width + x) * 4
                pixels[o] = Float(min(1, v * 1.03))
                pixels[o + 1] = Float(v)
                pixels[o + 2] = Float(v * 0.95)
                pixels[o + 3] = 1
            }
        }

        // Two discs, at a scale between the Auto D&B radii.
        for (cx, cy, delta, region) in [
            (70.0, 60.0, 0.22, Chart.Region.brightDisc), (210.0, 60.0, -0.22, .darkDisc),
        ] {
            for y in 0..<height {
                for x in 0..<width {
                    let r = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                    guard r < 14 else { continue }
                    let falloff = 1 - (r / 14) * (r / 14)
                    let o = (y * width + x) * 4
                    for channel in 0..<3 {
                        pixels[o + channel] = Float(
                            min(1, max(0, Double(pixels[o + channel]) + delta * falloff)))
                    }
                    // Only the inner half is labelled: the outer ring is where the
                    // disc fades into the ramp, and a dodge/burn measurement taken
                    // there would be measuring the falloff, not the correction.
                    if r < 7 { regions[y * width + x] = region }
                }
            }
        }

        // Eight hue patches plus a skin patch, in a row of squares.
        let patchSide = 30
        let patchY = 150
        var patches: [(Chart.Region, (Double, Double, Double))] = HueBand.allCases.map { band in
            (Chart.Region.band(band), hsvToRGB(hue: band.centreDegrees, s: 0.8, v: 0.8))
        }
        patches.append((.skin, (0.72, 0.56, 0.48)))
        for (index, patch) in patches.enumerated() {
            let x0 = 6 + index * (patchSide + 4)
            guard x0 + patchSide <= width, patchY + patchSide <= height else { continue }
            for y in patchY..<(patchY + patchSide) {
                for x in x0..<(x0 + patchSide) {
                    let o = (y * width + x) * 4
                    pixels[o] = Float(patch.1.0)
                    pixels[o + 1] = Float(patch.1.1)
                    pixels[o + 2] = Float(patch.1.2)
                    regions[y * width + x] = patch.0
                }
            }
        }

        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        return Chart(width: width, height: height, pixels: quantised, regions: regions)
    }

    /// HSV → RGB, used only to build the fixture's hue patches.
    static func hsvToRGB(hue: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let rgb: (Double, Double, Double) =
            switch Int(h) {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    // MARK: - Auto D&B analysis

    /// `rp_color_luma_downsample` + the three box passes, in `Double`.
    ///
    /// Returns the two analysis planes at the grid size
    /// `ColorRenderNode.analysisSize` reports.
    static func analysis(source: [Float], width: Int, height: Int)
        -> (big: [Double], small: [Double], size: (width: Int, height: Int))
    {
        let size = ColorRenderNode.analysisSize(width: width, height: height)
        var luma = [Double](repeating: 0, count: size.width * size.height)
        for gy in 0..<size.height {
            for gx in 0..<size.width {
                // Integer block bounds, the same arithmetic the kernel does.
                let x0 = gx * width / size.width
                let y0 = gy * height / size.height
                let x1 = min(width, max(x0 + 1, (gx + 1) * width / size.width))
                let y1 = min(height, max(y0 + 1, (gy + 1) * height / size.height))
                var sum = 0.0
                var n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let o = (y * width + x) * 4
                        sum += luminance(
                            (Double(source[o]), Double(source[o + 1]), Double(source[o + 2])))
                        n += 1
                    }
                }
                luma[gy * size.width + gx] = n > 0 ? sum / n : 0
            }
        }

        let rBig = ColorRenderNode.bigRadius(analysisWidth: size.width)
        let rSmall = ColorRenderNode.smallRadius(analysisWidth: size.width)
        var big = box(luma, size: size, radius: rBig)
        big = box(big, size: size, radius: rBig)
        let small = box(luma, size: size, radius: rSmall)
        return (big, small, size)
    }

    /// Separable box, horizontal then vertical, clamp-to-edge.
    static func box(_ plane: [Double], size: (width: Int, height: Int), radius: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: plane.count)
        for y in 0..<size.height {
            for x in 0..<size.width {
                var acc = 0.0
                var n = 0.0
                for d in -radius...radius {
                    let xx = min(size.width - 1, max(0, x + d))
                    acc += plane[y * size.width + xx]
                    n += 1
                }
                horizontal[y * size.width + x] = acc / n
            }
        }
        var out = [Double](repeating: 0, count: plane.count)
        for y in 0..<size.height {
            for x in 0..<size.width {
                var acc = 0.0
                var n = 0.0
                for d in -radius...radius {
                    let yy = min(size.height - 1, max(0, y + d))
                    acc += horizontal[yy * size.width + x]
                    n += 1
                }
                out[y * size.width + x] = acc / n
            }
        }
        return out
    }

    /// `rp_color_analysis`: manual bilinear read of an analysis plane at an image
    /// pixel centre.
    static func sampleAnalysis(
        _ plane: [Double], gridSize n: (width: Int, height: Int),
        imageSize: (width: Int, height: Int), x: Int, y: Int
    ) -> Double {
        var px = (Double(x) + 0.5) * (Double(n.width) / Double(imageSize.width)) - 0.5
        var py = (Double(y) + 0.5) * (Double(n.height) / Double(imageSize.height)) - 0.5
        px = min(max(px, 0), Double(n.width - 1))
        py = min(max(py, 0), Double(n.height - 1))
        let x0 = min(n.width - 1, max(0, Int(px.rounded(.down))))
        let y0 = min(n.height - 1, max(0, Int(py.rounded(.down))))
        let x1 = min(x0 + 1, n.width - 1)
        let y1 = min(y0 + 1, n.height - 1)
        let fx = px - Double(x0)
        let fy = py - Double(y0)
        let a = plane[y0 * n.width + x0]
        let b = plane[y0 * n.width + x1]
        let c = plane[y1 * n.width + x0]
        let d = plane[y1 * n.width + x1]
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }

    // MARK: - Constants (the specification, restated)

    static let exposureStops = 5.0
    static let wbTintGain = 0.12
    /// docs/ADR-0023's mapping, restated: slider amount (−1…1) → declared
    /// colour temperature, linear in mired between the photograph's neutral and
    /// 2000 K / 50000 K.
    static let warmFloorKelvin = 2000.0
    static let coolCeilingKelvin = 50000.0

    static func declaredKelvin(amount: Double, neutralKelvin: Double) -> Double {
        guard amount != 0 else { return neutralKelvin }
        let a = min(max(amount, -1), 1)
        let neutral = 1_000_000 / neutralKelvin
        let endpoint = 1_000_000 / (a > 0 ? coolCeilingKelvin : warmFloorKelvin)
        return 1_000_000 / (neutral + abs(a) * (endpoint - neutral))
    }

    /// Kim et al. (2002) Planckian locus, written from the published
    /// coefficients — a separate transcription from `WhiteBalance`'s.
    static func planckianXY(_ kelvin: Double) -> (Double, Double) {
        let t = 1 / kelvin
        let x =
            kelvin < 4000
            ? -0.2661239e9 * t * t * t - 0.2343589e6 * t * t + 0.8776956e3 * t + 0.179910
            : -3.0258469e9 * t * t * t + 2.1070379e6 * t * t + 0.2226347e3 * t + 0.240390
        let y: Double
        if kelvin < 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if kelvin < 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// Bradford `M_A`, `M_A⁻¹` and the sRGB/D65 matrices (Bruce Lindbloom), as
    /// flat row-major arrays so the arithmetic below is visibly independent of
    /// `Matrix3`.
    static let coneMatrix: [Double] = [
        0.8951000, 0.2664000, -0.1614000,
        -0.7502000, 1.7135000, 0.0367000,
        0.0389000, -0.0685000, 1.0296000,
    ]
    static let coneInverse: [Double] = [
        0.9869929, -0.1470543, 0.1599627,
        0.4323053, 0.5183603, 0.0492912,
        -0.0085287, 0.0400428, 0.9684867,
    ]
    static let rgbToXYZ: [Double] = [
        0.4124564, 0.3575761, 0.1804375,
        0.2126729, 0.7151522, 0.0721750,
        0.0193339, 0.1191920, 0.9503041,
    ]
    static let xyzToRGB: [Double] = [
        3.2404542, -1.5371385, -0.4985314,
        -0.9692660, 1.8760108, 0.0415560,
        0.0556434, -0.2040259, 1.0572252,
    ]

    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += a[i * 3 + k] * b[k * 3 + j] }
                out[i * 3 + j] = s
            }
        }
        return out
    }

    static func apply(_ m: [Double], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
            m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
            m[6] * v.0 + m[7] * v.1 + m[8] * v.2
        )
    }

    /// The white-balance gain in linear sRGB: the Bradford CAT from the declared
    /// illuminant to the photograph's neutral. Exactly the identity at 0.
    static func whiteBalanceMatrix(amount: Double, neutralKelvin: Double) -> [Double] {
        guard amount != 0 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        func white(_ k: Double) -> (Double, Double, Double) {
            let (x, y) = planckianXY(k)
            return (x / y, 1, (1 - x - y) / y)
        }
        let declared = declaredKelvin(amount: amount, neutralKelvin: neutralKelvin)
        let s = apply(coneMatrix, white(declared))
        let d = apply(coneMatrix, white(neutralKelvin))
        let diagonal: [Double] = [d.0 / s.0, 0, 0, 0, d.1 / s.1, 0, 0, 0, d.2 / s.2]
        let xyz = mul(coneInverse, mul(diagonal, coneMatrix))
        return mul(xyzToRGB, mul(xyz, rgbToXYZ))
    }
    static let highlightGamma = 1.45
    static let highlightPivot = 0.45
    static let shadowGamma = 0.65
    static let shadowPivot = 0.55
    static let contrastMax = 0.50
    static let vibranceMax = 1.0
    static let vibranceSkinProtect = 0.6
    static let vibranceSkinHue = 25.0
    static let vibranceSkinHalfWidth = 40.0
    static let saturationMax = 1.0
    static let hslSatMax = 1.0
    static let hslBandHalfWidth = 60.0
    static let dnbGain = 18.0
    static let dodgeGamma = 0.8091
    static let burnGamma = 1.2199

    static let lumaWeights = (r: 0.2126, g: 0.7152, b: 0.0722)

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        c.0 * lumaWeights.r + c.1 * lumaWeights.g + c.2 * lumaWeights.b
    }

    static func toLinear(_ v: Double) -> Double {
        let x = max(v, 0)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func toSRGB(_ v: Double) -> Double {
        let x = max(v, 0)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func hue(_ c: (Double, Double, Double)) -> Double {
        let hi = max(c.0, max(c.1, c.2))
        let lo = min(c.0, min(c.1, c.2))
        let d = hi - lo
        guard d > 1e-6 else { return 0 }
        var h: Double
        if hi == c.0 {
            h = ((c.1 - c.2) / d).truncatingRemainder(dividingBy: 6)
        } else if hi == c.1 {
            h = (c.2 - c.0) / d + 2
        } else {
            h = (c.0 - c.1) / d + 4
        }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    static func bandWeight(hue: Double, centre: Double, halfWidth: Double) -> Double {
        var d = abs(hue - centre)
        d = min(d, 360 - d)
        return max(0, 1 - d / halfWidth)
    }

    static func saturation(_ c: (Double, Double, Double), _ k: Double) -> (Double, Double, Double) {
        let g = luminance(c)
        return (g + (c.0 - g) * (1 + k), g + (c.1 - g) * (1 + k), g + (c.2 - g) * (1 + k))
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    static func mix(
        _ x: (Double, Double, Double), _ y: (Double, Double, Double), _ t: Double
    ) -> (Double, Double, Double) {
        (x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t)
    }

    static func powEach(_ c: (Double, Double, Double), _ g: Double) -> (Double, Double, Double) {
        (pow(max(c.0, 0), g), pow(max(c.1, 0), g), pow(max(c.2, 0), g))
    }

    // MARK: - Composite

    /// Amounts in 0…1, the way the kernel receives them.
    struct Amounts {
        var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
        var wbTemperature = 0.0, wbTint = 0.0, vibrance = 0.0, saturation = 0.0
        var curves = 0.0, autoDodgeBurn = 0.0
        var hsl: [Double] = []
        /// The photograph's own neutral (docs/ADR-0023). `RenderRequest`
        /// carries it; D65 when it carries nothing.
        var neutralKelvin = 6500.0

        init(_ sliders: ColorSliders, neutralKelvin: Double = 6500) {
            self.neutralKelvin = neutralKelvin
            exposure = sliders.exposure / 100
            contrast = sliders.contrast / 100
            highlights = sliders.highlights / 100
            shadows = sliders.shadows / 100
            wbTemperature = sliders.wbTemperature / 100
            wbTint = sliders.wbTint / 100
            vibrance = sliders.vibrance / 100
            saturation = sliders.saturation / 100
            curves = sliders.curves / 100
            autoDodgeBurn = sliders.autoDodgeBurn / 100
            hsl = sliders.hsl.map { $0 / 100 }
        }

        /// **Absolute**, matching the kernel: with signed bands a plain sum
        /// cancels `+50 red, −50 aqua` into "no HSL" (docs/ADR-0016).
        var hslAbsoluteTotal: Double { hsl.reduce(0) { $0 + abs($1) } }
    }

    /// `rp_color_composite` in `Double`.
    ///
    /// `big` and `small` are the analysis planes (may be empty when Auto D&B is
    /// 0); `curveTable` is the LUT the node uploaded; `contourLobes` are the
    /// **exact `Float` lobes the node uploaded** (docs/PLAN.md §6.2 "Tạo khối"),
    /// so this comparison measures the kernel's mask evaluation and not a second
    /// transcription of the mask geometry — the same arrangement the curve LUT
    /// uses.
    static func composite(
        source: [Float], width: Int, height: Int,
        big: [Double], small: [Double], analysisSize: (width: Int, height: Int),
        amounts a: Amounts, curveTable: [Float], contourLobes: [ContourLobe] = []
    ) -> [Float] {
        var out = source
        let active =
            abs(a.exposure) + abs(a.contrast) + abs(a.highlights) + abs(a.shadows)
            + abs(a.wbTemperature) + abs(a.wbTint) + abs(a.vibrance) + abs(a.saturation)
            + a.curves + a.autoDodgeBurn + a.hslAbsoluteTotal
        guard active > 0 || !contourLobes.isEmpty else { return out }

        // Uniform over the frame, exactly as ColorParams computes it once per
        // render on the CPU.
        let wb = whiteBalanceMatrix(amount: a.wbTemperature, neutralKelvin: a.neutralKelvin)

        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                var c = (Double(source[o]), Double(source[o + 1]), Double(source[o + 2]))

                // 1. Auto D&B
                if a.autoDodgeBurn > 0 {
                    let b = sampleAnalysis(
                        big, gridSize: analysisSize, imageSize: (width, height), x: x, y: y)
                    let s = sampleAnalysis(
                        small, gridSize: analysisSize, imageSize: (width, height), x: x, y: y)
                    let dev = s - b
                    let w = min(1, abs(dev) * dnbGain * a.autoDodgeBurn)
                    let g = dev < 0 ? dodgeGamma : burnGamma
                    c = mix(c, powEach(c, g), w)
                }

                // 1b. Contour — the same LUT step with a landmark-anchored mask
                //     supplying the weight and the direction.
                if !contourLobes.isEmpty {
                    let m = ContourMask.value(
                        at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), lobes: contourLobes)
                    let w = abs(m)
                    if w > 0 {
                        c = mix(c, powEach(c, m > 0 ? dodgeGamma : burnGamma), w)
                    }
                }

                // 2. Exposure + White Balance, in linear light.
                if a.exposure != 0 || a.wbTemperature != 0 || a.wbTint != 0 {
                    var lin = (toLinear(c.0), toLinear(c.1), toLinear(c.2))
                    let e = pow(2, a.exposure * exposureStops)
                    lin = (lin.0 * e, lin.1 * e, lin.2 * e)
                    // Temperature: the Bradford CAT from the declared
                    // illuminant to this photograph's neutral (docs/ADR-0023).
                    // Tint: one channel, one pow, unchanged from ADR-0012.
                    let tint = (1.0, pow(1 - wbTintGain, a.wbTint), 1.0)
                    var adapted = apply(wb, lin)
                    adapted = (adapted.0 * tint.0, adapted.1 * tint.1, adapted.2 * tint.2)
                    var white = apply(wb, (1.0, 1.0, 1.0))
                    white = (white.0 * tint.0, white.1 * tint.1, white.2 * tint.2)
                    let norm = max(luminance(white), 1e-4)
                    c = (
                        toSRGB(adapted.0 / norm), toSRGB(adapted.1 / norm),
                        toSRGB(adapted.2 / norm)
                    )
                }

                // 3/4. Highlights and Shadows.
                // The sign picks the gamma (g or 1/g), the magnitude is the mix.
                let luma = luminance(c)
                if a.highlights != 0 {
                    let w = smoothstep(highlightPivot, 1, luma)
                    let g = a.highlights > 0 ? highlightGamma : 1 / highlightGamma
                    c = mix(c, powEach(c, g), abs(a.highlights) * w)
                }
                if a.shadows != 0 {
                    let w = 1 - smoothstep(0, shadowPivot, luma)
                    let g = a.shadows > 0 ? shadowGamma : 1 / shadowGamma
                    c = mix(c, powEach(c, g), abs(a.shadows) * w)
                }

                // 5. Contrast — a negative amount extrapolates away from the
                //    S-curve, i.e. flattens toward mid-grey.
                if a.contrast != 0 {
                    let s = (clamp01(c.0), clamp01(c.1), clamp01(c.2))
                    let curve = (
                        s.0 * s.0 * (3 - 2 * s.0), s.1 * s.1 * (3 - 2 * s.1),
                        s.2 * s.2 * (3 - 2 * s.2)
                    )
                    c = mix(c, curve, a.contrast * contrastMax)
                }

                // 6. Curves.
                if a.curves > 0 {
                    let f = (
                        ColorToneCurve.lookup(curveTable, c.0, channel: 0),
                        ColorToneCurve.lookup(curveTable, c.1, channel: 1),
                        ColorToneCurve.lookup(curveTable, c.2, channel: 2)
                    )
                    c = mix(c, f, a.curves)
                }

                // 7. Vibrance.
                if a.vibrance != 0 {
                    let hi = max(c.0, max(c.1, c.2))
                    let lo = min(c.0, min(c.1, c.2))
                    let sat = (hi - lo) / max(hi, 1e-4)
                    let skin = bandWeight(
                        hue: hue(c), centre: vibranceSkinHue, halfWidth: vibranceSkinHalfWidth)
                    let k =
                        a.vibrance * vibranceMax * clamp01(1 - sat)
                        * (1 - vibranceSkinProtect * skin)
                    c = saturation(c, k)
                }

                // 8. Saturation.
                if a.saturation != 0 {
                    c = saturation(c, a.saturation * saturationMax)
                }

                // 9. HSL bands. The branch test is absolute; `amountSum` is not.
                if a.hslAbsoluteTotal > 0 {
                    let h = hue(c)
                    var weightSum = 0.0
                    var amountSum = 0.0
                    for band in HueBand.allCases {
                        let w = bandWeight(
                            hue: h, centre: band.centreDegrees, halfWidth: hslBandHalfWidth)
                        weightSum += w
                        amountSum += w * a.hsl[band.rawValue]
                    }
                    if weightSum > 0 {
                        c = saturation(c, (amountSum / weightSum) * hslSatMax)
                    }
                }

                out[o] = Float(clamp01(c.0))
                out[o + 1] = Float(clamp01(c.1))
                out[o + 2] = Float(clamp01(c.2))
            }
        }
        return out
    }

    /// The whole node in `Double`: analysis (when needed) then composite.
    static func renderNode(
        source: [Float], width: Int, height: Int, sliders: ColorSliders, curveTable: [Float],
        contourLobes: [ContourLobe] = [], neutralKelvin: Double = 6500
    ) -> [Float] {
        var big: [Double] = []
        var small: [Double] = []
        var size = (width: 1, height: 1)
        if sliders.needsDodgeBurnAnalysis {
            let a = analysis(source: source, width: width, height: height)
            big = a.big
            small = a.small
            size = a.size
        }
        return composite(
            source: source, width: width, height: height, big: big, small: small,
            analysisSize: size, amounts: Amounts(sliders, neutralKelvin: neutralKelvin),
            curveTable: curveTable, contourLobes: contourLobes)
    }

    // MARK: - Behaviour

    /// Mean absolute RGB change over the pixels of one region. The number a PSNR
    /// cannot produce: *did the slider move the pixels it claims to move?*
    static func meanChange(
        _ before: [Float], _ after: [Float], regions: [Chart.Region], _ region: Chart.Region
    ) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<regions.count where regions[i] == region {
            let o = i * 4
            for channel in 0..<3 {
                sum += abs(Double(after[o + channel]) - Double(before[o + channel]))
            }
            count += 3
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Mean signed luminance change over one region — the sign says which way a
    /// tone slider moved the picture, which `meanChange` deliberately hides.
    static func meanLuminanceChange(
        _ before: [Float], _ after: [Float], regions: [Chart.Region], _ region: Chart.Region
    ) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<regions.count where regions[i] == region {
            let o = i * 4
            let b = luminance((Double(before[o]), Double(before[o + 1]), Double(before[o + 2])))
            let a = luminance((Double(after[o]), Double(after[o + 1]), Double(after[o + 2])))
            sum += a - b
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }
}
