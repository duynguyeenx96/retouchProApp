import CoreGraphics
import Foundation

@testable import RPEngine

/// A synthetic made-up face and a `Double` implementation of
/// `rp_makeup_composite` written from docs/ADR-0027. Same arrangement and same
/// honest limit as `HairReference`: it proves the shader computes the documented
/// formula on the documented pixels, not that the result looks like makeup.
enum MakeupReference {
    struct Fixture {
        var width: Int
        var height: Int
        var pixels: [Float]
        var face: FaceRenderInput
        /// Well inside the painted lips / brows (no feather reaches the edge).
        var lipsCore: [Bool]
        var browsCore: [Bool]
        /// A disc at each blush lobe's centre.
        var cheekProbe: [Bool]
        /// Four pixels or more outside the skin ellipse, which contains every
        /// mask and every lobe: nothing may change there.
        var outside: [Bool]
    }

    static let width = 384
    static let height = 448
    static let faceWidth: CGFloat = 180
    static let centre = CGPoint(x: 192, y: 210)

    static let skinTone = (0.80, 0.62, 0.52)
    static let lipTone = (0.74, 0.46, 0.46)
    static let browTone = (0.38, 0.28, 0.22)

    struct Ellipse {
        var centre: CGPoint
        var rx: CGFloat
        var ry: CGFloat
        func contains(_ p: CGPoint, inflatedBy d: CGFloat = 0) -> Bool {
            let a = (p.x - centre.x) / (rx + d)
            let b = (p.y - centre.y) / (ry + d)
            return a * a + b * b <= 1
        }
    }

    static func fixture() -> Fixture {
        let base = SyntheticFaceMesh.renderInput(width: faceWidth, centre: centre)
        let lm = base.landmarks
        let w = base.faceWidth
        let frame = FaceMeshFrame(landmarks: lm, faceWidth: w)!

        let mouthL = lm[FaceMesh.mouthCornerLeft]
        let mouthR = lm[FaceMesh.mouthCornerRight]
        let lips = Ellipse(
            centre: CGPoint(x: (mouthL.x + mouthR.x) / 2, y: (mouthL.y + mouthR.y) / 2),
            rx: abs(mouthL.x - mouthR.x) / 2, ry: 0.07 * w)
        func browAbove(_ a: Int, _ b: Int) -> Ellipse {
            let p = CGPoint(x: (lm[a].x + lm[b].x) / 2, y: (lm[a].y + lm[b].y) / 2)
            return Ellipse(
                centre: CGPoint(x: p.x - frame.down.dx * 0.12 * w, y: p.y - frame.down.dy * 0.12 * w),
                rx: 0.13 * w, ry: 0.035 * w)
        }
        let brows = [
            browAbove(FaceMesh.eyeOuterRight, FaceMesh.eyeInnerRight),
            browAbove(FaceMesh.eyeInnerLeft, FaceMesh.eyeOuterLeft),
        ]
        let top = lm[FaceMesh.foreheadTop]
        let chin = lm[FaceMesh.chin]
        let skin = Ellipse(
            centre: CGPoint(x: (top.x + chin.x) / 2, y: (top.y + chin.y) / 2),
            rx: 0.62 * w, ry: 0.62 * frame.length)

        func mask(_ inside: (CGPoint) -> Bool) -> RenderMask {
            var values = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width where inside(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    values[y * width + x] = 255
                }
            }
            return RenderMask(width: width, height: height, values: values, maskToImage: .identity)
        }
        var face = base
        face.masks[.lips] = mask { lips.contains($0) }
        face.masks[.brows] = mask { p in brows.contains { $0.contains(p) } }
        face.masks[.skin] = mask { skin.contains($0) }

        let lobes = BlushMask.lobes(faces: [face])
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var lipsCore = [Bool](repeating: false, count: width * height)
        var browsCore = [Bool](repeating: false, count: width * height)
        var cheekProbe = [Bool](repeating: false, count: width * height)
        var outside = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let i = y * width + x
                // A gentle vertical ramp, so no pixel sits at 0 or 1.
                let ramp = 0.92 + 0.16 * Double(y) / Double(height - 1)
                var c = skinTone
                if lips.contains(p) { c = lipTone }
                if brows.contains(where: { $0.contains(p) }) { c = browTone }
                pixels[i * 4] = Float(c.0 * ramp)
                pixels[i * 4 + 1] = Float(c.1 * ramp)
                pixels[i * 4 + 2] = Float(c.2 * ramp)
                pixels[i * 4 + 3] = 1
                lipsCore[i] = lips.contains(p, inflatedBy: -3)
                browsCore[i] = brows.contains { $0.contains(p, inflatedBy: -2) }
                cheekProbe[i] = lobes.contains {
                    hypot(p.x - CGFloat($0.centre.x), p.y - CGFloat($0.centre.y)) < 0.03 * w
                }
                outside[i] = !skin.contains(p, inflatedBy: 4)
            }
        }
        let quantised = SpikeTextureIO.float16ToFloat32(SpikeTextureIO.float32ToFloat16(pixels))
        return Fixture(
            width: width, height: height, pixels: quantised, face: face, lipsCore: lipsCore,
            browsCore: browsCore, cheekProbe: cheekProbe, outside: outside)
    }

    static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    static let lipstickStrength = 0.8
    static let lipLumaPull = 0.4
    static let blushStrength = 0.35
    static let browMinRatio = 0.25

    static func saturate(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// The whole frame, fed the node's own masks (0 where the node bound none)
    /// and its lobes. `hasLips` / `hasBrows` mirror the node forcing an amount to
    /// 0 when its mask is absent.
    static func composite(
        pixels: [Float], width: Int, height: Int, sliders: MakeupSliders,
        lips: [Double]?, brows: [Double]?, skin: [Double]?, lobes: [ContourLobe]
    ) -> [Float] {
        let lipstick = lips == nil ? 0 : sliders.lipstick / 100
        let blush = (skin == nil || lobes.isEmpty) ? 0 : sliders.blush / 100
        let browsExponent = brows == nil ? 1 : Double(Float(sliders.browsLumaExponent))
        let lip = MakeupSliders.lipTint(tone: sliders.lipTone)
        let lipTint = SIMD3(
            Double(Float(lip.normalised.x)), Double(Float(lip.normalised.y)),
            Double(Float(lip.normalised.z)))
        let lipLuma = Double(Float(lip.luma))
        let rose = MakeupSliders.blushTint

        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let o = i * 4
                let l = lips?[i] ?? 0
                let b = brows?[i] ?? 0
                var bm = 0.0
                if blush > 0 {
                    bm = max(ContourMask.value(at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), lobes: lobes), 0)
                        * (skin?[i] ?? 0)
                }
                let active = l * lipstick + b * abs(browsExponent - 1) + bm * blush
                guard active > 0 else { continue }
                var c = SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2]))
                if browsExponent != 1 && b > 0 {
                    let yy = max((c * luma).sum(), 0)
                    let ratio = yy > 1e-4 ? max(pow(yy, browsExponent) / yy, browMinRatio) : 1
                    c = c + (c * ratio - c) * b
                }
                if lipstick > 0 && l > 0 {
                    let yy = (c * luma).sum()
                    let yT = yy + (lipLuma - yy) * lipLumaPull
                    c = c + (lipTint * yT - c) * (lipstick * l * lipstickStrength)
                }
                if bm > 0 {
                    let yy = (c * luma).sum()
                    c = c + (rose * yy - c) * (blush * bm * blushStrength)
                }
                out[o] = Float(saturate(c.x))
                out[o + 1] = Float(saturate(c.y))
                out[o + 2] = Float(saturate(c.z))
            }
        }
        return out
    }

    static func mean(_ pixels: [Float], where include: [Bool], _ f: (SIMD3<Double>) -> Double)
        -> Double
    {
        var sum = 0.0
        var n = 0
        for i in include.indices where include[i] {
            let o = i * 4
            sum += f(SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])))
            n += 1
        }
        return n == 0 ? .nan : sum / Double(n)
    }
}
