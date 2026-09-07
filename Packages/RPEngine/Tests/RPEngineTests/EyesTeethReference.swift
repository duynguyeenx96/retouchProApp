import CoreGraphics
import Foundation

@testable import RPEngine

/// A `Double`-precision, CPU-only reference for the whole "Mắt / Răng" render
/// node, plus the synthetic portrait fixture the selectivity numbers are
/// measured on.
///
/// The control for this group's golden tests, in the same arrangement as
/// `SkinReference` (the "Da" group) and `SpikeS3Support.referenceGuidedFilter`
/// (spike S3): written from `EyesTeethRenderNode`'s and
/// `EyesTeethShaders.metal`'s **documented specification** — the step order, the
/// weight formula, the named constants — rather than transcribed from the
/// shader.
///
/// ### What that independence does and does not prove
/// It is a different language, a different precision and a different author's
/// pass over the same specification, so it catches a transcription error: a
/// swapped channel, a `min` for a `max`, a missing `saturate`, a knee used in
/// the wrong term. It does **not** catch a wrong specification: if the documented
/// formula is a bad way to find teeth, both implementations agree and both are
/// wrong. That is what the selectivity measurement below is for, and it is a
/// separate claim from the PSNR.
///
/// The local-mean layer reuses `SkinReference.fastGuidedFilter`, which is
/// already an independent implementation of He & Sun 2015 written for the "Da"
/// group. Reusing it is deliberate: this node runs *the same kernel with the same
/// ε = 1e6*, so a second copy would only be a second chance to typo the paper.
enum EyesTeethReference {

    // MARK: - Fixture

    /// Parsing-crop side. Small enough to reason about by hand, large enough that
    /// a feathered edge has somewhere to ramp.
    static let maskSide = 64
    /// Cheek-to-cheek distance the fixture claims, in image pixels.
    ///
    /// Not arbitrary: the fixture's eye opening is 64 image pixels wide and a real
    /// eye is roughly 0.22 × face width, so 290 is the face this eye belongs to.
    /// It sets the local-mean radius (`0.050 × 290 = 15 px`), and a fixture that
    /// lied about it would price the blur at the wrong scale.
    static let faceWidth: CGFloat = 290

    /// A synthetic portrait region: skin, two eyes (sclera + iris + pupil) and an
    /// open mouth (teeth + gums), painted in **mask space** and mapped into the
    /// image through the same affine the masks use — so the pixels and the masks
    /// cannot drift apart.
    ///
    /// Colours are gamma-encoded sRGB (`RenderQuality.pixelSpace`), picked to be
    /// what the heuristic has to separate:
    ///
    /// | region | colour | why |
    /// |---|---|---|
    /// | skin | 0.72, 0.56, 0.48 | mid, warm |
    /// | sclera | 0.86, 0.85, 0.83 | bright, near-neutral |
    /// | iris | 0.24, 0.28, 0.36 | dark, bluish |
    /// | pupil | 0.05, 0.05, 0.06 | near black |
    /// | teeth | 0.80, 0.78, 0.70 | bright, faintly yellow — sat ≈ 0.125 |
    /// | gums | 0.62, 0.30, 0.30 | darker, strongly red — sat ≈ 0.516 |
    struct Portrait {
        var width: Int
        var height: Int
        /// Interleaved RGBA, already quantised to half-float (the GPU reads an
        /// rgba16Float source, so a reference starting from unquantised values
        /// would be charged 5e-4 of upload rounding the kernel did not cause).
        var pixels: [Float]
        var face: FaceRenderInput
        /// Per-image-pixel region labels, for the selectivity measurement.
        var regions: [Region]

        enum Region: UInt8 { case outside, skin, sclera, iris, pupil, teeth, gums }
    }

    /// Ellipse geometry in mask space. One description, used to paint the image,
    /// to build the masks and to label the regions.
    private static let leftEye = (cx: 20.0, cy: 24.0, rx: 8.0, ry: 5.0)
    private static let rightEye = (cx: 44.0, cy: 24.0, rx: 8.0, ry: 5.0)
    private static let irisRadius = 3.6
    private static let pupilRadius = 1.5
    private static let mouth = (cx: 32.0, cy: 44.0, rx: 11.0, ry: 5.0)
    /// Half-height of the teeth band inside the mouth ellipse. The rest of the
    /// interior is gums — which is the whole point: a slider that whitened the
    /// mouth mask uniformly would brighten those too.
    private static let teethHalfHeight = 2.6

    static func portrait(width: Int = 320, height: Int = 240) -> Portrait {
        let side = 256.0
        let scale = side / Double(maskSide)
        let maskToImage = CGAffineTransform.identity
            .translatedBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -CGFloat(maskSide) / 2, y: -CGFloat(maskSide) / 2)
        let imageToMask = maskToImage.inverted()

        var pixels = [Float](repeating: 0, count: width * height * 4)
        var regions = [Portrait.Region](repeating: .outside, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(imageToMask)
                let region = self.region(atMaskX: Double(p.x), y: Double(p.y))
                regions[y * width + x] = region
                let c = colour(of: region)
                let o = (y * width + x) * 4
                pixels[o] = Float(c.0)
                pixels[o + 1] = Float(c.1)
                pixels[o + 2] = Float(c.2)
                pixels[o + 3] = 1
            }
        }
        // A flat fixture would let a wrong local mean pass, because "brighter
        // than the neighbourhood" is trivially satisfied by a step edge. A gentle
        // luminance gradient across the frame makes the local mean actually
        // matter without changing which region a pixel belongs to.
        for y in 0..<height {
            for x in 0..<width {
                let g = 0.90 + 0.20 * (Double(x) / Double(width))
                let o = (y * width + x) * 4
                for channel in 0..<3 {
                    pixels[o + channel] = Float(min(1.0, Double(pixels[o + channel]) * g))
                }
            }
        }
        let quantised = SpikeTextureIO.float16ToFloat32(
            SpikeTextureIO.float32ToFloat16(pixels))

        let face = FaceRenderInput(
            faceWidth: faceWidth,
            masks: [
                .eyes: RenderMask(
                    width: maskSide, height: maskSide, values: eyeCoverage(),
                    maskToImage: maskToImage),
                .mouth: RenderMask(
                    width: maskSide, height: maskSide, values: mouthCoverage(),
                    maskToImage: maskToImage),
            ])
        return Portrait(
            width: width, height: height, pixels: quantised, face: face, regions: regions)
    }

    private static func region(atMaskX x: Double, y: Double) -> Portrait.Region {
        guard x >= 0, y >= 0, x < Double(maskSide), y < Double(maskSide) else { return .outside }
        for eye in [leftEye, rightEye] {
            let dx = (x - eye.cx) / eye.rx
            let dy = (y - eye.cy) / eye.ry
            if dx * dx + dy * dy <= 1 {
                let r = hypot(x - eye.cx, y - eye.cy)
                if r <= pupilRadius { return .pupil }
                if r <= irisRadius { return .iris }
                return .sclera
            }
        }
        let mx = (x - mouth.cx) / mouth.rx
        let my = (y - mouth.cy) / mouth.ry
        if mx * mx + my * my <= 1 {
            return abs(y - mouth.cy) <= teethHalfHeight ? .teeth : .gums
        }
        return .skin
    }

    private static func colour(of region: Portrait.Region) -> (Double, Double, Double) {
        switch region {
        case .outside, .skin: (0.72, 0.56, 0.48)
        case .sclera: (0.86, 0.85, 0.83)
        case .iris: (0.24, 0.28, 0.36)
        case .pupil: (0.05, 0.05, 0.06)
        case .teeth: (0.80, 0.78, 0.70)
        case .gums: (0.62, 0.30, 0.30)
        }
    }

    /// Feathered coverage of both eye openings, 0…255 — the shape
    /// `ParsedFace.feathered(.eyes)` produces, which is what the bridge is
    /// required to pass (spike S2 §4). A hard mask is deliberately *not* what
    /// this fixture provides.
    /// - Parameter side: crop size in pixels. The geometry scales with it, so
    ///   `side: 512` is the same face drawn at the size a real
    ///   `ParsedFace.mask` comes in — which is what the bench uses.
    static func eyeCoverage(side: Int = maskSide) -> [UInt8] {
        let k = Double(side) / Double(maskSide)
        return coverage(side: side) { x, y in
            var v = 0.0
            for eye in [leftEye, rightEye] {
                v = max(
                    v,
                    ellipse(
                        x: x, y: y, cx: eye.cx * k, cy: eye.cy * k, rx: eye.rx * k,
                        ry: eye.ry * k))
            }
            return v
        }
    }

    /// Feathered coverage of the mouth **interior**.
    static func mouthCoverage(side: Int = maskSide) -> [UInt8] {
        let k = Double(side) / Double(maskSide)
        return coverage(side: side) { x, y in
            ellipse(
                x: x, y: y, cx: mouth.cx * k, cy: mouth.cy * k, rx: mouth.rx * k,
                ry: mouth.ry * k)
        }
    }

    private static func coverage(side: Int, _ body: (Double, Double) -> Double) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let v = body(Double(x) + 0.5, Double(y) + 0.5)
                values[y * side + x] = UInt8((min(max(v, 0), 1) * 255).rounded())
            }
        }
        return values
    }

    /// 1 inside, ramping to 0 over the outermost ~1.2 mask pixels — the same
    /// shape a two-pass box feather of radius 3 leaves on an object this size.
    private static func ellipse(
        x: Double, y: Double, cx: Double, cy: Double, rx: Double, ry: Double
    ) -> Double {
        let dx = (x - cx) / rx
        let dy = (y - cy) / ry
        let r = sqrt(dx * dx + dy * dy)
        return min(max((1.15 - r) / 0.30, 0), 1)
    }

    // MARK: - Mask rasterisation

    /// Full-resolution coverage in 0…1 for one kind, the reference for
    /// `rp_skin_mask` as driven by `MaskRasteriser`.
    static func rasterisedMask(
        faces: [FaceRenderInput], kind: RenderMaskKind, width: Int, height: Int
    ) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for mask in faces.compactMap({ $0.masks[kind] }) {
            let t = mask.imageToMask
            let source = mask.values.map { Double($0) / 255.0 }
            for y in 0..<height {
                for x in 0..<width {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(t)
                    guard p.x >= 0, p.y >= 0, p.x < CGFloat(mask.width), p.y < CGFloat(mask.height)
                    else { continue }
                    let v = SkinReference.bilinear(
                        source, width: mask.width, height: mask.height,
                        u: Double(p.x) / Double(mask.width),
                        v: Double(p.y) / Double(mask.height))
                    out[y * width + x] = max(out[y * width + x], v)
                }
            }
        }
        return out
    }

    // MARK: - Composite

    struct Amounts {
        var eyeBrighten = 0.0, eyeDefinition = 0.0, scleraWhiten = 0.0, teethWhiten = 0.0

        init(_ sliders: EyesTeethSliders) {
            eyeBrighten = sliders.eyeBrighten / 100
            eyeDefinition = sliders.eyeDefinition / 100
            scleraWhiten = sliders.scleraWhiten / 100
            teethWhiten = sliders.teethWhiten / 100
        }
    }

    static let brightenGamma = 0.86
    static let definitionGain = 1.0
    static let whitenLumaKnee = 0.06
    static let scleraSatKnee = 0.60
    static let teethSatKnee = 0.40
    static let whitenChroma = 0.85
    static let whitenLift = 0.10

    static func whitenWeight(
        _ c: (Double, Double, Double), _ L: (Double, Double, Double), satKnee: Double
    ) -> Double {
        let lift = clamp01((luma(c) - luma(L)) / whitenLumaKnee)
        let hi = max(c.0, max(c.1, c.2))
        let lo = min(c.0, min(c.1, c.2))
        let sat = (hi - lo) / max(hi, 1e-4)
        return lift * clamp01(1 - sat / satKnee)
    }

    static func whiten(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let g = luma(c)
        let w = mix(c, (g, g, g), whitenChroma)
        return (
            w.0 + (1 - w.0) * whitenLift, w.1 + (1 - w.1) * whitenLift,
            w.2 + (1 - w.2) * whitenLift
        )
    }

    /// `rp_eyes_teeth_composite` in `Double`. `source` and `low` are interleaved
    /// RGBA; `eye` and `mouth` are one plane each in 0…1. Returns interleaved
    /// RGBA.
    static func composite(
        source: [Float], low: [Float], eye: [Double], mouth: [Double], amounts a: Amounts
    ) -> [Float] {
        var out = source
        for i in 0..<eye.count {
            let o = i * 4
            let e = eye[i]
            let t = mouth[i]
            let active =
                e * (a.eyeBrighten + a.eyeDefinition + a.scleraWhiten) + t * a.teethWhiten
            guard active > 0 else { continue }

            var c = (Double(source[o]), Double(source[o + 1]), Double(source[o + 2]))
            let L = (Double(low[o]), Double(low[o + 1]), Double(low[o + 2]))

            // 1. Sáng mắt
            c = mix(
                c,
                (
                    pow(max(c.0, 0), brightenGamma), pow(max(c.1, 0), brightenGamma),
                    pow(max(c.2, 0), brightenGamma)
                ), a.eyeBrighten * e)

            // 2. Nét mắt
            let gain = a.eyeDefinition * e * definitionGain
            c = (c.0 + (c.0 - L.0) * gain, c.1 + (c.1 - L.1) * gain, c.2 + (c.2 - L.2) * gain)

            // 3. Trắng lòng trắng
            c = mix(c, whiten(c), a.scleraWhiten * e * whitenWeight(c, L, satKnee: scleraSatKnee))

            // 4. Trắng răng
            c = mix(c, whiten(c), a.teethWhiten * t * whitenWeight(c, L, satKnee: teethSatKnee))

            out[o] = Float(clamp01(c.0))
            out[o + 1] = Float(clamp01(c.1))
            out[o + 2] = Float(clamp01(c.2))
        }
        return out
    }

    /// The whole node in `Double`: both masks, the local-mean layer, composite.
    static func renderNode(
        source: [Float], width: Int, height: Int, faces: [FaceRenderInput],
        sliders: EyesTeethSliders, subsample: Int
    ) -> [Float] {
        let eye =
            sliders.needsEyeMask
            ? rasterisedMask(faces: faces, kind: .eyes, width: width, height: height)
            : [Double](repeating: 0, count: width * height)
        let mouth =
            sliders.needsMouthMask
            ? rasterisedMask(faces: faces, kind: .mouth, width: width, height: height)
            : [Double](repeating: 0, count: width * height)

        var low = source
        if sliders.needsLocalMeanLayer {
            let faceWidth = faces.map(\.faceWidth).max() ?? 0
            let radius = EyesTeethRenderNode.localMeanRadius(faceWidth: faceWidth)
            for channel in 0..<3 {
                let plane = SpikeS3Support.channel(source, channel)
                let filtered = SkinReference.fastGuidedFilter(
                    plane, width: width, height: height, radius: radius,
                    epsilon: Double(EyesTeethRenderNode.localMeanEpsilon), subsample: subsample)
                for i in 0..<filtered.count { low[i * 4 + channel] = Float(filtered[i]) }
            }
        }
        return composite(
            source: source, low: low, eye: eye, mouth: mouth, amounts: Amounts(sliders))
    }

    // MARK: - Helpers

    static let lumaWeights = (r: 0.2126, g: 0.7152, b: 0.0722)

    static func luma(_ c: (Double, Double, Double)) -> Double {
        c.0 * lumaWeights.r + c.1 * lumaWeights.g + c.2 * lumaWeights.b
    }

    static func mix(
        _ x: (Double, Double, Double), _ y: (Double, Double, Double), _ t: Double
    ) -> (Double, Double, Double) {
        (x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t)
    }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    // MARK: - Selectivity

    /// Mean absolute RGB change over the pixels of one region.
    ///
    /// This is the number that answers the question a PSNR cannot: *did the
    /// slider move the pixels it claims to move?* PSNR against the reference only
    /// says the GPU computed the documented formula.
    static func meanChange(
        _ before: [Float], _ after: [Float], regions: [Portrait.Region],
        _ region: Portrait.Region
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
}
