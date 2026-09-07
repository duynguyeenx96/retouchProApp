import CoreGraphics
import Foundation

@testable import RPEngine

/// A `Double`-precision, CPU-only reference for the whole "Da" render node.
///
/// The control for the Phase 2 golden tests, in the same spirit as
/// `SpikeS3Support.referenceGuidedFilter`: written from the *specification*
/// (He & Sun 2015 for the fast guided filter, `SkinRenderNode`'s documented
/// step order for the composite) rather than transcribed from the shader, so a
/// transcription error in `SkinShaders.metal` cannot be reproduced here.
///
/// Independence has one deliberate exception: bilinear upsampling with
/// clamp-to-edge addressing. That is a fixed definition of `MTLSampler`
/// behaviour, not part of the algorithm, and reproducing it is the only way to
/// compare the fast filter's output at all.
enum SkinReference {

    // MARK: - Fixtures

    /// A soft elliptical "skin" mask, 0…255, row 0 at the top.
    static func ellipseMask(width: Int, height: Int, feather: Double = 0.25) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let nx = (Double(x) + 0.5) / Double(width) * 2 - 1
                let ny = (Double(y) + 0.5) / Double(height) * 2 - 1
                let r = sqrt(nx * nx / 0.64 + ny * ny)
                // 1 inside r <= 1-feather, 0 outside r >= 1, smooth between.
                let t = (1.0 - r) / max(feather, 1e-6)
                let v = min(max(t, 0), 1)
                values[y * width + x] = UInt8((v * 255).rounded())
            }
        }
        return values
    }

    /// One face covering a rotated sub-square of the image.
    ///
    /// `faceWidth` must be small enough that `faceWidth * 1.87` (the
    /// CelebAMask-HQ crop side, which is what `ParsedFace.region` carries) leaves
    /// part of the frame outside the mask. A mask that saturates the whole image
    /// still passes a PSNR comparison but stops testing the mask at all — the
    /// first version of this fixture did exactly that and
    /// `maskRasterisationMatchesReference`'s coverage assertion caught it.
    static func face(
        imageWidth: Int, imageHeight: Int, maskSide: Int = 64,
        faceWidth: CGFloat = 120, rotationDegrees: CGFloat = 12
    ) -> FaceRenderInput {
        let side = faceWidth * 1.87  // CelebAMask-HQ framing, as ParsedFace uses
        let center = CGPoint(x: Double(imageWidth) * 0.45, y: Double(imageHeight) * 0.5)
        let scale = side / CGFloat(maskSide)
        let rotation = rotationDegrees * .pi / 180
        // Same construction as CropRegion.outputToImage, which is where a real
        // mask's transform comes from.
        let maskToImage = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -CGFloat(maskSide) / 2, y: -CGFloat(maskSide) / 2)
        let mask = RenderMask(
            width: maskSide, height: maskSide,
            values: ellipseMask(width: maskSide, height: maskSide),
            maskToImage: maskToImage)
        return FaceRenderInput(faceWidth: faceWidth, masks: [.skin: mask])
    }

    // MARK: - Mask rasterisation

    /// Full-resolution coverage in 0…1, the reference for `rp_skin_mask`.
    static func rasterisedMask(
        faces: [FaceRenderInput], width: Int, height: Int
    ) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        let masks = faces.compactMap { $0.masks[.skin] }
        for mask in masks {
            let t = mask.imageToMask
            let source = mask.values.map { Double($0) / 255.0 }
            for y in 0..<height {
                for x in 0..<width {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(t)
                    guard p.x >= 0, p.y >= 0, p.x < CGFloat(mask.width), p.y < CGFloat(mask.height)
                    else { continue }
                    let v = bilinear(
                        source, width: mask.width, height: mask.height,
                        u: Double(p.x) / Double(mask.width),
                        v: Double(p.y) / Double(mask.height))
                    out[y * width + x] = max(out[y * width + x], v)
                }
            }
        }
        return out
    }

    // MARK: - Fast guided filter (He & Sun 2015)

    /// Self-guided fast guided filter, one channel, `Double`.
    ///
    /// The steps are the paper's: block-average `I` and `I²` down by `s`, box
    /// both, form `a` and `b`, box those, then bilinearly upsample `a` and `b`
    /// and combine with the **full-resolution** `I`.
    static func fastGuidedFilter(
        _ image: [Double], width: Int, height: Int, radius: Int, epsilon: Double, subsample: Int
    ) -> [Double] {
        let s = max(1, subsample)
        let subW = (width + s - 1) / s
        let subH = (height + s - 1) / s
        var meanI = [Double](repeating: 0, count: subW * subH)
        var meanII = [Double](repeating: 0, count: subW * subH)
        for sy in 0..<subH {
            for sx in 0..<subW {
                let x0 = sx * s, y0 = sy * s
                let x1 = min(x0 + s, width), y1 = min(y0 + s, height)
                var sum = 0.0, sumSq = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let v = image[y * width + x]
                        sum += v
                        sumSq += v * v
                        n += 1
                    }
                }
                let inv = n > 0 ? 1 / n : 0
                meanI[sy * subW + sx] = sum * inv
                meanII[sy * subW + sx] = sumSq * inv
            }
        }
        let r = max(1, Int((Double(radius) / Double(s)).rounded()))
        let boxI = box(meanI, width: subW, height: subH, radius: r)
        let boxII = box(meanII, width: subW, height: subH, radius: r)
        var a = [Double](repeating: 0, count: subW * subH)
        var b = [Double](repeating: 0, count: subW * subH)
        for i in 0..<a.count {
            let variance = max(boxII[i] - boxI[i] * boxI[i], 0)
            a[i] = variance / max(variance + epsilon, 1e-20)
            b[i] = boxI[i] * (1 - a[i])
        }
        let meanA = box(a, width: subW, height: subH, radius: r)
        let meanB = box(b, width: subW, height: subH, radius: r)

        var out = [Double](repeating: 0, count: width * height)
        // The denominator is s * subW, not width: the coefficient texture covers
        // s * subW full-resolution columns whenever width is not a multiple of s.
        let denomX = Double(s * subW), denomY = Double(s * subH)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / denomX
                let v = (Double(y) + 0.5) / denomY
                let av = bilinear(meanA, width: subW, height: subH, u: u, v: v)
                let bv = bilinear(meanB, width: subW, height: subH, u: u, v: v)
                out[y * width + x] = av * image[y * width + x] + bv
            }
        }
        return out
    }

    // MARK: - Composite

    struct Amounts {
        var smooth = 0.0, keepTexture = 0.0, evenTone = 0.0, redness = 0.0
        var shine = 0.0, brighten = 0.0, darkCircle = 0.0, wrinkle = 0.0

        init(_ sliders: SkinSliders) {
            smooth = sliders.smooth / 100
            keepTexture = sliders.keepTexture / 100
            evenTone = sliders.evenTone / 100
            redness = sliders.redness / 100
            shine = sliders.shine / 100
            brighten = sliders.brighten / 100
            darkCircle = sliders.darkCircle / 100
            wrinkle = sliders.wrinkle / 100
        }
    }

    static let luma = (r: 0.2126, g: 0.7152, b: 0.0722)
    static let shineKnee = 0.06
    static let darkKnee = 0.10
    static let brightenGamma = 0.86

    /// `rp_skin_composite` in `Double`. `source`, `base`, `low` are interleaved
    /// RGBA; `mask` is one plane in 0…1. Returns interleaved RGBA.
    static func composite(
        source: [Float], base: [Float], low: [Float], mask: [Double], amounts a: Amounts
    ) -> [Float] {
        var out = source
        let count = mask.count
        for i in 0..<count {
            let o = i * 4
            let m = mask[i]
            let active =
                m
                * (a.smooth + a.evenTone + a.redness + a.shine + a.brighten + a.darkCircle
                    + a.wrinkle)
            guard active > 0 else { continue }

            let I = (Double(source[o]), Double(source[o + 1]), Double(source[o + 2]))
            let S = (Double(base[o]), Double(base[o + 1]), Double(base[o + 2]))
            let L = (Double(low[o]), Double(low[o + 1]), Double(low[o + 2]))
            let detail = (I.0 - S.0, I.1 - S.1, I.2 - S.2)
            var c = I

            func lum(_ v: (Double, Double, Double)) -> Double {
                v.0 * luma.r + v.1 * luma.g + v.2 * luma.b
            }
            func mix(
                _ x: (Double, Double, Double), _ y: (Double, Double, Double), _ t: Double
            ) -> (Double, Double, Double) {
                (x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t)
            }

            // 1. Mịn da + Giữ texture
            let smoothed = (
                S.0 + detail.0 * a.keepTexture, S.1 + detail.1 * a.keepTexture,
                S.2 + detail.2 * a.keepTexture
            )
            c = mix(c, smoothed, a.smooth * m)

            // 2. Đều màu da
            let scale = lum(c) / max(lum(L), 1e-4)
            c = mix(c, (L.0 * scale, L.1 * scale, L.2 * scale), a.evenTone * m)

            // 3. Khử đỏ
            let excess = max((c.0 - 0.5 * (c.1 + c.2)) - (L.0 - 0.5 * (L.1 + L.2)), 0)
            c.0 -= a.redness * m * excess

            // 4. Khử bóng dầu
            let shineWeight = min(max((lum(c) - lum(L)) / shineKnee, 0), 1)
            c = mix(c, (min(c.0, L.0), min(c.1, L.1), min(c.2, L.2)), a.shine * m * shineWeight)

            // 5. Sáng da
            c = mix(
                c,
                (
                    pow(max(c.0, 0), brightenGamma), pow(max(c.1, 0), brightenGamma),
                    pow(max(c.2, 0), brightenGamma)
                ), a.brighten * m)

            // 6. Quầng thâm
            let darkWeight = min(max((lum(L) - lum(c)) / darkKnee, 0), 1)
            c = mix(c, (max(c.0, L.0), max(c.1, L.1), max(c.2, L.2)), a.darkCircle * m * darkWeight)

            // 7. Nếp nhăn
            c.0 -= a.wrinkle * m * min(detail.0, 0)
            c.1 -= a.wrinkle * m * min(detail.1, 0)
            c.2 -= a.wrinkle * m * min(detail.2, 0)

            out[o] = Float(min(max(c.0, 0), 1))
            out[o + 1] = Float(min(max(c.1, 0), 1))
            out[o + 2] = Float(min(max(c.2, 0), 1))
        }
        return out
    }

    /// The whole node in `Double`: mask, both blurred layers, composite.
    static func renderNode(
        source: [Float], width: Int, height: Int, faces: [FaceRenderInput],
        sliders: SkinSliders, subsample: Int
    ) -> [Float] {
        let mask = rasterisedMask(faces: faces, width: width, height: height)
        let faceWidth = faces.map(\.faceWidth).max() ?? 0
        let smoothRadius = SkinRenderNode.smoothRadius(faceWidth: faceWidth)
        let lowRadius = SkinRenderNode.lowRadius(faceWidth: faceWidth)

        var base = source
        var low = source
        for channel in 0..<3 {
            let plane = SpikeS3Support.channel(source, channel)
            if sliders.needsSmoothLayer {
                let filtered = fastGuidedFilter(
                    plane, width: width, height: height, radius: smoothRadius,
                    epsilon: Double(SkinRenderNode.smoothEpsilon), subsample: subsample)
                for i in 0..<filtered.count { base[i * 4 + channel] = Float(filtered[i]) }
            }
            if sliders.needsLowFrequencyLayer {
                let filtered = fastGuidedFilter(
                    plane, width: width, height: height, radius: lowRadius,
                    epsilon: Double(SkinRenderNode.lowEpsilon), subsample: subsample)
                for i in 0..<filtered.count { low[i * 4 + channel] = Float(filtered[i]) }
            }
        }
        return composite(
            source: source, base: base, low: low, mask: mask, amounts: Amounts(sliders))
    }

    // MARK: - Helpers

    /// Separable box mean, clamp-to-edge, `Double`.
    static func box(_ src: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: width * height)
        let n = Double(2 * radius + 1)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for d in -radius...radius {
                    sum += src[y * width + min(max(x + d, 0), width - 1)]
                }
                horizontal[y * width + x] = sum / n
            }
        }
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for d in -radius...radius {
                    sum += horizontal[min(max(y + d, 0), height - 1) * width + x]
                }
                out[y * width + x] = sum / n
            }
        }
        return out
    }

    /// `MTLSampler` bilinear + clamp-to-edge on a `width × height` plane, given
    /// normalised coordinates.
    static func bilinear(
        _ plane: [Double], width: Int, height: Int, u: Double, v: Double
    ) -> Double {
        let fx = u * Double(width) - 0.5
        let fy = v * Double(height) - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ x: Int, _ y: Int) -> Double {
            plane[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }
}
