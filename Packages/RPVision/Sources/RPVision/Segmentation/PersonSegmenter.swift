import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// How hard Vision works on the subject mask.
///
/// Mirrors `VNGeneratePersonSegmentationRequest.QualityLevel` by name so the
/// mapping is a `switch` with nothing to get wrong, and exists separately so
/// nothing above RPVision has to import Vision to name a quality.
///
/// Apple's guidance is `.fast` for interactive/streaming work and `.accurate`
/// only where the latency is affordable. The plan (docs/PLAN.md §6.1, "Khoá
/// nền") says the same thing and adds the rule this project applies everywhere:
/// no default until there is a measurement. `Scripts/bench-background-lock.sh`
/// produces it — `Research/bench/p6-background-lock-*.json`.
///
/// ### What the measurement says (Mac host, 2048 px preview, Release)
/// Median per request: `.fast` 5.5 ms, `.balanced` 17.2 ms, `.accurate` 54.5 ms
/// (24 MP full frame: 88 / 127 / 185 ms) — but the mask resolutions are 256x192,
/// 512x384 and 2016x1512, and that is the part the timing hides. Mean coverage
/// inside a separately detected face box came back at 0.90 for `.fast` (as low as
/// 0.71 on one frame), against 0.997 for `.balanced` and 0.998 for `.accurate`,
/// with ~0 in the frame corners for all three. So `.fast` is not "the same mask,
/// sooner": at a 2048 px preview its 256 px mask is roughly 25 px across a head,
/// and a one-pixel boundary error there removes a third of the face. A quality
/// level for this job has to be picked on coverage first and milliseconds second.
///
/// The absolute milliseconds move with host load — two runs of the same bench on
/// the same Mac gave 5.5/17.2/54.5 and 9.7/21.0/58.8 — while the *ordering* and
/// the coverage figures did not. Treat the ms as an order of magnitude and the
/// coverage as the finding, and note that no iPhone number exists yet.
public enum PersonSegmentationQuality: String, Sendable, Codable, CaseIterable {
    case fast, balanced, accurate

    var visionQuality: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

/// A whole-frame foreground (person) coverage map plus the affine that puts it
/// back on the photo.
///
/// Deliberately the **same shape** as RPEngine's `RenderMask` — width, height,
/// `[UInt8]` coverage row-major with row 0 at the top, and a mask→image affine —
/// so the app-target adapter is a memberwise call, exactly like
/// `App/FaceAnalysisRenderBridge.swift` is for the face masks. RPVision does not
/// import RPEngine and RPEngine does not import RPVision (docs/ADR-0009); this
/// type is the value carried across that seam.
///
/// Note what this is *not*: it is not a face mask and it never went through
/// BlazeFace, the 478-point mesh or BiSeNet parsing. It is a single, generic
/// `VNGeneratePersonSegmentationRequest` over the whole frame, so it exists for
/// frames where `FaceAnalyzer` finds nothing (a back-turned subject, a full-body
/// shot at a distance) and it covers hair, clothing and hands, which the face
/// parsing crop never sees.
public struct PersonSegmentationMask: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `width * height` bytes of coverage, 0 = background, 255 = subject.
    public var values: [UInt8]
    /// Maps mask pixels (y down) to image pixels (y down).
    public var maskToImage: CGAffineTransform
    /// Pixel size of the image the request ran on.
    public var imageSize: CGSize
    /// Which quality level produced it — carried along because the mask
    /// resolution and the timing both depend on it, and a cached mask has to
    /// know whether it answers the question being asked.
    public var quality: PersonSegmentationQuality

    public init(
        width: Int, height: Int, values: [UInt8], maskToImage: CGAffineTransform,
        imageSize: CGSize, quality: PersonSegmentationQuality
    ) {
        precondition(values.count == width * height, "mask buffer size mismatch")
        self.width = width
        self.height = height
        self.values = values
        self.maskToImage = maskToImage
        self.imageSize = imageSize
        self.quality = quality
    }

    /// Image pixels → mask pixels.
    public var imageToMask: CGAffineTransform { maskToImage.inverted() }

    /// Mean coverage (0…1) over a rectangle **in image pixels**, sampled at the
    /// mask's own resolution with nearest-neighbour.
    ///
    /// This is the measurement hook, not a rendering path: the bench uses it to
    /// state coverage inside a detected face box against coverage in a corner of
    /// the frame, which is what proves the mask is aligned with the photo and not
    /// flipped or transposed. Rendering goes through RPEngine's rasteriser on the
    /// GPU instead.
    public func meanCoverage(inImageRect rect: CGRect) -> Double {
        let t = imageToMask
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { $0.applying(t) }
        let minX = max(0, Int((corners.map(\.x).min() ?? 0).rounded(.down)))
        let maxX = min(width - 1, Int((corners.map(\.x).max() ?? 0).rounded(.up)))
        let minY = max(0, Int((corners.map(\.y).min() ?? 0).rounded(.down)))
        let maxY = min(height - 1, Int((corners.map(\.y).max() ?? 0).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return 0 }
        var total = 0.0
        var count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                total += Double(values[y * width + x])
                count += 1
            }
        }
        return count == 0 ? 0 : total / (255.0 * Double(count))
    }
}

/// Produces ``PersonSegmentationMask`` with `VNGeneratePersonSegmentationRequest`.
///
/// ## Why this is not part of `FaceAnalyzer`
/// Everything else in RPVision is one pipeline — Vision face rectangles →
/// BlazeFace ROI → 478-point mesh → 19-class BiSeNet parsing — and all of it is
/// per-face, crop-sized and backed by converted Core ML models that have to be
/// bundled (docs/ADR-0015). This is a different request family: one whole-frame
/// Vision request whose model ships inside the OS, no crop, no landmarks, no
/// `.mlpackage`, and an answer that exists for frames with no detectable face at
/// all. Routing it through `FaceAnalyzer` would make the background mask depend
/// on a face being found, which is precisely the dependency "Khoá nền" must not
/// have.
///
/// ## Cost
/// One request per image per quality level, and the request is **not** cheap
/// enough to run on the interaction path — see the numbers in
/// `Research/bench/p6-background-lock-*.json`. A caller is expected to do what
/// `FaceAnalyzer` does: run it once per shot, key the result on the shot's
/// content hash and the pixel size, and hand the cached mask to every frame.
///
/// The instance is cheap and holds no model, so a caller may keep one or make
/// one per call; `VNImageRequestHandler` is created per image either way,
/// because Vision's handler is bound to one image.
public struct PersonSegmenter: Sendable {
    /// Quality level every ``mask(for:)`` call uses.
    public let quality: PersonSegmentationQuality

    /// - Throws: ``RPVisionFeatureDisabled`` when
    ///   `RPVisionFeatureFlags.personSegmentation` is off, which is the shipping
    ///   default until §6.1's UI lands. Same gate shape as `FaceAnalyzer`: the
    ///   refusal happens at construction, not halfway through a render.
    public init(quality: PersonSegmentationQuality = .balanced) throws {
        guard RPVisionFeatureFlags.personSegmentation else {
            throw RPVisionFeatureDisabled(feature: "personSegmentation")
        }
        self.quality = quality
    }

    /// Runs the request on `image` and returns the mask in that image's pixel
    /// grid, or `nil` when Vision found no person at all.
    ///
    /// `nil` is a legitimate answer, not an error: a product shot or a landscape
    /// has no subject, and the caller must treat that as "the background lock
    /// has nothing to lock" rather than as a failure.
    public func mask(for image: CGImage) throws -> PersonSegmentationMask? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.visionQuality
        // One byte per pixel. The alternative (`kCVPixelFormatType_OneComponent32Float`)
        // is 4x the bytes for a coverage map that RPEngine uploads as `r8Unorm`
        // anyway, so the float would be quantised on the way to the GPU.
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return Self.mask(
            from: observation.pixelBuffer,
            imageSize: CGSize(width: image.width, height: image.height), quality: quality)
    }

    /// The revision Vision picked for this OS, for the bench record.
    public static var requestRevision: Int {
        VNGeneratePersonSegmentationRequest().revision
    }

    /// Whether `VNGeneratePersonSegmentationRequest` can actually run on this
    /// machine — `nil` when it can, otherwise the reason it cannot.
    ///
    /// **This is not a version check, and it cannot be one.** The request is
    /// API-available on every OS this app targets (iOS 15+/macOS 12+, well below
    /// the iOS 18/macOS 15 floor), and it compiles and constructs fine everywhere.
    /// It is *performing* it that fails on the **iOS Simulator**, with
    /// `com.apple.Vision` code 9 (`VNErrorInternalError`), "Could not create
    /// inference context" — or, on the first request of a process,
    /// `com.apple.VisionCore` code 1, "E5RT is not supported". Both were observed
    /// in the same test run, which is exactly why this probes by *trying* instead
    /// of matching a domain and a code — measured, not guessed: it is why
    /// `Research/bench/p6-background-lock-ios-simulator.json` records an
    /// unsupported platform instead of a millisecond figure. The segmentation
    /// model has no Simulator build; `VNDetectFaceRectanglesRequest` in the same
    /// process on the same image runs normally, so this is specific to this
    /// request family and not a broken Vision install.
    ///
    /// So the only honest test is to try it: this performs the request once on a
    /// 64x48 scratch image and reports what happened. **Costs one request** (a few
    /// ms) — a caller that needs it per frame is holding it wrong; ask once, keep
    /// the answer.
    ///
    /// Deliberately *not* consulted by ``mask(for:)``. A failure there stays a
    /// thrown error, because "this platform cannot do it" and "this call went
    /// wrong" must not collapse into the same silent `nil`.
    public static func unsupportedReason() -> String? {
        guard
            let context = CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let image = context.makeImage()
        else { return "could not build the probe image" }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return nil
        } catch {
            let nsError = error as NSError
            return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        }
    }

    // MARK: - Pixel buffer → bytes

    /// Copies a `OneComponent8` buffer into a tightly packed `[UInt8]`.
    ///
    /// The row stride is not the width — `CVPixelBufferGetBytesPerRow` is padded
    /// to the hardware's alignment (at 512 px wide it comes back as 512 here but
    /// that is not guaranteed), and copying `width * height` bytes straight out
    /// of the base address would shear the mask diagonally on any machine where
    /// it is padded. Rows are copied one at a time for that reason.
    static func mask(
        from buffer: CVPixelBuffer, imageSize: CGSize, quality: PersonSegmentationQuality
    ) -> PersonSegmentationMask? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                destinationBase.advanced(by: row * width)
                    .copyMemory(from: base.advanced(by: row * stride), byteCount: width)
            }
        }
        // Vision returns the mask in the orientation of the image handed to the
        // handler, row 0 at the top, so the only correction is scale. The tests
        // assert this rather than assuming it: coverage is measured inside a
        // *separately* detected face rectangle and would collapse if the mask were
        // flipped.
        //
        // ### The scale is non-uniform, and that is correct
        // The mask does **not** come back at the input's aspect ratio. Measured on
        // real a6300 frames (`PersonSegmenterTests`, and the probe behind
        // `Research/bench/p6-background-lock-macos.json`): a 2048x1365 (3:2) frame
        // returns 256x192 / 512x384 / 2016x1512 — all 4:3 — and a 682x1365 (1:2)
        // frame returns 192x256 / 384x512 / 1512x2016, all 3:4. So Vision fits the
        // picture to its own grid and the mask is a *stretched* copy, which is why
        // the affine below scales each axis independently instead of by one factor.
        //
        // This was worth measuring rather than assuming: if Vision had letterboxed
        // instead of stretched, the same affine would put the mask several percent
        // of the frame out of place, which no amount of looking at a portrait would
        // reveal. Face-box coverage on a square crop (image 1:1, mask 4:3) came back
        // at 0.99–1.00, which a letterbox could not produce.
        let transform = CGAffineTransform(
            scaleX: imageSize.width / CGFloat(width), y: imageSize.height / CGFloat(height))
        return PersonSegmentationMask(
            width: width, height: height, values: values, maskToImage: transform,
            imageSize: imageSize, quality: quality)
    }
}
