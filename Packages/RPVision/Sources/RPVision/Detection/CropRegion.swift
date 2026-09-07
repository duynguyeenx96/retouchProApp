import CoreGraphics
import Foundation

/// A rotated square region of an image resampled to an arbitrary square output.
///
/// `FaceCrop` (spike S1) is the same idea pinned to the 478-point model's 256 px
/// input — `FaceCrop.outputSide` is a constant, so it cannot describe the 128 px
/// BlazeFace input or the 512 px parsing input. `CropRegion` carries the output
/// side with it; `FaceCrop` converts both ways, and
/// `CropRegionRendererTests.matchesFaceCropRenderer` asserts that rendering a
/// `CropRegion` built from a `FaceCrop` produces byte-identical pixels to
/// `FaceCropRenderer`, so spike S1's calibration is not silently re-derived here.
///
/// Same convention as `FaceCrop`: **image pixels, origin top-left, y increasing
/// downwards**, rotation clockwise in that frame.
public struct CropRegion: Sendable, Equatable, Codable {
    public var center: CGPoint
    public var side: CGFloat
    public var rotation: CGFloat
    public var outputSide: Int

    public init(center: CGPoint, side: CGFloat, rotation: CGFloat, outputSide: Int) {
        self.center = center
        self.side = side
        self.rotation = rotation
        self.outputSide = outputSide
    }

    public init(_ crop: FaceCrop, outputSide: Int = Int(FaceCrop.outputSide)) {
        self.init(
            center: crop.center, side: crop.side, rotation: crop.rotation,
            outputSide: outputSide)
    }

    /// The same region as a `FaceCrop`, i.e. resampled to 256 px instead.
    public var faceCrop: FaceCrop {
        FaceCrop(center: center, side: side, rotation: rotation)
    }

    public var pixelsPerOutputPixel: CGFloat { side / CGFloat(outputSide) }

    /// Maps output space (0…outputSide, y down) to image space (y down).
    public var outputToImage: CGAffineTransform {
        let s = pixelsPerOutputPixel
        let half = CGFloat(outputSide) / 2
        return CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: rotation)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -half, y: -half)
    }

    public var imageToOutput: CGAffineTransform { outputToImage.inverted() }

    public func imagePoint(fromOutput point: CGPoint) -> CGPoint {
        point.applying(outputToImage)
    }

    public func outputPoint(fromImage point: CGPoint) -> CGPoint {
        point.applying(imageToOutput)
    }

    /// Maps a 0…1 coordinate inside the region (BlazeFace works in these) to image
    /// pixels. Independent of `outputSide`, which is why the detector decode uses it.
    public func imagePoint(fromNormalized point: CGPoint) -> CGPoint {
        let dx = (point.x - 0.5) * side
        let dy = (point.y - 0.5) * side
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }
}
