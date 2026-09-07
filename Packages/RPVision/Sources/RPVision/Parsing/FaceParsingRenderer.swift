import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Resamples any image into the square BGRA buffer the face-parsing model expects.
///
/// The upstream reference resizes the whole frame to 512x512 with a plain bilinear
/// filter and ignores aspect ratio (`vendor/test.py`: `img.resize((512, 512),
/// BILINEAR)`), and the model was trained on 1:1 CelebA-HQ crops. This keeps the
/// same "squash to square" behaviour so the Swift path and the Python reference
/// see the same geometry; Phase 2 will feed it a square face crop anyway.
///
/// Core Image only — no UIKit/AppKit, so it builds on macOS and iOS alike.
public final class FaceParsingRenderer {
    private let context: CIContext
    private let side: Int
    private var pool: CVPixelBufferPool?

    public init(context: CIContext? = nil, side: Int = FaceParsingModel.inputSide) {
        self.context = context ?? CIContext(options: [.cacheIntermediates: false])
        self.side = side
    }

    public func render(_ image: CGImage) throws -> CVPixelBuffer {
        let source = CIImage(cgImage: image)
        let scaleX = CGFloat(side) / CGFloat(image.width)
        let scaleY = CGFloat(side) / CGFloat(image.height)
        let scaled = source
            .transformed(
                by: CGAffineTransform(scaleX: scaleX, y: scaleY),
                highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let opaque = scaled.composited(
            over: CIImage(color: .black)
                .cropped(to: CGRect(x: 0, y: 0, width: side, height: side)))

        let buffer = try makeBuffer()
        context.render(opaque, to: buffer)
        return buffer
    }

    private func makeBuffer() throws -> CVPixelBuffer {
        if pool == nil {
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
            pool = created
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw FaceCropRendererError.pixelBufferAllocationFailed(status)
        }
        return buffer
    }
}
