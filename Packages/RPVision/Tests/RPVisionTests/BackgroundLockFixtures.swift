import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Real a6300 frames for the "Khoá nền" (background lock) suites, plus the two
/// helpers both the correctness test and the bench need.
///
/// The frames are the same sips-decoded 24 MP JPEGs every other bench in this
/// repo uses (`Research/spikes/S3-guided-filter-mls/images/full/`, the
/// gitignored decodes of `Research/data/*.ARW`). They are located from
/// `#filePath` exactly as `Phase2Resources` and `SpikeS2Resources` do, so a
/// checkout without `Research/` skips these tests instead of failing.
enum BackgroundLockFixtures {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RPVisionTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RPVision
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    static var imageDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment["RP_BGLOCK_IMAGES"] {
            return URL(fileURLWithPath: override)
        }
        let url = repoRoot.appendingPathComponent(
            "Research/spikes/S3-guided-filter-mls/images/full")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return url
    }

    /// Up to `limit` frames, sorted, so a run is reproducible.
    static func imageURLs(limit: Int) -> [URL] {
        guard let directory = imageDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return
            names
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .sorted()
            .prefix(limit)
            .map { directory.appendingPathComponent($0) }
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `image` redrawn so its long edge is `longEdge` px, or unchanged when it is
    /// already smaller.
    ///
    /// The preview path renders at 2048 px (docs/PLAN.md §3), so that is the size
    /// the interactive number has to be measured at; measuring only the 24 MP
    /// frame would report a cost the user never pays while dragging.
    static func resized(_ image: CGImage, longEdge: Int) -> CGImage? {
        let scale = CGFloat(longEdge) / CGFloat(max(image.width, image.height))
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A deterministic synthetic frame with no person in it: a diagonal ramp plus
    /// a hard step. Used to check that "no subject" is reported as such.
    static func syntheticImage(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                let ramp = CGFloat(x + y) / CGFloat(width + height)
                let step: CGFloat = x > width / 2 ? 0.25 : 0
                context.setFillColor(
                    red: min(1, ramp + step), green: min(1, ramp * 0.8), blue: 0.4, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }

    /// The largest face Vision finds, in **image pixels with y down**, or `nil`.
    ///
    /// `VNDetectFaceRectanglesRequest` is used and not the project's BlazeFace
    /// path on purpose: this is a check on the *segmentation* mask, so the
    /// reference box has to come from somewhere the mask does not, and a built-in
    /// Vision request needs none of the converted Core ML models (which is also
    /// what lets this run on a checkout without them).
    static func largestFaceBox(in image: CGImage) throws -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let best = (request.results ?? []).max(by: { $0.confidence < $1.confidence })
        else { return nil }
        let box = best.boundingBox  // normalised, origin bottom-left
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return CGRect(
            x: box.minX * width, y: (1 - box.maxY) * height,
            width: box.width * width, height: box.height * height)
    }

    /// The four corner patches, each `fraction` of the frame on a side. Stand-ins
    /// for "definitely background" in a portrait; reported rather than asserted
    /// per-corner, because a full-length frame can legitimately put an elbow in
    /// one of them.
    static func cornerRects(width: Int, height: Int, fraction: CGFloat = 0.06) -> [CGRect] {
        let w = CGFloat(width) * fraction
        let h = CGFloat(height) * fraction
        return [
            CGRect(x: 0, y: 0, width: w, height: h),
            CGRect(x: CGFloat(width) - w, y: 0, width: w, height: h),
            CGRect(x: 0, y: CGFloat(height) - h, width: w, height: h),
            CGRect(x: CGFloat(width) - w, y: CGFloat(height) - h, width: w, height: h),
        ]
    }
}
