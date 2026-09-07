import Foundation
import RPCore

/// The "Da" slider group (docs/PLAN.md Phase 2): eight 0–100 sliders, all
/// defaulting to 0, all no-ops at 0.
///
/// The 0-default rule is not decoration — `EditSection.setSlider` *removes* a key
/// set back to 0, so "absent" and "0" have to mean the same thing all the way
/// down to the shader. ``isIdentity`` is what the graph uses to skip the node
/// entirely, and `SkinRenderNodeTests.allSlidersZeroIsBitExactIdentity` pins that
/// the kernel agrees.
public struct SkinSliders: Sendable, Equatable {
    /// Mịn da — guided-filter smoothing amount inside the skin mask.
    public var smooth: Double = 0
    /// Giữ texture — how much of the high-frequency residual is added back on
    /// top of the smoothing.
    ///
    /// A *modifier*, not an effect: at `smooth == 0` it does nothing, and at
    /// `keepTexture == 100` the smoothing is cancelled out exactly. That is why
    /// it is excluded from ``isIdentity`` — a document with only `keepTexture`
    /// set renders identical to the original.
    public var keepTexture: Double = 0
    /// Đều màu da — pull local chroma towards the large-radius blur, holding
    /// luminance.
    public var evenTone: Double = 0
    /// Khử đỏ — remove redness above the local mean.
    public var redness: Double = 0
    /// Khử bóng dầu — darken specular highlights towards the local mean.
    public var shine: Double = 0
    /// Sáng da — gamma lift inside the skin mask.
    public var brighten: Double = 0
    /// Quầng thâm — lift local dark patches towards their surroundings.
    public var darkCircle: Double = 0
    /// Nếp nhăn — fill the negative high-frequency residual (dark fine lines).
    public var wrinkle: Double = 0

    public init(
        smooth: Double = 0, keepTexture: Double = 0, evenTone: Double = 0,
        redness: Double = 0, shine: Double = 0, brighten: Double = 0,
        darkCircle: Double = 0, wrinkle: Double = 0
    ) {
        self.smooth = Slider.clamp(smooth)
        self.keepTexture = Slider.clamp(keepTexture)
        self.evenTone = Slider.clamp(evenTone)
        self.redness = Slider.clamp(redness)
        self.shine = Slider.clamp(shine)
        self.brighten = Slider.clamp(brighten)
        self.darkCircle = Slider.clamp(darkCircle)
        self.wrinkle = Slider.clamp(wrinkle)
    }

    /// Parameter names inside `EditState.SectionKey.skin`.
    public enum Key {
        public static let smooth = "smooth"
        public static let keepTexture = "keepTexture"
        public static let evenTone = "evenTone"
        public static let redness = "redness"
        public static let shine = "shine"
        public static let brighten = "brighten"
        public static let darkCircle = "darkCircle"
        public static let wrinkle = "wrinkle"

        public static let all = [
            smooth, keepTexture, evenTone, redness, shine, brighten, darkCircle, wrinkle,
        ]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.skin]
        self.init(
            smooth: section.slider(Key.smooth),
            keepTexture: section.slider(Key.keepTexture),
            evenTone: section.slider(Key.evenTone),
            redness: section.slider(Key.redness),
            shine: section.slider(Key.shine),
            brighten: section.slider(Key.brighten),
            darkCircle: section.slider(Key.darkCircle),
            wrinkle: section.slider(Key.wrinkle))
    }

    /// Writes these values back into an `EditState`'s `skin` section.
    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.skin
        state.setSlider(Key.smooth, in: section, to: smooth)
        state.setSlider(Key.keepTexture, in: section, to: keepTexture)
        state.setSlider(Key.evenTone, in: section, to: evenTone)
        state.setSlider(Key.redness, in: section, to: redness)
        state.setSlider(Key.shine, in: section, to: shine)
        state.setSlider(Key.brighten, in: section, to: brighten)
        state.setSlider(Key.darkCircle, in: section, to: darkCircle)
        state.setSlider(Key.wrinkle, in: section, to: wrinkle)
    }

    /// `true` when this group cannot change a single pixel. `keepTexture` is
    /// excluded on purpose — see its doc comment.
    public var isIdentity: Bool {
        smooth == 0 && evenTone == 0 && redness == 0 && shine == 0 && brighten == 0
            && darkCircle == 0 && wrinkle == 0
    }

    /// Does the composite need the edge-preserving (guided) layer?
    var needsSmoothLayer: Bool { smooth > 0 || wrinkle > 0 }
    /// Does the composite need the large-radius blur?
    var needsLowFrequencyLayer: Bool {
        evenTone > 0 || redness > 0 || shine > 0 || darkCircle > 0
    }
}
