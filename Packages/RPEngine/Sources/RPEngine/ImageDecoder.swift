import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode-only ImageIO front end. **No edits are applied here and none will
/// be** — this exists so Phase 1's UI can put pixels on screen before the
/// Phase 2 `RenderGraph` exists.
///
/// Phase 2 replaces the RAW path with `CIRAWFilter` (docs/PLAN.md §1.4 /
/// spike S4); ImageIO decodes an ARW today by handing back the camera's
/// embedded preview, which is fine for a filmstrip thumbnail and honest for a
/// canvas placeholder, but is not a RAW development.
public enum ImageDecoder {
    /// Decodes `url` with its longest edge at most `maxPixelSize`, applying the
    /// EXIF orientation.
    ///
    /// Uses `CGImageSourceCreateThumbnailAtIndex`, which reads only as much of
    /// the file as it needs: for a 24 MP ARW it returns the embedded JPEG
    /// preview instead of decoding the mosaic.
    public static func decode(contentsOf url: URL, maxPixelSize: Int) throws -> PreviewImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RPEngineError.cannotOpenImage(path: url.path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw RPEngineError.cannotDecodeImage(path: url.path)
        }
        return PreviewImage(cgImage: image, sourcePixelSize: pixelSize(of: source))
    }

    /// Full-resolution pixel size read from the file header, orientation
    /// applied. `nil` when the file is not readable as an image.
    public static func pixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }

        // EXIF orientations 5–8 swap the axes.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
