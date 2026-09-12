import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import RPVision

/// Correctness for the "Khoá nền" subject mask (docs/PLAN.md §6.1).
///
/// `.serialized` for the same reason every other RPVision suite is:
/// `RPVisionFeatureFlags` is a process-global store, and this suite restores only
/// the one flag it sets (docs/ADR-0006's warning about `resetToDefaults()`).
/// `.serialized` alone is not enough, though — it does not order this suite
/// against `PersonSegmentationBenchTests`, which drives the same flag — so every
/// test here that touches the flag goes through ``RPVisionTestFlags``.
///
/// The alignment test needs the real a6300 frames and is skipped — not faked —
/// when they are absent.
@Suite("Phase 6 background lock — person segmentation", .serialized)
struct PersonSegmenterTests {

    @Test("Construction refuses while the feature flag is off")
    func flagGatesConstruction() throws {
        try RPVisionTestFlags.exclusive {
            RPVisionFeatureFlags.personSegmentation = false
            #expect(throws: RPVisionFeatureDisabled.self) { _ = try PersonSegmenter() }
        }
    }

    /// The mask buffer's row stride is not its width. Vision hands back a
    /// `CVPixelBuffer` whose `bytesPerRow` is padded to the hardware's alignment,
    /// and copying `width * height` bytes straight from the base address shears
    /// the mask diagonally — the kind of bug that looks like "the segmentation is
    /// slightly wrong" instead of like a memcpy mistake. This pins the row-by-row
    /// copy with a deliberately over-padded buffer.
    @Test("Unpacks a padded pixel buffer row by row")
    func unpacksPaddedRows() throws {
        let width = 13
        let height = 7
        let stride = width + 11
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: stride * height, alignment: 64)
        defer { bytes.deallocate() }
        let typed = bytes.bindMemory(to: UInt8.self, capacity: stride * height)
        for y in 0..<height {
            for x in 0..<stride {
                // Padding is a value the payload never takes, so it cannot pass
                // by accident.
                typed[y * stride + x] = x < width ? UInt8(y * width + x) : 0xEE
            }
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            nil, width, height, kCVPixelFormatType_OneComponent8, bytes, stride, nil, nil, nil,
            &buffer)
        let pixelBuffer = try #require(buffer, "CVPixelBufferCreateWithBytes failed \(status)")

        let mask = try #require(
            PersonSegmenter.mask(
                from: pixelBuffer, imageSize: CGSize(width: 130, height: 70), quality: .fast))

        #expect(mask.width == width)
        #expect(mask.height == height)
        #expect(mask.values.count == width * height)
        for y in 0..<height {
            for x in 0..<width {
                #expect(mask.values[y * width + x] == UInt8(y * width + x))
            }
        }
        // 130 x 70 image from a 13 x 7 mask: 10x in both axes, no translation.
        #expect(abs(mask.maskToImage.a - 10) < 1e-9)
        #expect(abs(mask.maskToImage.d - 10) < 1e-9)
        #expect(abs(mask.maskToImage.tx) < 1e-9)
        #expect(abs(mask.maskToImage.ty) < 1e-9)
    }

    /// **Regression for the non-uniform scale.** Vision does not return the mask
    /// at the input's aspect ratio — a 2048x1365 (3:2) frame comes back as
    /// 256x192 / 512x384 / 2016x1512, all 4:3 (see `PersonSegmenter.mask(from:)`).
    /// The obvious implementation, one scale factor from the long edge, is
    /// therefore wrong on the short axis by several percent of the frame, which is
    /// far too small to notice in a portrait and far too large to ship: at 1365 px
    /// tall it is tens of pixels of vertical slip, so the lock would cut across a
    /// chin.
    ///
    /// Synthetic on purpose: it pins *our* affine, not Vision's choice of grid.
    /// Asserting the grid would be asserting an OS implementation detail that a
    /// future revision may change — the real guard against that is
    /// ``maskAlignsWithDetectedFace``, which measures where the mask lands.
    @Test("A mask whose aspect ratio differs from the image scales per axis")
    func nonUniformAspectRatioMapsPerAxis() throws {
        // 4:3 mask, 3:2 image — exactly the shape mismatch measured on a6300
        // frames at `.balanced`.
        let maskWidth = 64
        let maskHeight = 48
        let imageSize = CGSize(width: 2048, height: 1365)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, maskWidth, maskHeight, kCVPixelFormatType_OneComponent8, nil, &buffer)
        let pixelBuffer = try #require(buffer, "CVPixelBufferCreate failed \(status)")
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let typed = base.bindMemory(to: UInt8.self, capacity: stride * maskHeight)
            for y in 0..<maskHeight {
                for x in 0..<stride { typed[y * stride + x] = 0 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let mask = try #require(
            PersonSegmenter.mask(from: pixelBuffer, imageSize: imageSize, quality: .balanced))

        let scaleX = mask.maskToImage.a
        let scaleY = mask.maskToImage.d
        #expect(abs(scaleX - imageSize.width / CGFloat(maskWidth)) < 1e-9)
        #expect(abs(scaleY - imageSize.height / CGFloat(maskHeight)) < 1e-9)
        // The two axes must not have been collapsed into one factor.
        #expect(abs(scaleX - scaleY) > 1, "scales collapsed to \(scaleX) / \(scaleY)")
        // No rotation or shear: the mask is a stretched copy, not a rotated one.
        #expect(abs(mask.maskToImage.b) < 1e-12)
        #expect(abs(mask.maskToImage.c) < 1e-12)

        // The mask's far corner has to land on the image's far corner. A single
        // long-edge scale would put it at (2048, 1024) — 341 px short.
        let farCorner = CGPoint(x: CGFloat(maskWidth), y: CGFloat(maskHeight))
            .applying(mask.maskToImage)
        #expect(abs(farCorner.x - imageSize.width) < 1e-6)
        #expect(abs(farCorner.y - imageSize.height) < 1e-6)

        // And the inverse has to bring the image's far corner back inside the mask.
        let backCorner = CGPoint(x: imageSize.width, y: imageSize.height)
            .applying(mask.imageToMask)
        #expect(abs(backCorner.x - CGFloat(maskWidth)) < 1e-6)
        #expect(abs(backCorner.y - CGFloat(maskHeight)) < 1e-6)
    }

    /// Runs `body`, and on a machine that cannot perform the request at all wraps
    /// it in `withKnownIssue` so the failure is *reported* rather than hidden.
    ///
    /// The iOS Simulator has no person-segmentation model and fails every
    /// `perform` with `com.apple.Vision 9 "Could not create inference context"`
    /// (see ``PersonSegmenter/unsupportedReason()``). `FaceAnalyzerTests` already
    /// handles the same Simulator limitation with `withKnownIssue`, and this is
    /// the same shape — except the condition is a runtime probe rather than
    /// `#if targetEnvironment(simulator)`, because "can this machine run the
    /// request" is a capability, not a compile-time fact, and a future OS that
    /// fixes the Simulator should quietly start running these for real.
    static func onlyWhereSupported(_ body: () throws -> Void) rethrows {
        guard let reason = PersonSegmenter.unsupportedReason() else {
            try body()
            return
        }
        withKnownIssue("person segmentation unavailable here — \(reason)") { try body() }
    }

    @Test("A frame with no person reports no subject")
    func noPersonIsNoSubject() throws {
        try Self.onlyWhereSupported {
            try RPVisionTestFlags.withPersonSegmentation {
                let image = try #require(
                    BackgroundLockFixtures.syntheticImage(width: 256, height: 192))
                let segmenter = try PersonSegmenter(quality: .balanced)
                let mask = try segmenter.mask(for: image)
                // Vision may answer "no observation" or "an observation that is
                // empty"; both mean the same thing to a caller and both are accepted
                // here. What is not accepted is a mask that calls the ramp a person.
                if let mask {
                    let coverage = mask.meanCoverage(
                        inImageRect: CGRect(x: 0, y: 0, width: 256, height: 192))
                    #expect(
                        coverage < 0.05, "synthetic ramp reported \(coverage) subject coverage")
                }
            }
        }
    }

    /// The mask has to sit on the photo the right way up. Vision's masks come back
    /// as a `CVPixelBuffer`, and a pixel buffer is exactly the kind of surface that
    /// is flipped relative to a `CGImage` half the time — so this measures coverage
    /// inside a **separately detected** face rectangle rather than assuming it.
    /// A vertically flipped mask puts near-zero coverage there.
    @Test("Subject coverage lands inside a detected face box")
    func maskAlignsWithDetectedFace() throws {
        let urls = BackgroundLockFixtures.imageURLs(limit: 3)
        try #require(
            !urls.isEmpty || BackgroundLockFixtures.imageDirectory == nil,
            "fixture directory exists but holds no JPEGs")
        guard !urls.isEmpty else { return }  // no Research/ in this checkout

        try Self.onlyWhereSupported {
            try RPVisionTestFlags.withPersonSegmentation {
                let segmenter = try PersonSegmenter(quality: .balanced)
                var checked = 0
                for url in urls {
                    guard let full = BackgroundLockFixtures.image(at: url),
                        let image = BackgroundLockFixtures.resized(full, longEdge: 2048),
                        let faceBox = try BackgroundLockFixtures.largestFaceBox(in: image),
                        let mask = try segmenter.mask(for: image)
                    else { continue }
                    let face = mask.meanCoverage(inImageRect: faceBox)
                    let corners = BackgroundLockFixtures.cornerRects(
                        width: image.width, height: image.height)
                    let cornerCoverage =
                        corners.map { mask.meanCoverage(inImageRect: $0) }.reduce(0, +)
                        / Double(corners.count)
                    #expect(face > 0.85, "\(url.lastPathComponent): face box coverage \(face)")
                    #expect(
                        face - cornerCoverage > 0.5,
                        "\(url.lastPathComponent): face \(face) vs corners \(cornerCoverage)")
                    checked += 1
                }
                #expect(checked > 0, "no fixture produced both a face box and a mask")
            }
        }
    }
}
