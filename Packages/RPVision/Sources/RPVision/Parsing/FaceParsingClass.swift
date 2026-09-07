import Foundation

/// The 19 CelebAMask-HQ classes emitted by the face-parsing model, in the exact
/// index order the checkpoint was trained with.
///
/// The order is **not** guessed: it is `enumerate(atts, 1)` in
/// `prepropess_data.py` of zllrunning/face-parsing.PyTorch, which is the script
/// that generated the training labels, with 0 left as background. Other
/// "CelebAMask-HQ 19 class" listings on the internet order the parts differently
/// (some put `hair` at 13, some drop `ear_r`), and using one of those would
/// silently mislabel every mask. `Research/spikes/S2-face-parsing` verifies the
/// mapping empirically as well: per-class IoU against ground truth built with
/// this same rule, plus a geometric sanity check (hair above skin, eyes inside
/// the face box) in `FaceParsingModelTests`.
public enum FaceParsingClass: UInt8, CaseIterable, Sendable {
    case background = 0
    case skin = 1
    case leftBrow = 2
    case rightBrow = 3
    case leftEye = 4
    case rightEye = 5
    case eyeglasses = 6
    case leftEar = 7
    case rightEar = 8
    case earring = 9
    case nose = 10
    case mouth = 11
    case upperLip = 12
    case lowerLip = 13
    case neck = 14
    case necklace = 15
    case cloth = 16
    case hair = 17
    case hat = 18

    /// The upstream attribute name, i.e. the `*_<name>.png` suffix in
    /// `CelebAMask-HQ-mask-anno`. `background` has no annotation file.
    public var celebAMaskName: String {
        switch self {
        case .background: "background"
        case .skin: "skin"
        case .leftBrow: "l_brow"
        case .rightBrow: "r_brow"
        case .leftEye: "l_eye"
        case .rightEye: "r_eye"
        case .eyeglasses: "eye_g"
        case .leftEar: "l_ear"
        case .rightEar: "r_ear"
        case .earring: "ear_r"
        case .nose: "nose"
        case .mouth: "mouth"
        case .upperLip: "u_lip"
        case .lowerLip: "l_lip"
        case .neck: "neck"
        case .necklace: "neck_l"
        case .cloth: "cloth"
        case .hair: "hair"
        case .hat: "hat"
        }
    }
}

/// Named unions of classes, which is what the render graph actually wants:
/// docs/PLAN.md §2 asks `FaceAnalysis` for skin / hair / eyes / teeth / lips /
/// brows / neck rather than 19 separate maps.
///
/// Note `teeth` is deliberately absent: CelebAMask-HQ has no teeth class. `mouth`
/// is the mouth *interior* (the gap between the lips), so Phase 2's "whiten teeth"
/// slider has to derive teeth from `mouth` by luminance, not from a parsing class.
public enum FaceParsingGroup: String, CaseIterable, Sendable {
    case skin
    case hair
    case eyes
    case brows
    case lips
    case mouth
    case nose
    case neck
    case ears
    case eyeglasses

    public var classes: [FaceParsingClass] {
        switch self {
        case .skin: [.skin]
        case .hair: [.hair]
        case .eyes: [.leftEye, .rightEye]
        case .brows: [.leftBrow, .rightBrow]
        case .lips: [.upperLip, .lowerLip]
        case .mouth: [.mouth]
        case .nose: [.nose]
        case .neck: [.neck]
        case .ears: [.leftEar, .rightEar]
        case .eyeglasses: [.eyeglasses]
        }
    }
}
