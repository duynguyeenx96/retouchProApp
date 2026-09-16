import CoreGraphics
import Foundation

/// Turns a decoded frame into the **whole-frame** skin ``RenderMask`` that
/// docs/PLAN.md §6.2 ("Sửa da" — đồng bộ da toàn thân) needs.
///
/// The face-parsing mask the "Da" sliders use today only exists inside a crop
/// around each face, so neck / shoulder / arm skin in the same frame keeps its
/// original texture and tone while the face is smoothed. This produces the other
/// half: coverage for *every* skin pixel in the frame, from ``SkinCore`` (the
/// port of `panelpts/RetouchProUXP/skincore.js`), which ``SkinRenderNode`` then
/// unions with the per-face mask.
///
/// ## Why the mask is small
/// The classifier runs on a ``Options/workingWidth``-wide grid (320 px by
/// default — skincore.js's `SMALL_W`, and the resolution `panelpts/research/
/// eval.js` scored), not on the full frame. Three reasons, in order:
///
/// 1. **It is what was measured.** The thresholds, the 2 % component floor and
///    the top-5 % normalisation were all tuned at that scale.
/// 2. Body skin is a *large region*. A 320 px grid over a 24 MP frame is one
///    sample per ~12 px, and the mask is bilinearly resampled by the same
///    `rp_skin_mask` pass that already resamples the 512² parsing crops — a
///    `RenderMask` is bytes + size + an affine, and nothing downstream cares how
///    big it is.
/// 3. Cost. 320×213 is 68 k pixels of `Double` CPU work per *image* (not per
///    frame — the mask is computed once and lives in the `RenderRequest`),
///    against 24 M.
///
/// The price is that the mask cannot follow a fine edge: a wisp of hair over a
/// shoulder is one sample wide and will be smoothed along with the skin. The
/// face — where fine edges matter most — is not affected, because the BiSeNet
/// mask stays authoritative there (see ``SkinRenderNode``'s union).
///
/// ## v2: the subject mask multiply (docs/ADR-0021 §v2)
/// Every `make` overload takes an optional `subject:` ``RenderMask`` — a
/// whole-frame person mask from ``SubjectMaskProviding`` — and multiplies it into
/// the coverage **here**, after ``SkinCore`` has run. It is deliberately not
/// inside `SkinCore.classify`: that type is the transcription of
/// `panelpts/RetouchProUXP/skincore.js` and stays pure CV with no subject prior
/// in it, exactly as its own doc comment reserves ("adding it later is a multiply
/// on `Result.coverage` and changes nothing else here").
///
/// What the multiply can and cannot do, stated plainly because the measurement
/// says so (`Research/bench/p6-skin-sync-macos.json`, `accuracy.tones[].v2`):
///
/// * It **removes false positives** — skin-coloured wood/rattan behind the
///   subject stops being reported as skin, which on the cluttered tone-IV frame
///   moves IoU 0.000 → 0.938.
/// * It **cannot add a pixel back.** A multiply is `coverage × subject`, so a
///   pixel the colour rule already scored 0 stays 0. Tone VI (91,60,17) is
///   rejected by ``SkinCore/skinScore(_:_:_:)``'s Kovac `R <= 95` line long
///   before this function is reached, so it is 0.000 IoU with and without a
///   subject mask. v2 does not fix deep skin tones and must never be described as
///   if it does.
public enum BodySkinMask {

    public struct Options: Sendable, Equatable {
        /// Long-edge-independent: the classifier grid is `workingWidth` across,
        /// with the height following the frame's aspect ratio.
        public var workingWidth: Int
        public var core: SkinCore.Options

        public init(workingWidth: Int = 320, core: SkinCore.Options = .default) {
            self.workingWidth = max(8, workingWidth)
            self.core = core
        }

        public static let `default` = Options()
    }

    public struct Result: Sendable, Equatable {
        /// Whole-frame coverage, with the affine that puts it back on the photo.
        /// Hand this to `RenderRequest.bodySkinMask` (scaled with
        /// `RenderMask.scaled(by:)` if the preview is not at full resolution,
        /// exactly like a face mask).
        public var mask: RenderMask
        public var stats: SkinCore.Stats
        /// Mean coverage over the frame, 0…1. A sanity number for the bench: a
        /// portrait is usually 0.05–0.35, and 0.9 means the classifier has
        /// latched onto the background.
        public var coverageFraction: Double
    }

    /// - Parameters:
    ///   - rgb: interleaved 8-bit **gamma-encoded sRGB**, row-major, row 0 at
    ///     the top. The same value space as `RenderQuality.pixelSpace`
    ///     (`.sRGBEncoded`) and as the panel this is ported from; the thresholds
    ///     are meaningless in linear light.
    ///   - subject: an optional whole-frame person mask **in the pixel
    ///     coordinates of this very frame** (`width` x `height`), i.e. the mask
    ///     ``SubjectMaskProviding`` returns for the same decoded image. Its own
    ///     resolution is free — Vision hands back 256x192 / 512x384 / 2016x1512
    ///     regardless of the frame's aspect ratio — because it is resampled
    ///     through its `maskToImage` affine onto the working grid.
    ///     `nil` means *no subject mask was asked for or none was found*, and is
    ///     **not** the same as an all-zero mask: with `nil` the coverage is
    ///     returned exactly as ``SkinCore`` produced it, which is the v1
    ///     behaviour byte for byte.
    public static func make(
        rgb: [UInt8], componentsPerPixel: Int, width: Int, height: Int,
        subject: RenderMask? = nil,
        options: Options = .default
    ) -> Result {
        precondition(width > 0 && height > 0)
        let workingWidth = min(options.workingWidth, width)
        let workingHeight = max(
            1, Int((Double(height) * Double(workingWidth) / Double(width)).rounded()))

        let small: [UInt8]
        let components: Int
        if workingWidth == width && workingHeight == height {
            small = rgb
            components = componentsPerPixel
        } else {
            small = SkinCore.areaDownRGB(
                rgb, componentsPerPixel: componentsPerPixel, width: width, height: height,
                targetWidth: workingWidth, targetHeight: workingHeight)
            components = 3
        }

        let classified = SkinCore.classify(
            rgb: small, componentsPerPixel: components, width: workingWidth,
            height: workingHeight, options: options.core)

        let workingToImage = CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(workingWidth),
            y: CGFloat(height) / CGFloat(workingHeight))
        var coverage = classified.coverage
        if let subject {
            coverage = intersect(
                coverage, width: workingWidth, height: workingHeight, with: subject,
                coverageToImage: workingToImage)
        }

        let mask = RenderMask(
            width: workingWidth, height: workingHeight, values: coverage,
            maskToImage: workingToImage)
        let sum = coverage.reduce(0) { $0 + Int($1) }
        return Result(
            mask: mask, stats: classified.stats,
            coverageFraction: Double(sum) / Double(coverage.count * 255))
    }

    // MARK: - The subject multiply

    /// `coverage × subject`, evaluated on the *coverage's* grid.
    ///
    /// The two masks are almost never the same size or even the same aspect
    /// ratio — the classifier works on a 320-px-wide grid that follows the
    /// frame's aspect, while `VNGeneratePersonSegmentationRequest` returns a
    /// fixed 4:3 (or 3:4) grid that it **stretches** the picture into (see
    /// `RPVision.PersonSegmenter`'s note on the non-uniform affine). So neither a
    /// pixel index nor a single scale factor can relate them: each working-grid
    /// pixel is taken to image pixels through `coverageToImage`, then to subject
    /// pixels through `subject.imageToMask`, and the subject is sampled there
    /// bilinearly.
    ///
    /// Conventions, both of which are pinned by tests because both are easy to
    /// get wrong by half a pixel:
    /// * A pixel's sample point is its **centre**, `(x + 0.5, y + 0.5)`, and the
    ///   subject texel whose centre lands at `u` is `u - 0.5`.
    /// * Outside the subject mask the nearest edge texel is used (clamp), not 0 —
    ///   Vision's mask covers the whole frame, so an out-of-range sample means a
    ///   rounding overshoot at the border, and treating that as "background"
    ///   would shave a row off the subject.
    static func intersect(
        _ coverage: [UInt8], width: Int, height: Int, with subject: RenderMask,
        coverageToImage: CGAffineTransform
    ) -> [UInt8] {
        guard subject.width > 0, subject.height > 0 else { return coverage }
        let toSubject = coverageToImage.concatenating(subject.imageToMask)
        var out = coverage
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard coverage[index] > 0 else { continue }
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    .applying(toSubject)
                let s = bilinear(subject, atTexelSpace: p)
                // Round half up, so a fully covered pixel under a saturated
                // subject mask stays exactly 255.
                out[index] = UInt8(clamping: (Int(coverage[index]) * Int(s.rounded()) + 127) / 255)
            }
        }
        return out
    }

    /// Bilinear sample of `mask` at a point in its own pixel space, clamped at
    /// the edges. Returns 0…255.
    private static func bilinear(_ mask: RenderMask, atTexelSpace point: CGPoint) -> Double {
        let u = Double(point.x) - 0.5
        let v = Double(point.y) - 0.5
        let x0 = Int(u.rounded(.down))
        let y0 = Int(v.rounded(.down))
        let fx = u - Double(x0)
        let fy = v - Double(y0)
        func sample(_ x: Int, _ y: Int) -> Double {
            let cx = min(max(x, 0), mask.width - 1)
            let cy = min(max(y, 0), mask.height - 1)
            return Double(mask.values[cy * mask.width + cx])
        }
        let top = sample(x0, y0) * (1 - fx) + sample(x0 + 1, y0) * fx
        let bottom = sample(x0, y0 + 1) * (1 - fx) + sample(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Same, from the interleaved float RGBA the rest of the engine passes
    /// around (`SpikeTextureIO.floatPixels`), 0…1 gamma-encoded sRGB.
    public static func make(
        floatRGBA pixels: [Float], width: Int, height: Int, subject: RenderMask? = nil,
        options: Options = .default
    ) -> Result {
        precondition(pixels.count >= width * height * 4)
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            for k in 0..<3 {
                let v = Double(pixels[i * 4 + k])
                bytes[i * 3 + k] = UInt8(clamping: SkinCore.jsRound(min(max(v, 0), 1) * 255))
            }
        }
        return make(
            rgb: bytes, componentsPerPixel: 3, width: width, height: height, subject: subject,
            options: options)
    }

    /// Same, straight from a decoded frame — the entry point the live canvas
    /// uses, once per shot.
    ///
    /// The image is drawn into an **8-bit sRGB** buffer at its own pixel size and
    /// handed to ``make(rgb:componentsPerPixel:width:height:subject:options:)``,
    /// which then does the `SkinCore.areaDownRGB` box-average down to the working
    /// grid. Going through 8 bits rather than `SpikeTextureIO.floatPixels` is
    /// deliberate on two counts: it is a quarter of the transient memory (11 MB
    /// instead of 45 MB for a 2048 px preview, and this runs on an iPhone), and
    /// the classifier's thresholds are 8-bit sRGB numbers in `skincore.js`, so a
    /// float round-trip would only add a quantisation step on the way in.
    ///
    /// **CPU work, once per image, not per frame** (17.8 ms at 2048 px, 90.1 ms
    /// at 24 MP — `Research/bench/p6-skin-sync-macos.json`). Call it off the main
    /// actor and cache the result in the `RenderRequest`.
    public static func make(
        image: CGImage, subject: RenderMask? = nil, options: Options = .default
    ) throws -> Result {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw SpikeTextureIO.Failure.cannotMakeBitmapContext }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return make(
            rgb: bytes, componentsPerPixel: 4, width: width, height: height, subject: subject,
            options: options)
    }
}
