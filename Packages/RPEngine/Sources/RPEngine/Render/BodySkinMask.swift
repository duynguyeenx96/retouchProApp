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
    public static func make(
        rgb: [UInt8], componentsPerPixel: Int, width: Int, height: Int,
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

        let mask = RenderMask(
            width: workingWidth, height: workingHeight, values: classified.coverage,
            maskToImage: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(workingWidth),
                y: CGFloat(height) / CGFloat(workingHeight)))
        let sum = classified.coverage.reduce(0) { $0 + Int($1) }
        return Result(
            mask: mask, stats: classified.stats,
            coverageFraction: Double(sum) / Double(classified.coverage.count * 255))
    }

    /// Same, from the interleaved float RGBA the rest of the engine passes
    /// around (`SpikeTextureIO.floatPixels`), 0…1 gamma-encoded sRGB.
    public static func make(
        floatRGBA pixels: [Float], width: Int, height: Int, options: Options = .default
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
            rgb: bytes, componentsPerPixel: 3, width: width, height: height, options: options)
    }
}
