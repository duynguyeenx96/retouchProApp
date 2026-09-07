import CoreGraphics
import CryptoKit
import Foundation

/// Everything that changes what `FaceAnalyzer` produces. Part of the cache key, so
/// two callers asking for different framings can never share a cached result.
///
/// Every default here is a number some spike measured, not a preference. Changing
/// one invalidates the corresponding result file; the comments say which.
public struct FaceAnalyzerOptions: Sendable, Equatable, Hashable, Codable {
    /// Side of the stage-2 crop handed to BlazeFace, as a multiple of the long side
    /// of Vision's box.
    ///
    /// 3.5 is the framing spike S1 built its real-camera dataset with
    /// (`Research/spikes/S1-landmark/prepare_a6300.swift`), and MediaPipe's own
    /// detector finds every face in those crops. It cannot be "just run BlazeFace
    /// on the frame": at 128 px input a 6 %-of-frame face is ~8 px wide and S1 §4a
    /// measured the detector finding *nothing* in 4 of the 11 full 24 MP frames at
    /// every scale from full-res down to 1400 px. That is the whole reason stage 1
    /// exists.
    public var detectorRegionScale: CGFloat = 3.5

    /// Scale from BlazeFace's box to the mesh ROI. **1.5, MediaPipe's own value**
    /// (`RectTransformationCalculator` with `square_long: true, scale: 1.5`), not
    /// `FaceCrop.visionBoxScale` = 1.40. 1.40 was a fit that partially compensated
    /// for Apple's box being ~6 % larger than BlazeFace's; feeding it a BlazeFace
    /// box would double-count the correction.
    public var landmarkROIScale: CGFloat = 1.5

    /// MediaPipe rounds the ROI side to a whole pixel before cropping. Matching it
    /// is free and removes a sub-pixel difference from the comparison against the
    /// Python reference.
    public var roundsLandmarkROISide: Bool = true

    public var detection: BlazeFaceDecoder.Options = BlazeFaceDecoder.Options()

    /// `nil` skips parsing entirely (landmarks only), which is what a reshape-only
    /// preview wants.
    public var parsing: ParsingOptions? = ParsingOptions()

    public init() {}

    public struct ParsingOptions: Sendable, Equatable, Hashable, Codable {
        /// Crop side as a multiple of the face box's long side. 1.87 and 0.544 are
        /// measured off the 30 CelebAMask-HQ test frames the checkpoint was trained
        /// on (spike S2 §5): the training frame is 1.87 x face width with the face
        /// centre at 54.4 % of the height. S1's 3.5 x framing shows the parser a
        /// face 3.4x smaller in area than anything it has seen.
        public var cropScale: CGFloat = 1.87
        /// Where the face centre sits vertically in the crop, 0…1.
        public var faceCenterYFraction: CGFloat = 0.544
        /// Rotate the crop so the eye line is horizontal before parsing.
        ///
        /// Spike S2 §5: without this the model collapsed the two most-rolled a6300
        /// frames (+41.5°, −19.7°) into one flat `skin` region — no nose, no brows,
        /// no eyes. With it, 10 of 11 frames parse completely instead of 9.
        public var rollNormalised: Bool = true

        public init() {}
    }

    /// Stable digest of the options, used in the cache key.
    ///
    /// JSON with sorted keys rather than `hashValue`: Swift's `Hasher` is seeded
    /// per process, so a `hashValue` in a key that might one day be written to disk
    /// would silently stop matching after a relaunch.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "unencodable" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
