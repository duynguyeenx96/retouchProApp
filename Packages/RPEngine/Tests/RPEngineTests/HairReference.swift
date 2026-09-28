import CoreGraphics
import Foundation

@testable import RPEngine

/// A synthetic hair fixture and a `Double` CPU implementation of
/// `rp_hair_composite`, written from docs/ADR-0026's specification — the
/// `EyesTeethReference` arrangement. It proves the shader computes the
/// documented formula; it does **not** prove the formula looks good, which
/// nobody has checked on a real photo yet (docs/PLAN.md Phase 5, local work).
enum HairReference {
    struct Fixture {
        var width: Int
        var height: Int
        /// Interleaved RGBA, already quantised to half-float (the GPU reads an
        /// rgba16Float source).
        var pixels: [Float]
        var face: FaceRenderInput
        /// `true` where the image pixel is painted as hair (mask fully on).
        var isHair: [Bool]
        /// `true` where the mask is exactly 0 after bilinear sampling, i.e. where
        /// nothing may change.
        var isOutside: [Bool]
    }

    static let maskSide = 32
    static let maskScale: CGFloat = 3
    /// Rows `< hairRows` of the mask are hair (255), row `hairRows` is a 50 %
    /// feather row, everything below is 0.
    static let hairRows = 12

    static func fixture(width: Int = 96, height: Int = 72) -> Fixture {
        var values = [UInt8](repeating: 0, count: maskSide * maskSide)
        for y in 0..<maskSide {
            for x in 0..<maskSide {
                values[y * maskSide + x] = y < hairRows ? 255 : (y == hairRows ? 128 : 0)
            }
        }
        let mask = RenderMask(
            width: maskSide, height: maskSide, values: values,
            maskToImage: CGAffineTransform(scaleX: maskScale, y: maskScale))
        let face = FaceRenderInput(landmarks: [], faceWidth: 60, masks: [.hair: mask])

        // Hair occupies image rows whose mask sample is fully inside; the
        // bilinear ramp spans roughly one mask pixel (3 image rows) either side
        // of the feather row, so the labels leave a generous gap.
        let hairEnd = Int(CGFloat(hairRows - 1) * maskScale)       // fully 255
        let outsideStart = Int(CGFloat(hairRows + 2) * maskScale)  // fully 0

        var pixels = [Float](repeating: 0, count: width * height * 4)
        var isHair = [Bool](repeating: false, count: width * height)
        var isOutside = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let rgb: (Double, Double, Double)
                if y < outsideStart {
                    // Brown hair with strand-scale luma stripes, so "brighter
                    // than the neighbourhood" is not trivially a step edge.
                    let band = 1 + 0.35 * sin(Double(x) * 0.5 + Double(y) * 0.15)
                    rgb = (0.30 * band, 0.22 * band, 0.16 * band)
                } else {
                    rgb = (0.80, 0.62, 0.52)
                }
                pixels[o] = Float(rgb.0)
                pixels[o + 1] = Float(rgb.1)
                pixels[o + 2] = Float(rgb.2)
                pixels[o + 3] = 1
                isHair[y * width + x] = y < hairEnd
                isOutside[y * width + x] = y >= outsideStart
            }
        }
        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        return Fixture(
            width: width, height: height, pixels: quantised, face: face, isHair: isHair,
            isOutside: isOutside)
    }

    static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    // Mirrors of the shader constants — a typo on either side fails the golden.
    static let glossContrast = 0.6
    static let glossKnee = 0.06
    static let glossLift = 0.25
    static let dyeStrength = 0.85
    static let maxLightRatio = 4.0

    static func saturate(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// One pixel of `rp_hair_composite`. `c` and `low` are the source and gloss
    /// layer colours, `m` the rasterised mask value.
    static func composite(
        c source: SIMD3<Double>, low: SIMD3<Double>, m: Double, sliders: HairSliders
    ) -> SIMD3<Double> {
        let gloss = sliders.gloss / 100
        let dye = sliders.dye / 100
        let exponent = Double(Float(sliders.lightnessExponent))
        let active = m * (gloss + dye + abs(exponent - 1))
        guard active > 0 else { return source }

        var c = source
        if gloss > 0 {
            let g = gloss * m
            let sheen = saturate(((c * luma).sum() - (low * luma).sum()) / glossKnee)
            c = c + (c - low) * (g * glossContrast)
            c = c + (SIMD3(repeating: 1) - c) * (g * sheen * glossLift)
        }
        if dye > 0 {
            let y = (c * luma).sum()
            let tint = HairSliders.dyeTint(tone: sliders.dyeTone)
            let dyed = tint * y
            let t = dye * m * dyeStrength
            c = c + (dyed - c) * t
        }
        if exponent != 1 {
            let y = max((c * luma).sum(), 0)
            let ratio = y > 1e-4 ? min(pow(y, exponent) / y, maxLightRatio) : 1
            c = c + (c * ratio - c) * m
        }
        return SIMD3(saturate(c.x), saturate(c.y), saturate(c.z))
    }

    /// The whole frame through ``composite(c:low:m:sliders:)``, fed a given
    /// gloss layer and mask (the node's own, so a composite failure is not
    /// confused with a blur or rasterisation one).
    static func composite(
        pixels: [Float], low: [Float], mask: [Double], width: Int, height: Int,
        sliders: HairSliders
    ) -> [Float] {
        var out = pixels
        for i in 0..<(width * height) {
            let o = i * 4
            let c = SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2]))
            let l = SIMD3(Double(low[o]), Double(low[o + 1]), Double(low[o + 2]))
            let r = composite(c: c, low: l, m: mask[i], sliders: sliders)
            out[o] = Float(r.x)
            out[o + 1] = Float(r.y)
            out[o + 2] = Float(r.z)
        }
        return out
    }

    static func meanLuma(_ pixels: [Float], where include: [Bool]) -> Double {
        var sum = 0.0
        var n = 0
        for i in include.indices where include[i] {
            let o = i * 4
            sum += (SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) * luma)
                .sum()
            n += 1
        }
        return n == 0 ? 0 : sum / Double(n)
    }
}
