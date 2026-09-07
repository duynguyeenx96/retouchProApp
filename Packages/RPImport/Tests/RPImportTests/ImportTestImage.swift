import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a tiny JPEG with real EXIF/TIFF tags, so the metadata tests exercise
/// `CGImageSource` rather than only the dictionary-mapping function.
enum ImportTestImage {
    @discardableResult
    static func writeJPEG(
        to url: URL,
        width: Int = 2,
        height: Int = 2,
        make: String,
        model: String,
        iso: Int
    ) -> Bool {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return false }
        context.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return false }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model,
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [iso]
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
