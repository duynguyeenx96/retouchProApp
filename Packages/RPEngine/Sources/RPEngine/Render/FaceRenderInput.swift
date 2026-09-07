import CoreGraphics
import Foundation

/// A soft coverage map produced somewhere else (RPVision's face parsing today)
/// together with the affine that puts it back on the photo.
///
/// **This is the seam `docs/ADR-0007` promised**: "Phase 2's `RenderGraph` will
/// need … a plain value type between `FaceAnalysis` and the warp." RPEngine does
/// not import RPVision, so nothing here mentions `ParsedFace`, `CropRegion` or
/// Core ML. The shape is deliberately the *exact* shape RPVision already hands
/// out, so the adapter is a memberwise call and cannot get the geometry wrong:
///
/// ```swift
/// RenderMask(width:  parsed.mask.width,
///            height: parsed.mask.height,
///            values: parsed.feathered(.skin),      // ParsedFace.feathered, not hardMask
///            maskToImage: parsed.region.outputToImage)
/// ```
///
/// `values` is 0…255 coverage, row-major, row 0 at the top — the same convention
/// as `FaceParsingMask.labels` and as every texture in this package.
public struct RenderMask: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `width * height` bytes of coverage, 0 = outside, 255 = fully inside.
    public var values: [UInt8]
    /// Maps mask pixels (y down) to image pixels (y down).
    public var maskToImage: CGAffineTransform

    public init(width: Int, height: Int, values: [UInt8], maskToImage: CGAffineTransform) {
        precondition(values.count == width * height, "mask buffer size mismatch")
        self.width = width
        self.height = height
        self.values = values
        self.maskToImage = maskToImage
    }

    /// Image pixels → mask pixels. What the shader needs: it walks the
    /// destination and has to find the mask sample for each output pixel.
    public var imageToMask: CGAffineTransform { maskToImage.inverted() }

    /// The same mask against an image scaled by `scale`.
    ///
    /// A preview renders at 2048 px while `FaceAnalyzer` ran on the full frame,
    /// so this conversion happens on every preview. Only the *transform* moves —
    /// the 512² parsing mask is not resampled, because resampling it would throw
    /// away the sub-pixel geometry that the feather is there to preserve.
    public func scaled(by scale: CGFloat) -> RenderMask {
        RenderMask(
            width: width, height: height, values: values,
            maskToImage: maskToImage.concatenating(
                CGAffineTransform(scaleX: scale, y: scale)))
    }
}

/// Which region a ``RenderMask`` covers. Mirrors RPVision's `FaceParsingGroup`
/// by name so the adapter is a `switch` with no arithmetic in it.
///
/// There is **no `teeth` case, deliberately.** CelebAMask-HQ has no teeth class
/// (`mouth` is the mouth *interior*), so the "trắng răng" slider has to derive
/// teeth from luminance inside `mouth` — spike S2 §3c, `ParsedFace`'s doc
/// comment. Adding a `teeth` case here would let a later node quietly assume a
/// mask that nothing can produce.
public enum RenderMaskKind: String, Sendable, CaseIterable, Codable {
    case skin, hair, eyes, brows, lips, mouth, neck, nose, eyeglasses, ears
}

/// One face as the render graph sees it: geometry in image pixels, plus the
/// masks the nodes need.
public struct FaceRenderInput: Sendable, Equatable {
    /// The 478-point mesh in image pixels, y down (`AnalyzedFace.imagePoints`).
    /// Empty is legal — the Da group only needs the masks.
    public var landmarks: [CGPoint]
    /// Cheek-to-cheek distance in image pixels (`AnalyzedFace.faceWidth`).
    ///
    /// **Every length in the graph is expressed as a fraction of this.** That is
    /// what makes a preset transfer between images (docs/PLAN.md §2): a skin
    /// smoothing radius of "0.03 × face width" means the same thing on a
    /// head-and-shoulders frame and on a full-length one, and a radius in pixels
    /// does not.
    public var faceWidth: CGFloat
    public var masks: [RenderMaskKind: RenderMask]

    public init(
        landmarks: [CGPoint] = [], faceWidth: CGFloat,
        masks: [RenderMaskKind: RenderMask] = [:]
    ) {
        self.landmarks = landmarks
        self.faceWidth = faceWidth
        self.masks = masks
    }

    /// The same face against an image scaled by `scale`.
    public func scaled(by scale: CGFloat) -> FaceRenderInput {
        FaceRenderInput(
            landmarks: landmarks.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
            faceWidth: faceWidth * scale,
            masks: masks.mapValues { $0.scaled(by: scale) })
    }
}
