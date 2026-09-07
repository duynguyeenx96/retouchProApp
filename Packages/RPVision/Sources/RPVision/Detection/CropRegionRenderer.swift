import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Resamples a `CropRegion` into a square BGRA buffer of `region.outputSide`.
///
/// Generalisation of `FaceCropRenderer` (spike S1), which is hard-wired to 256 px:
/// `FaceAnalyzer` needs 128 px (BlazeFace), 256 px (mesh) and 512 px (parsing) from
/// the same code. The transform maths is the same chain — flip into y-down, apply
/// `imageToOutput`, flip back — and `CropRegionRendererTests` pins the two
/// renderers to byte-identical output at 256 px so S1's measured numbers still
/// describe this path.
///
/// Core Image only, no UIKit/AppKit.
public final class CropRegionRenderer {
    private let context: CIContext
    private var pools: [Int: CVPixelBufferPool] = [:]

    public init(context: CIContext? = nil) {
        self.context = context ?? CIContext(options: [.cacheIntermediates: false])
    }

    /// Areas outside the source image come out black, matching MediaPipe's
    /// `ImageToTensorCalculator` with `border_mode: BORDER_ZERO`.
    public func render(_ image: CGImage, region: CropRegion) throws -> CVPixelBuffer {
        let side = region.outputSide
        let height = CGFloat(image.height)
        let source = CIImage(cgImage: image)

        let flipInput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        let transform = flipInput
            .concatenating(region.imageToOutput)
            .concatenating(flipOutput)

        let sampled = source
            .transformed(by: transform, highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let opaque = sampled.composited(
            over: CIImage(color: .black).cropped(
                to: CGRect(x: 0, y: 0, width: side, height: side)))

        let buffer = try makeBuffer(side: side)
        context.render(opaque, to: buffer)
        return buffer
    }

    private func makeBuffer(side: Int) throws -> CVPixelBuffer {
        let pool: CVPixelBufferPool
        if let existing = pools[side] {
            pool = existing
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else {
                throw FaceCropRendererError.pixelBufferPoolFailed(status)
            }
            pools[side] = created
            pool = created
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw FaceCropRendererError.pixelBufferAllocationFailed(status)
        }
        return buffer
    }
}
