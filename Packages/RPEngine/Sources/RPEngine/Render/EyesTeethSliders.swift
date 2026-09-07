import Foundation
import RPCore

/// The "Mắt / Răng" slider group (docs/PLAN.md Phase 2): *Sáng mắt, Trắng lòng
/// trắng, Nét mắt, Trắng răng.*
///
/// Four sliders, all 0–100, all defaulting to 0, all exact no-ops at 0 — the
/// same contract as ``SkinSliders`` and ``FaceSliders``, and for the same
/// reason: `EditSection.setSlider` *removes* a key set back to 0, so "absent"
/// and "0" have to mean the same thing all the way down to the shader.
/// ``isIdentity`` is what the graph uses to skip the node entirely, and
/// `EyesTeethRenderNodeTests.allSlidersZeroIsBitExactIdentity` pins that the
/// kernel agrees.
///
/// Unlike ``SkinSliders`` there is no modifier here — every one of the four is
/// an effect in its own right — so ``isIdentity`` is simply "all zero".
public struct EyesTeethSliders: Sendable, Equatable {
    /// **Sáng mắt** — gamma lift inside the eye mask.
    public var eyeBrighten: Double = 0
    /// **Trắng lòng trắng** — removes the yellow/red cast from the white of the
    /// eye. Weighted toward the pixels inside the eye mask that look like sclera
    /// (bright for their neighbourhood, close to neutral); there is no sclera
    /// class in CelebAMask-HQ, see ``EyesTeethRenderNode``.
    public var scleraWhiten: Double = 0
    /// **Nét mắt** — local contrast inside the eye mask, at the eye's own scale.
    public var eyeDefinition: Double = 0
    /// **Trắng răng** — the same whitening as ``scleraWhiten``, inside the mouth
    /// *interior* mask and with a tighter neutrality cut-off. Derived from
    /// luminance, never from a "teeth" parsing class — there isn't one
    /// (spike S2 §3c, `RenderMaskKind`'s doc comment).
    public var teethWhiten: Double = 0

    public init(
        eyeBrighten: Double = 0, scleraWhiten: Double = 0, eyeDefinition: Double = 0,
        teethWhiten: Double = 0
    ) {
        self.eyeBrighten = Slider.clamp(eyeBrighten)
        self.scleraWhiten = Slider.clamp(scleraWhiten)
        self.eyeDefinition = Slider.clamp(eyeDefinition)
        self.teethWhiten = Slider.clamp(teethWhiten)
    }

    /// Parameter names inside `EditState.SectionKey.eyesTeeth`.
    public enum Key {
        public static let eyeBrighten = "eyeBrighten"
        public static let scleraWhiten = "scleraWhiten"
        public static let eyeDefinition = "eyeDefinition"
        public static let teethWhiten = "teethWhiten"

        public static let all = [eyeBrighten, scleraWhiten, eyeDefinition, teethWhiten]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.eyesTeeth]
        self.init(
            eyeBrighten: section.slider(Key.eyeBrighten),
            scleraWhiten: section.slider(Key.scleraWhiten),
            eyeDefinition: section.slider(Key.eyeDefinition),
            teethWhiten: section.slider(Key.teethWhiten))
    }

    /// Writes these values back into an `EditState`'s `eyesTeeth` section.
    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.eyesTeeth
        state.setSlider(Key.eyeBrighten, in: section, to: eyeBrighten)
        state.setSlider(Key.scleraWhiten, in: section, to: scleraWhiten)
        state.setSlider(Key.eyeDefinition, in: section, to: eyeDefinition)
        state.setSlider(Key.teethWhiten, in: section, to: teethWhiten)
    }

    /// `true` when this group cannot change a single pixel.
    public var isIdentity: Bool {
        eyeBrighten == 0 && scleraWhiten == 0 && eyeDefinition == 0 && teethWhiten == 0
    }

    /// Does anything in this group read the eye mask?
    var needsEyeMask: Bool { eyeBrighten > 0 || scleraWhiten > 0 || eyeDefinition > 0 }
    /// Does anything in this group read the mouth-interior mask?
    var needsMouthMask: Bool { teethWhiten > 0 }
    /// Does the composite need the local-mean (double box blur) layer?
    ///
    /// "Sáng mắt" alone does not: a gamma lift needs no neighbourhood. That is
    /// worth a branch, because the layer is 192 MB at 24 MP and the guided
    /// filter's intermediates another 144 MB.
    var needsLocalMeanLayer: Bool {
        scleraWhiten > 0 || eyeDefinition > 0 || teethWhiten > 0
    }
}
