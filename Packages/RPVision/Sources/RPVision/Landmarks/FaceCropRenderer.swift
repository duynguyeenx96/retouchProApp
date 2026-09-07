import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Resamples a rotated square face region into the 256x256 BGRA buffer the
/// landmark model expects. Core Image only — no UIKit/AppKit, so this builds on
/// macOS and iOS alike.
public final class FaceCropRenderer {
    private let context: CIContext
    private let side: Int
    private var pool: CVPixelBufferPool?

    public init(context: CIContext? = nil, side: Int = Int(FaceCrop.outputSide)) {
        self.context = context ?? CIContext(options: [.cacheIntermediates: false])
        self.side = side
    }

    /// Renders `crop` out of `image` into a fresh 32BGRA pixel buffer.
    ///
    /// Areas outside the source image come out black, matching MediaPipe's
    /// `ImageToTensorCalculator` with a zero border.
    public func render(_ image: CGImage, crop: FaceCrop) throws -> CVPixelBuffer {
        let height = CGFloat(image.height)
        let source = CIImage(cgImage: image)

        // Core Image works y-up; FaceCrop is y-down. Flip in, map, flip out.
        let flipInput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let flipOutput = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        // sourceCI -> sourceYDown -> cropYDown -> cropCI
        let transform = flipInput
            .concatenating(crop.imageToCrop)
            .concatenating(flipOutput)

        let sampled = source
            .transformed(by: transform, highQualityDownsample: true)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let opaque = sampled.composited(over: CIImage(color: .black)
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

public enum FaceCropRendererError: Error, CustomStringConvertible {
    case pixelBufferPoolFailed(CVReturn)
    case pixelBufferAllocationFailed(CVReturn)

    public var description: String {
        switch self {
        case .pixelBufferPoolFailed(let s): "CVPixelBufferPoolCreate failed (\(s))"
        case .pixelBufferAllocationFailed(let s): "CVPixelBufferPoolCreatePixelBuffer failed (\(s))"
        }
    }
}
