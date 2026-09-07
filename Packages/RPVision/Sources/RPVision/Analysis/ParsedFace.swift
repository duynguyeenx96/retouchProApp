import CoreGraphics
import Foundation

/// A face's 19-class parsing result plus the geometry that puts it back on the
/// photo.
///
/// The mask is produced on a **roll-normalised crop framed like CelebAMask-HQ**
/// (1.87 x face width, face centre at 54.4 % of the height), which is what spike
/// S2 §5 measured: on the user's real a6300 frames the raw framing parsed 9 of 11
/// faces and the roll-normalised framing parsed 10 of 11, the two failures being
/// the frames with +41.5° and -19.7° of head roll. `region` carries that geometry
/// so a consumer can map mask pixels back to image pixels.
///
/// ## Two things a consumer must know
///
/// 1. **There is no teeth class.** CelebAMask-HQ's `mouth` is the mouth *interior*
///    (the gap between the lips) — see `FaceParsingGroup`'s doc comment and spike
///    S2 §3c. `docs/PLAN.md` §1.3's "trắng răng" slider must derive teeth from
///    **luminance inside `mouthInterior`**, not from a parsed class. There is
///    deliberately no `teeth` accessor here so the mistake cannot be made silently.
/// 2. **Eyes need a feathered mask.** Spike S2 §4 measured eye IoU at 0.84 against
///    a 0.85 bar and proved it is the checkpoint's ceiling (the PyTorch original
///    scores 0.8401 too) because eyes average 1 365 px of 262 144. That error is a
///    ~1 px boundary error on a 15 px object, invisible through a soft mask and
///    obvious through a hard one. `feathered(_:)` is the accessor eye-adjacent
///    sliders should use; `FaceParsingGroup.recommendedFeatherRadius` says how much.
public struct ParsedFace: Sendable, Equatable {
    /// Dense class map, `region.outputSide` square.
    public var mask: FaceParsingMask
    /// Maps mask pixels to image pixels (y down).
    public var region: CropRegion

    public init(mask: FaceParsingMask, region: CropRegion) {
        self.mask = mask
        self.region = region
    }

    /// Hard 0/255 coverage of a class union, in mask space.
    public func hardMask(for group: FaceParsingGroup) -> [UInt8] {
        mask.binaryMask(for: group)
    }

    /// The mouth *interior*. Named so that nothing reads as "teeth"; see the type
    /// doc for why the whiten-teeth slider has to go through luminance.
    public func mouthInterior() -> [UInt8] { mask.binaryMask(for: .mouth) }

    /// Soft coverage of a class union: a separable box blur of the hard mask, run
    /// twice so the profile is piecewise-linear rather than a step.
    ///
    /// Cost is O(width * height) per pass and independent of the radius (running
    /// sums), so a large feather is not more expensive than a small one; the number
    /// is in `Research/bench/p2-face-analyzer-*.json`.
    ///
    /// - Parameter radius: in mask pixels. `nil` uses
    ///   `group.recommendedFeatherRadius`.
    public func feathered(_ group: FaceParsingGroup, radius: Int? = nil) -> [UInt8] {
        let r = radius ?? group.recommendedFeatherRadius
        return Self.feather(mask.binaryMask(for: group), width: mask.width, height: mask.height, radius: r)
    }

    /// Fraction of the crop each class covers. Cheap health check: spike S2 §5
    /// caught a sign error in the roll normalisation with exactly this signal (the
    /// skin fraction ballooned from ~0.145 to 0.20-0.25 when the face collapsed
    /// into one flat region).
    public func coverage() -> [Double] {
        let total = Double(mask.width * mask.height)
        return mask.histogram().map { Double($0) / total }
    }

    /// The classes a working portrait parse must contain, each above `minFraction`
    /// of the crop. `eyeglasses` substitutes for the eye classes because 9 of the
    /// user's 11 a6300 subjects wear glasses and the model correctly labels those
    /// `eye_g` while emitting no `l_eye`/`r_eye` (spike S2 §5).
    public func partsPresent(minFraction: Double = 0.0005) -> Bool {
        let c = coverage()
        func has(_ cls: FaceParsingClass) -> Bool { c[Int(cls.rawValue)] >= minFraction }
        let eyes = (has(.leftEye) && has(.rightEye)) || has(.eyeglasses)
        return has(.skin) && has(.hair) && has(.nose) && has(.leftBrow) && has(.rightBrow)
            && has(.upperLip) && has(.lowerLip) && eyes
    }

    /// Two passes of a box blur with running sums. Separable, so 4 linear scans.
    static func feather(_ source: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return source }
        var buffer = source.map { Float($0) }
        for _ in 0..<2 {
            buffer = boxBlurRows(buffer, width: width, height: height, radius: radius)
            buffer = boxBlurColumns(buffer, width: width, height: height, radius: radius)
        }
        return buffer.map { UInt8(max(0, min(255, $0.rounded()))) }
    }

    private static func boxBlurRows(
        _ source: [Float], width: Int, height: Int, radius: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: source.count)
        let window = Float(2 * radius + 1)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            // Edges clamp, so the window always has 2r+1 samples and a mask that
            // touches the crop border does not fade out against nothing.
            for i in -radius...radius { sum += source[row + min(max(0, i), width - 1)] }
            for x in 0..<width {
                out[row + x] = sum / window
                let outgoing = source[row + min(max(0, x - radius), width - 1)]
                let incoming = source[row + min(max(0, x + radius + 1), width - 1)]
                sum += incoming - outgoing
            }
        }
        return out
    }

    private static func boxBlurColumns(
        _ source: [Float], width: Int, height: Int, radius: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: source.count)
        let window = Float(2 * radius + 1)
        for x in 0..<width {
            var sum: Float = 0
            for i in -radius...radius { sum += source[min(max(0, i), height - 1) * width + x] }
            for y in 0..<height {
                out[y * width + x] = sum / window
                let outgoing = source[min(max(0, y - radius), height - 1) * width + x]
                let incoming = source[min(max(0, y + radius + 1), height - 1) * width + x]
                sum += incoming - outgoing
            }
        }
        return out
    }
}

extension FaceParsingGroup {
    /// Feather radius in mask pixels (the mask is 512 px square).
    ///
    /// Not tuned against taste — it is a direct consequence of spike S2's measured
    /// boundary error. The eye group's IoU ceiling of 0.84 comes from being ~1 px
    /// out along a ~140 px perimeter, so the mask edge is unreliable at the ±1-2 px
    /// scale and the blend has to be at least that wide. Brows, lips and the mouth
    /// interior are small objects with the same problem (per-class IoU 0.67-0.86,
    /// spike S2 §3b); skin, hair and neck score 0.86-0.94 and need only enough of a
    /// ramp to hide the staircase from the 512 → full-res upsample.
    public var recommendedFeatherRadius: Int {
        switch self {
        case .eyes, .brows, .mouth, .lips: 3
        case .nose, .ears, .eyeglasses: 2
        case .skin, .hair, .neck: 2
        }
    }

    /// Whether a hard mask is measurably unsafe for this group. Eye-adjacent
    /// sliders ("sáng mắt", "trắng lòng trắng", "trắng răng") must honour this.
    public var requiresFeatheredMask: Bool {
        switch self {
        case .eyes, .brows, .mouth, .lips: true
        default: false
        }
    }
}
