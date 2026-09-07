import Foundation
import RPCore

/// The "Mặt" (face reshape) slider group — docs/PLAN.md Phase 2:
/// *Bóp mặt, Gò má, Hàm, Cằm, Trán, Thái dương, Mũi (thu nhỏ/sống/đầu),
/// Mắt (to/khoảng cách/nghiêng), Miệng (to/cười), Môi đầy.*
///
/// Fifteen sliders, all 0–100, all defaulting to 0, all exact no-ops at 0 — the
/// same contract as ``SkinSliders``, and for the same reason:
/// `EditSection.setSlider` *removes* a key set back to 0, so "absent" and "0"
/// have to mean the same thing all the way down to the mesh.
///
/// ## Why every slider is one-directional
/// Several of these are naturally bidirectional in other editors ("eye distance"
/// wider *or* narrower; "chin" longer *or* shorter). The project's fixed
/// decision is `0–100, default 0`, so each slider here is the **one** direction
/// a retoucher reaches for, named in its doc comment. The bidirectional version
/// is a signed −100…100 range, which is a plan/UI change rather than a change to
/// this file: ``FaceReshape`` would take the sign straight through, because
/// every displacement it builds is already linear in the slider value.
///
/// ## Nothing here is a pixel count
/// Each slider's magnitude at 100 is either a **fraction of face width**
/// (`FaceReshape.slimFraction` and friends) or a **dimensionless gain** on a
/// landmark-derived distance that itself scales with the face
/// (`FaceReshape.eyeSizeGain`). Both are invariant to a uniform rescale of the
/// mesh, which is exactly what docs/PLAN.md §2 requires for a preset to move
/// between a head-and-shoulders frame and a full-length one.
/// `FaceReshapeTests.displacementsScaleWithTheFace` is the proof.
public struct FaceSliders: Sendable, Equatable {

    // MARK: - Face outline

    /// **Bóp mặt** — pulls the whole lower face oval toward the face's own
    /// midline, ramping from nothing at the eye line to full at the chin.
    public var slim: Double = 0
    /// **Gò má** — narrows the cheekbone band only (the widest part of the oval,
    /// where `faceWidth` is measured).
    public var cheekbone: Double = 0
    /// **Hàm** — narrows the jaw band, between the cheekbones and the chin.
    public var jaw: Double = 0
    /// **Cằm** — *shortens* the chin: the bottom of the oval moves up the face
    /// axis. Lengthening is the other direction of the same slider.
    public var chin: Double = 0
    /// **Trán** — *lowers* the hairline, i.e. shortens the forehead.
    public var forehead: Double = 0
    /// **Thái dương** — *fills* the temples by pushing that band of the oval
    /// outward. A hollow temple is the common complaint; narrowing there is what
    /// `slim` already does lower down.
    public var temple: Double = 0

    // MARK: - Nose

    /// **Mũi — thu nhỏ.** Scales the whole nose about its own centroid.
    public var noseShrink: Double = 0
    /// **Mũi — sống.** Narrows the bridge, strongest at the nasion and fading to
    /// nothing at the tip.
    ///
    /// A 2D warp can narrow a bridge; it cannot *raise* one, which is a shading
    /// change (dodge along the bridge, burn the sides) and belongs to a later
    /// group. The slider is named for what it does.
    public var noseBridge: Double = 0
    /// **Mũi — đầu.** Lifts the tip along the face axis and pinches the alae in,
    /// strongest below the middle of the nose.
    public var noseTip: Double = 0

    // MARK: - Eyes

    /// **Mắt — to.** Scales each eye (ring + iris) about its own centre.
    public var eyeSize: Double = 0
    /// **Mắt — khoảng cách.** Moves the two eyes *apart* along the face's lateral
    /// axis, each by the same amount, so the face stays symmetric.
    public var eyeSpacing: Double = 0
    /// **Mắt — nghiêng.** Rotates each eye about its own centre so the **outer**
    /// corner rises (a "cat-eye" lift). The sense is derived per face from where
    /// the outer corner actually is, not from a hard-coded sign, so a rolled or
    /// mirrored face cannot tilt the wrong way.
    public var eyeTilt: Double = 0

    // MARK: - Mouth

    /// **Miệng — to.** Scales the whole lip region about the mouth centre.
    public var mouthSize: Double = 0
    /// **Miệng — cười.** Lifts the mouth corners along the face axis and spreads
    /// them outward, with the weight falling to nothing at the centre of the lip.
    public var mouthSmile: Double = 0
    /// **Môi đầy.** Expands the **outer** lip ring away from the mouth's own
    /// horizontal centre line while the **inner** ring is pinned, so the lips
    /// thicken without the mouth opening.
    public var lipFullness: Double = 0

    public init(
        slim: Double = 0, cheekbone: Double = 0, jaw: Double = 0, chin: Double = 0,
        forehead: Double = 0, temple: Double = 0,
        noseShrink: Double = 0, noseBridge: Double = 0, noseTip: Double = 0,
        eyeSize: Double = 0, eyeSpacing: Double = 0, eyeTilt: Double = 0,
        mouthSize: Double = 0, mouthSmile: Double = 0, lipFullness: Double = 0
    ) {
        self.slim = Slider.clamp(slim)
        self.cheekbone = Slider.clamp(cheekbone)
        self.jaw = Slider.clamp(jaw)
        self.chin = Slider.clamp(chin)
        self.forehead = Slider.clamp(forehead)
        self.temple = Slider.clamp(temple)
        self.noseShrink = Slider.clamp(noseShrink)
        self.noseBridge = Slider.clamp(noseBridge)
        self.noseTip = Slider.clamp(noseTip)
        self.eyeSize = Slider.clamp(eyeSize)
        self.eyeSpacing = Slider.clamp(eyeSpacing)
        self.eyeTilt = Slider.clamp(eyeTilt)
        self.mouthSize = Slider.clamp(mouthSize)
        self.mouthSmile = Slider.clamp(mouthSmile)
        self.lipFullness = Slider.clamp(lipFullness)
    }

    /// Parameter names inside `EditState.SectionKey.face`.
    public enum Key {
        public static let slim = "slim"
        public static let cheekbone = "cheekbone"
        public static let jaw = "jaw"
        public static let chin = "chin"
        public static let forehead = "forehead"
        public static let temple = "temple"
        public static let noseShrink = "noseShrink"
        public static let noseBridge = "noseBridge"
        public static let noseTip = "noseTip"
        public static let eyeSize = "eyeSize"
        public static let eyeSpacing = "eyeSpacing"
        public static let eyeTilt = "eyeTilt"
        public static let mouthSize = "mouthSize"
        public static let mouthSmile = "mouthSmile"
        public static let lipFullness = "lipFullness"

        public static let all: [String] = [
            slim, cheekbone, jaw, chin, forehead, temple,
            noseShrink, noseBridge, noseTip,
            eyeSize, eyeSpacing, eyeTilt,
            mouthSize, mouthSmile, lipFullness,
        ]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.face]
        self.init(
            slim: section.slider(Key.slim),
            cheekbone: section.slider(Key.cheekbone),
            jaw: section.slider(Key.jaw),
            chin: section.slider(Key.chin),
            forehead: section.slider(Key.forehead),
            temple: section.slider(Key.temple),
            noseShrink: section.slider(Key.noseShrink),
            noseBridge: section.slider(Key.noseBridge),
            noseTip: section.slider(Key.noseTip),
            eyeSize: section.slider(Key.eyeSize),
            eyeSpacing: section.slider(Key.eyeSpacing),
            eyeTilt: section.slider(Key.eyeTilt),
            mouthSize: section.slider(Key.mouthSize),
            mouthSmile: section.slider(Key.mouthSmile),
            lipFullness: section.slider(Key.lipFullness))
    }

    /// Writes these values back into an `EditState`'s `face` section.
    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.face
        state.setSlider(Key.slim, in: section, to: slim)
        state.setSlider(Key.cheekbone, in: section, to: cheekbone)
        state.setSlider(Key.jaw, in: section, to: jaw)
        state.setSlider(Key.chin, in: section, to: chin)
        state.setSlider(Key.forehead, in: section, to: forehead)
        state.setSlider(Key.temple, in: section, to: temple)
        state.setSlider(Key.noseShrink, in: section, to: noseShrink)
        state.setSlider(Key.noseBridge, in: section, to: noseBridge)
        state.setSlider(Key.noseTip, in: section, to: noseTip)
        state.setSlider(Key.eyeSize, in: section, to: eyeSize)
        state.setSlider(Key.eyeSpacing, in: section, to: eyeSpacing)
        state.setSlider(Key.eyeTilt, in: section, to: eyeTilt)
        state.setSlider(Key.mouthSize, in: section, to: mouthSize)
        state.setSlider(Key.mouthSmile, in: section, to: mouthSmile)
        state.setSlider(Key.lipFullness, in: section, to: lipFullness)
    }

    /// Every value in declaration order. The order is the order ``FaceReshape``
    /// accumulates displacements in, so it is part of the contract: a sum of
    /// floats is not associative and two orders would give two (very slightly)
    /// different meshes for the same document.
    public var values: [Double] {
        [
            slim, cheekbone, jaw, chin, forehead, temple,
            noseShrink, noseBridge, noseTip,
            eyeSize, eyeSpacing, eyeTilt,
            mouthSize, mouthSmile, lipFullness,
        ]
    }

    /// `true` when this group cannot move a single landmark.
    ///
    /// Unlike ``SkinSliders`` there is no modifier slider here — every one of the
    /// fifteen is an effect in its own right, so this is simply "all zero".
    public var isIdentity: Bool { values.allSatisfy { $0 == 0 } }

    /// Does any slider touch the face oval?
    var needsOval: Bool {
        slim > 0 || cheekbone > 0 || jaw > 0 || chin > 0 || forehead > 0 || temple > 0
    }
    /// Does any slider touch the nose?
    var needsNose: Bool { noseShrink > 0 || noseBridge > 0 || noseTip > 0 }
    /// Does any slider touch the eyes?
    var needsEyes: Bool { eyeSize > 0 || eyeSpacing > 0 || eyeTilt > 0 }
    /// Does any slider touch the lips?
    var needsMouth: Bool { mouthSize > 0 || mouthSmile > 0 || lipFullness > 0 }
}
