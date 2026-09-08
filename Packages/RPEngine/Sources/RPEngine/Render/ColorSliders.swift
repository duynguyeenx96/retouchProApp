import Foundation
import RPCore

/// One of the eight hue bands the "HSL" sub-group works on.
///
/// Centres are the classic eight-band split (the same set Lightroom's HSL panel
/// uses). They are **not** evenly spaced, so the weights are normalised at use
/// (see ``ColorRenderNode``): each band gets a triangular window of ±60°, the
/// windows are divided by their sum, and the result is a partition of unity —
/// which is what makes "all eight bands at 100" exactly equal to
/// ``ColorSliders/saturation`` at 100 (`ColorRenderNodeTests.hslBandsSumToPlainSaturation`).
public enum HueBand: Int, Sendable, CaseIterable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// Hue centre in degrees, HSV convention (red 0°, green 120°, blue 240°).
    public var centreDegrees: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 280
        case .magenta: 320
        }
    }

    /// Parameter name inside `EditState.SectionKey.color`.
    public var key: String {
        switch self {
        case .red: "hslRed"
        case .orange: "hslOrange"
        case .yellow: "hslYellow"
        case .green: "hslGreen"
        case .aqua: "hslAqua"
        case .blue: "hslBlue"
        case .purple: "hslPurple"
        case .magenta: "hslMagenta"
        }
    }
}

/// The "Color" slider group (docs/PLAN.md Phase 2): *Exposure, Contrast,
/// Highlights, Shadows, WB, Vibrance, Saturation, Curves, HSL, Auto D&B.*
///
/// Ten names in the plan, **18 keys** here. Two of the ten are sub-groups, in
/// exactly the way the "Mặt" list writes "Mũi (thu nhỏ/sống/đầu)" as one item and
/// ships three sliders:
///
/// * **WB** → ``wbTemperature`` + ``wbTint``. A white balance control without a
///   green/magenta axis is half a control; both axes are one 0–100 slider each.
/// * **HSL** → eight per-hue-band saturation sliders (``hsl``, indexed by
///   ``HueBand``). Per-band *lightness* and *hue rotation* are deliberately not
///   shipped — they would be 16 more keys, and the band weights the kernel
///   already computes are the whole of the machinery they would need
///   (docs/ADR-0012).
///
/// ## 16 sliders are −100…100, two are 0…100, all default 0
///
/// This is the **only** bidirectional group in the project (docs/ADR-0016).
/// `Slider.range(for:in:)` scopes it: "Da", "Mặt" and "Mắt / Răng" still clamp to
/// 0…100 and are untouched. The reason to widen this one is that a photograph can
/// arrive already over-processed, and then the fix is *less* exposure / contrast /
/// saturation than the file has, which a one-directional slider cannot express.
///
/// Widening does not break the contract every node depends on. What that contract
/// needs is "absent == neutral == the default", because `EditSection.setSlider`
/// **deletes** a key set back to its default (`RPCore/EditState.swift`); 0 is
/// still the default and still the identity, it now simply has values on both
/// sides. A slider *centred at 50* would still be illegal, and there is none.
///
/// Each direction is chosen and documented rather than implied:
///
/// | slider | at +100 | at −100 |
/// |---|---|---|
/// | `exposure` | **brighter**, +1 EV | **darker**, −1 EV (symmetric in stops, not in gain) |
/// | `contrast` | more contrast (S-curve) | flatter, toward mid-grey |
/// | `highlights` | highlights pulled **down** (recovery) | highlights pushed **up** |
/// | `shadows` | shadows pulled **up** (lift) | shadows pushed **down** |
/// | `wbTemperature` | **warmer** | **cooler** |
/// | `wbTint` | toward **magenta** | toward **green** |
/// | `vibrance` | more saturation in the least saturated colours | less, same weighting |
/// | `saturation` | 2× saturation | 0× — grayscale |
/// | `hsl…` | more saturation in that hue band | less, down to grey at −100 |
/// | `curves` | more of the fixed film curve | **not available — 0…100** |
/// | `autoDodgeBurn` | more local-luminance evening | **not available — 0…100** |
///
/// Note `highlights`/`shadows` keep the sign convention they shipped with in
/// docs/ADR-0012 (positive = recovery), which is the **opposite** of Lightroom's.
/// Flipping it would silently reinterpret every value already written to
/// `edits/*.json`, so it is written down instead.
///
/// ### Why two sliders stay one-directional
/// * `curves` is the *amount* of one fixed film look (``ColorToneCurve``). The
///   opposite of a look is not a look, and mechanically the extrapolation past 0
///   clips: the curve's lifted toe (0.030) maps to a negative value and crushes
///   the bottom 3 % to black, exactly the clipping this node was designed to
///   avoid. The bidirectional version of "Curves" is a knot editor, which
///   docs/ADR-0012 already defers.
/// * `autoDodgeBurn` is a **correction**: it measures this frame's local
///   luminance error and reduces it. Negated it would *amplify* blotchiness, and
///   no user dragging a slider named "Dodge & Burn tự động" to the left is asking
///   for that. If "more local contrast" is ever wanted it is a different slider
///   with a different name, not this one's negative half.
///
/// Both are listed in `Slider.oneDirectionalParameters` in RPCore (that is where
/// the clamp happens); `ColorRenderNodeTests.rangesAreScopedToTheColorGroup` pins
/// the two lists together, because RPCore cannot import RPEngine's key names.
public struct ColorSliders: Sendable, Equatable {
    /// **Exposure**, −100…100 — ±1 EV, applied as a gain in **linear light**.
    /// `exp2(amount)`, so the two directions are symmetric in *stops*: −100 is
    /// 0.5×, exactly the inverse of +100's 2×.
    public var exposure: Double = 0
    /// **Contrast**, −100…100 — a smoothstep S-curve about mid-grey, mixed in at
    /// positive values and **extrapolated away from** at negative ones, which
    /// flattens the picture toward mid-grey. Monotone and endpoint-preserving in
    /// both directions (measured: minimum slope 0.75 at −100).
    public var contrast: Double = 0
    /// **Highlights**, −100…100 — a gamma weighted toward bright pixels: >1
    /// (recovery, darker) at positive values, its **reciprocal** at negative
    /// ones. Positive = recovery is docs/ADR-0012's convention and the opposite
    /// of Lightroom's; see the type's doc comment.
    public var highlights: Double = 0
    /// **Shadows**, −100…100 — a gamma weighted toward dark pixels: <1 (lift) at
    /// positive values, its **reciprocal** (deepen) at negative ones.
    public var shadows: Double = 0
    /// **WB, temperature axis**, −100…100 — warmer above 0, cooler below. A von
    /// Kries diagonal gain in linear light, renormalised so the frame's
    /// luminance does not move with it. The gain is `pow(base, amount)`, so
    /// −x is the exact channel-wise inverse of +x.
    public var wbTemperature: Double = 0
    /// **WB, tint axis**, −100…100 — toward magenta above 0 (green pulled down),
    /// toward green below.
    public var wbTint: Double = 0
    /// **Vibrance**, −100…100 — saturation change weighted by `1 − saturation`,
    /// damped on the skin-tone hues so a portrait's face is neither the first
    /// thing to clip nor the first thing to go grey.
    public var vibrance: Double = 0
    /// **Saturation**, −100…100 — uniform: 2× at 100, 0× (grayscale) at −100.
    public var saturation: Double = 0
    /// **Curves**, **0…100** — the amount of a fixed per-channel film curve
    /// (lifted toe, rolled shoulder, cool shadows / warm highlights), applied
    /// through a 256-entry LUT texture. Not a knot editor; see ``ColorToneCurve``.
    /// One-directional on purpose — the opposite of a look is not a look, and
    /// extrapolating past 0 clips both ends (see the type's doc comment).
    public var curves: Double = 0
    /// **Auto D&B**, **0…100** — the port of `panelpts/RetouchProUXP`
    /// `dodgeBurnMaps` + `autoDodgeBurn`: evens out local luminance blocks by
    /// dodging what is darker than its surroundings and burning what is brighter.
    /// One-directional on purpose — the negative half would amplify the very
    /// blotchiness it exists to remove (see the type's doc comment).
    public var autoDodgeBurn: Double = 0
    /// **HSL**, −100…100 each — per-hue-band saturation, indexed by
    /// ``HueBand/rawValue``.
    /// Always ``HueBand/allCases``.count long; a shorter or longer array is
    /// padded/truncated by ``init(exposure:contrast:highlights:shadows:wbTemperature:wbTint:vibrance:saturation:curves:autoDodgeBurn:hsl:)``.
    public private(set) var hsl: [Double]

    public init(
        exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        wbTemperature: Double = 0, wbTint: Double = 0, vibrance: Double = 0,
        saturation: Double = 0, curves: Double = 0, autoDodgeBurn: Double = 0,
        hsl: [Double] = []
    ) {
        self.exposure = Self.clamp(exposure, Key.exposure)
        self.contrast = Self.clamp(contrast, Key.contrast)
        self.highlights = Self.clamp(highlights, Key.highlights)
        self.shadows = Self.clamp(shadows, Key.shadows)
        self.wbTemperature = Self.clamp(wbTemperature, Key.wbTemperature)
        self.wbTint = Self.clamp(wbTint, Key.wbTint)
        self.vibrance = Self.clamp(vibrance, Key.vibrance)
        self.saturation = Self.clamp(saturation, Key.saturation)
        self.curves = Self.clamp(curves, Key.curves)
        self.autoDodgeBurn = Self.clamp(autoDodgeBurn, Key.autoDodgeBurn)
        self.hsl = HueBand.allCases.map { band in
            band.rawValue < hsl.count ? Self.clamp(hsl[band.rawValue], band.key) : 0
        }
    }

    /// Clamps one value to the range RPCore gives this key **in the color
    /// section** — −100…100 for the sixteen bidirectional sliders, 0…100 for
    /// `curves` and `autoDodgeBurn`. The table lives in `RPCore.Slider` because
    /// that is where `EditSection.setSlider` clamps; this just asks it, so the
    /// in-memory value and the value that survives a save can never disagree.
    static func clamp(_ value: Double, _ key: String) -> Double {
        Slider.clamp(value, for: key, in: EditState.SectionKey.color)
    }

    /// One hue band's saturation slider.
    public subscript(band: HueBand) -> Double {
        get { hsl[band.rawValue] }
        set { hsl[band.rawValue] = Self.clamp(newValue, band.key) }
    }

    /// Parameter names inside `EditState.SectionKey.color`.
    public enum Key {
        public static let exposure = "exposure"
        public static let contrast = "contrast"
        public static let highlights = "highlights"
        public static let shadows = "shadows"
        public static let wbTemperature = "wbTemperature"
        public static let wbTint = "wbTint"
        public static let vibrance = "vibrance"
        public static let saturation = "saturation"
        public static let curves = "curves"
        public static let autoDodgeBurn = "autoDodgeBurn"

        /// Every key this group owns, scalars first then the eight hue bands.
        public static let all: [String] =
            [
                exposure, contrast, highlights, shadows, wbTemperature, wbTint, vibrance,
                saturation, curves, autoDodgeBurn,
            ] + HueBand.allCases.map(\.key)
    }

    public init(_ state: EditState) {
        let section = state[section: EditState.SectionKey.color]
        self.init(
            exposure: section.slider(Key.exposure),
            contrast: section.slider(Key.contrast),
            highlights: section.slider(Key.highlights),
            shadows: section.slider(Key.shadows),
            wbTemperature: section.slider(Key.wbTemperature),
            wbTint: section.slider(Key.wbTint),
            vibrance: section.slider(Key.vibrance),
            saturation: section.slider(Key.saturation),
            curves: section.slider(Key.curves),
            autoDodgeBurn: section.slider(Key.autoDodgeBurn),
            hsl: HueBand.allCases.map { section.slider($0.key) })
    }

    /// Writes these values back into an `EditState`'s `color` section.
    public func write(into state: inout EditState) {
        let section = EditState.SectionKey.color
        state.setSlider(Key.exposure, in: section, to: exposure)
        state.setSlider(Key.contrast, in: section, to: contrast)
        state.setSlider(Key.highlights, in: section, to: highlights)
        state.setSlider(Key.shadows, in: section, to: shadows)
        state.setSlider(Key.wbTemperature, in: section, to: wbTemperature)
        state.setSlider(Key.wbTint, in: section, to: wbTint)
        state.setSlider(Key.vibrance, in: section, to: vibrance)
        state.setSlider(Key.saturation, in: section, to: saturation)
        state.setSlider(Key.curves, in: section, to: curves)
        state.setSlider(Key.autoDodgeBurn, in: section, to: autoDodgeBurn)
        for band in HueBand.allCases {
            state.setSlider(band.key, in: section, to: self[band])
        }
    }

    /// `true` when this group cannot change a single pixel. What
    /// ``RenderGraph`` uses to skip the node entirely.
    public var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && wbTemperature == 0 && wbTint == 0 && vibrance == 0 && saturation == 0
            && curves == 0 && autoDodgeBurn == 0 && hsl.allSatisfy { $0 == 0 }
    }

    /// Does the composite need the two-scale luminance analysis?
    ///
    /// Only "Auto D&B" does, and it is one of the two one-directional sliders, so
    /// this stays a `> 0` test. Worth a branch: four extra dispatches and the only
    /// allocation in the whole node besides the 4 kB curve LUT.
    public var needsDodgeBurnAnalysis: Bool { autoDodgeBurn > 0 }

    /// Does anything need the linear-light round trip (two `pow` per channel
    /// each way)? Exposure and both white-balance axes do; nothing else does.
    /// `!= 0`, not `> 0`: a slider at −40 is as much work as one at +40.
    var needsLinearLight: Bool { exposure != 0 || wbTemperature != 0 || wbTint != 0 }

    /// Total **absolute** HSL band amount, so the kernel and the reference can
    /// skip the whole band evaluation on the common "no HSL" document.
    ///
    /// Absolute, not signed: with bidirectional bands a signed sum is zero for
    /// `hslRed = +50, hslAqua = −50`, which is emphatically not "no HSL".
    var hslAbsoluteTotal: Double { hsl.reduce(0) { $0 + abs($1) } }
}
