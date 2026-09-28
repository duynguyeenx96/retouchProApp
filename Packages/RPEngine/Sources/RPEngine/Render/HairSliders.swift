import Foundation
import RPCore

/// The "Tóc" (hair) slider group — docs/PLAN.md Phase 5, *"hair: bóng, tối/sáng,
/// đổi màu"*.
///
/// Five sliders, all 0–100, all defaulting to 0 — the same contract as
/// ``EyesTeethSliders``: `EditSection.setSlider` *removes* a key set back to 0,
/// so "absent" and "0" have to mean the same thing all the way down to the
/// shader, and ``isIdentity`` is what lets the graph skip the node.
///
/// ## Why "Tối / sáng" is two sliders
/// The plan names one bidirectional control. Only the "Color" namespace is
/// signed today (`RPCore.Slider.bidirectionalSections`, docs/ADR-0016), and
/// making `hair` signed would change how RPCore clamps, how presets scale and
/// what `EditState.isDefault` means for this namespace — an RPCore format
/// decision to take on its own, not as a side effect of a Phase 5 node. Two
/// one-directional amounts keep "0 = untouched" trivially true, and both at once
/// compose (their exponents multiply, see ``lightnessExponent``).
///
/// ## `dyeTone` is a modifier, not an effect
/// A hue has no neutral value, so a "hair colour" slider whose 0 is a colour
/// would break the 0-is-identity rule. The dye is therefore an *amount*
/// (``dye``) plus a *where on the palette* (``dyeTone``), and ``dyeTone`` alone
/// changes nothing — the arrangement ``SkinSliders``' "Giữ texture" already
/// uses. ``isIdentity`` ignores it for exactly that reason.
public struct HairSliders: Sendable, Equatable {
    /// **Bóng tóc** — local contrast plus a lift of the strands that are already
    /// brighter than their neighbourhood, i.e. the sheen bands.
    public var gloss: Double = 0
    /// **Sáng tóc** — luma lift inside the hair mask.
    public var lighten: Double = 0
    /// **Tối tóc** — luma push-down inside the hair mask.
    public var darken: Double = 0
    /// **Nhuộm màu** — how far the hair's chroma moves to the ``dyeTone`` colour,
    /// at constant luma.
    public var dye: Double = 0
    /// **Tông màu** — where on ``dyePalette`` the dye sits. Modifier only.
    public var dyeTone: Double = 0

    public init(
        gloss: Double = 0, lighten: Double = 0, darken: Double = 0, dye: Double = 0,
        dyeTone: Double = 0
    ) {
        self.gloss = Slider.clamp(gloss)
        self.lighten = Slider.clamp(lighten)
        self.darken = Slider.clamp(darken)
        self.dye = Slider.clamp(dye)
        self.dyeTone = Slider.clamp(dyeTone)
    }

    /// Parameter names inside `EditState.SectionKey.hair`.
    public enum Key {
        public static let gloss = "gloss"
        public static let lighten = "lighten"
        public static let darken = "darken"
        public static let dye = "dye"
        public static let dyeTone = "dyeTone"

        public static let all = [gloss, lighten, darken, dye, dyeTone]
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.hair]
        self.init(
            gloss: section.slider(Key.gloss),
            lighten: section.slider(Key.lighten),
            darken: section.slider(Key.darken),
            dye: section.slider(Key.dye),
            dyeTone: section.slider(Key.dyeTone))
    }

    /// Writes these values back into an `EditState`'s `hair` section.
    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.hair
        state.setSlider(Key.gloss, in: section, to: gloss)
        state.setSlider(Key.lighten, in: section, to: lighten)
        state.setSlider(Key.darken, in: section, to: darken)
        state.setSlider(Key.dye, in: section, to: dye)
        state.setSlider(Key.dyeTone, in: section, to: dyeTone)
    }

    /// `true` when this group cannot change a single pixel. ``dyeTone`` is not
    /// part of it — see the type's note.
    public var isIdentity: Bool { gloss == 0 && lighten == 0 && darken == 0 && dye == 0 }

    /// Does the composite need the local-mean (double box blur) layer? Only
    /// "Bóng tóc" compares a strand with its neighbourhood; the other three are
    /// per-pixel, and the layer is 192 MB at 24 MP.
    var needsLocalMeanLayer: Bool { gloss > 0 }

    // MARK: - Lightness

    /// Luma exponent at "Sáng tóc" = 100. Stronger than the eye lift's 0.86
    /// because hair is the darkest large region of a portrait: at 0.86 a strand
    /// at luma 0.12 moves to 0.16, which nobody would call "lighter hair".
    /// 0.65 takes it to 0.25. Argued, not tuned against a retoucher's eye.
    public static let lightenExponent = 0.65
    /// Luma exponent at "Tối tóc" = 100. 1.8 takes a mid-brown strand at 0.35 to
    /// 0.15 — roughly one shade darker on a dye chart — while a highlight at 0.8
    /// only drops to 0.67, so the hair keeps its shape.
    public static let darkenExponent = 1.8

    /// The exponent applied to the pixel's **luma** (not per channel — see the
    /// shader: per-channel gamma is what gave the removed "Tự động" its yellow
    /// cast, docs/PLAN.md §6.5). Interpolated in log space so 50 is the
    /// geometric half of 100, and the two sliders multiply.
    var lightnessExponent: Double {
        pow(Self.lightenExponent, lighten / 100) * pow(Self.darkenExponent, darken / 100)
    }

    // MARK: - Dye palette

    /// The colours "Tông màu" walks through, gamma-encoded sRGB, in slider order:
    /// ash brown → copper → burgundy → violet → ash grey-blue.
    ///
    /// Picked as the common salon families, dark enough to be hair colours
    /// rather than paint. Only their **chroma direction** is used — the tint is
    /// normalised to luma 1 (``dyeTint(tone:)``) and multiplied by the pixel's own
    /// luma — so the absolute brightness of these five does not matter.
    /// Not tuned against real renders; docs/PLAN.md lists that as local work.
    public static let dyePalette: [SIMD3<Double>] = [
        SIMD3(0.40, 0.33, 0.28),
        SIMD3(0.62, 0.34, 0.20),
        SIMD3(0.50, 0.16, 0.22),
        SIMD3(0.38, 0.22, 0.48),
        SIMD3(0.36, 0.38, 0.44),
    ]

    /// Rec.709 luma, the same weights as `kRPLuma` in SkinShaders.metal.
    static let lumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// The dye colour for a "Tông màu" value, **normalised to luma 1**: the shader
    /// multiplies it by the pixel's luma, so a dyed pixel keeps its brightness
    /// and only its chroma moves. Computed once on the CPU and handed to the
    /// shader, so the palette has one definition that a test can read.
    static func dyeTint(tone: Double) -> SIMD3<Double> {
        let palette = dyePalette
        let position = Slider.clamp(tone) / 100 * Double(palette.count - 1)
        let lower = min(palette.count - 2, Int(position.rounded(.down)))
        let f = position - Double(lower)
        let c = palette[lower] * (1 - f) + palette[lower + 1] * f
        let y = (c * lumaWeights).sum()
        return c / max(y, 1e-6)
    }
}
