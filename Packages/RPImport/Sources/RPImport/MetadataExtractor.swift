import Foundation
import ImageIO
import RPCore

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// Reads `CaptureMetadata` out of an image file.
///
/// A protocol, not a free function, so tests can inject a deterministic
/// extractor and so a later phase can swap in `CIRAWFilter`'s richer RAW
/// metadata without touching the importers.
public protocol CaptureMetadataExtracting: Sendable {
    /// Never throws: metadata is a nice-to-have. A file whose EXIF cannot be
    /// read is still a perfectly good import, so failures collapse to an empty
    /// ``CaptureMetadata``.
    func metadata(forFileAt url: URL) -> CaptureMetadata
}

/// A no-op extractor. Used by tests, and by callers that want import to do the
/// minimum I/O possible.
public struct NullMetadataExtractor: CaptureMetadataExtracting {
    public init() {}
    public func metadata(forFileAt url: URL) -> CaptureMetadata { CaptureMetadata() }
}

/// EXIF/TIFF metadata via ImageIO.
///
/// ImageIO is available identically on macOS and iOS and reads Sony ARW, so one
/// implementation covers both platforms and both of the plan's file types.
/// It parses headers only — it never decodes pixels — so the cost is a few
/// milliseconds even for a 24 MP RAW.
public struct ImageIOMetadataExtractor: CaptureMetadataExtracting {
    public init() {}

    public func metadata(forFileAt url: URL) -> CaptureMetadata {
        // kCGImageSourceShouldCache = false: we want the header, not the image.
        let sourceOptions =
            [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                as? [CFString: Any]
        else {
            return CaptureMetadata()
        }
        return Self.metadata(fromImageProperties: properties)
    }

    /// Split out from the file read so it can be unit-tested with a literal
    /// dictionary, with no image file involved.
    public static func metadata(fromImageProperties properties: [CFString: Any]) -> CaptureMetadata
    {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var metadata = CaptureMetadata()
        metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        metadata.orientation = properties[kCGImagePropertyOrientation] as? Int
            ?? tiff[kCGImagePropertyTIFFOrientation] as? Int

        metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?
            .trimmingCharacters(in: .whitespaces).nonEmpty
        metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespaces).nonEmpty
        metadata.lens = (exif[kCGImagePropertyExifLensModel] as? String)?
            .trimmingCharacters(in: .whitespaces).nonEmpty

        metadata.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        metadata.shutterSpeedSeconds = exif[kCGImagePropertyExifExposureTime] as? Double
        metadata.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        metadata.focalLengthMillimetres = exif[kCGImagePropertyExifFocalLength] as? Double

        // EXIF has no time zone. DateTimeOriginal is local wall-clock time at
        // the camera; parsing it in the current time zone is the same choice
        // Photos and Lightroom make, and is the only one available without the
        // OffsetTimeOriginal tag (which the a6300 does not write).
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            metadata.capturedAt = Self.exifDateFormatter.date(from: original)
        }
        if metadata.capturedAt == nil,
            let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String
        {
            metadata.capturedAt = Self.exifDateFormatter.date(from: digitized)
        }
        return metadata
    }

    /// EXIF `DateTimeOriginal` is `"yyyy:MM:dd HH:mm:ss"` — colons in the date.
    static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
