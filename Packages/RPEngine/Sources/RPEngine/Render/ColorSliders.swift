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
/// ## Every slider is 0–100, default 0, and moves in one direction
/// That is not a preference, it is forced. `EditSection.setSlider` **deletes** a
/// key set back to 0 (`RPCore/EditState.swift`), so "absent" and "neutral" have
/// to be the same number, and `Slider.clamp` pins the range at 0…100 for every
/// group in the project. A signed exposure or a temperature slider centred at 50
/// would make an *empty* `EditState` a non-identity render, which breaks the
/// contract every node in the graph is built on (`isIdentity` → the graph skips
/// the node → bit-exact passthrough).
///
/// So each slider has a direction, chosen and documented rather than implied:
///
/// | slider | direction at 100 |
/// |---|---|
/// | `exposure` | **brighter** (+1 EV) |
/// | `contrast` | more contrast |
/// | `highlights` | highlights pulled **down** (recovery) |
/// | `shadows` | shadows pulled **up** (lift) |
/// | `wbTemperature` | **warmer** |
/// | `wbTint` | toward **magenta** |
/// | `vibrance` | more saturation in the least saturated colours |
/// | `saturation` | more saturation, uniformly |
/// | `curves` | more of the fixed film curve |
/// | `hsl…` | more saturation in that hue band |
/// | `autoDodgeBurn` | more local-luminance evening |
///
/// The reverse of each (darken, desaturate, cool, …) needs either a signed range
/// or a paired key, and both are plan-level decisions about `Slider`, not changes
/// to this node — the same disclosure the "Mặt" group makes about its
/// one-directional reshape sliders (docs/ADR-0010).
public struct ColorSliders: Sendable, Equatable {
    /// **Exposure** — up to +1 EV, applied as a gain in **linear light**.
    public var exposure: Double = 0
    /// **Contrast** — a smoothstep S-curve about mid-grey.
    public var contrast: Double = 0
    /// **Highlights** — recovery: a >1 gamma weighted toward bright pixels.
    public var highlights: Double = 0
    /// **Shadows** — lift: a <1 gamma weighted toward dark pixels.
    public var shadows: Double = 0
    /// **WB, temperature axis** — warmer. A von Kries diagonal gain in linear
    /// light, renormalised so the frame's luminance does not move with it.
    public var wbTemperature: Double = 0
    /// **WB, tint axis** — toward magenta (green pulled down).
    public var wbTint: Double = 0
    /// **Vibrance** — saturation boost weighted by `1 − saturation`, damped on
    /// the skin-tone hues so a portrait's face is not the first thing to clip.
    public var vibrance: Double = 0
    /// **Saturation** — uniform, up to 2× at 100.
    public var saturation: Double = 0
    /// **Curves** — the amount of a fixed per-channel film curve (lifted toe,
    /// rolled shoulder, cool shadows / warm highlights), applied through a
    /// 256-entry LUT texture. Not a knot editor; see ``ColorToneCurve``.
    public var curves: Double = 0
    /// **Auto D&B** — the port of `panelpts/RetouchProUXP` `dodgeBurnMaps` +
    /// `autoDodgeBurn`: evens out local luminance blocks by dodging what is
    /// darker than its surroundings and burning what is brighter.
    public var autoDodgeBurn: Double = 0
    /// **HSL** — per-hue-band saturation, indexed by ``HueBand/rawValue``.
    /// Always ``HueBand/allCases``.count long; a shorter or longer array is
    /// padded/truncated by ``init(exposure:contrast:highlights:shadows:wbTemperature:wbTint:vibrance:saturation:curves:autoDodgeBurn:hsl:)``.
    public private(set) var hsl: [Double]

    public init(
        exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
        wbTemperature: Double = 0, wbTint: Double = 0, vibrance: Double = 0,
        saturation: Double = 0, curves: Double = 0, autoDodgeBurn: Double = 0,
        hsl: [Double] = []
    ) {
        self.exposure = Slider.clamp(exposure)
        self.contrast = Slider.clamp(contrast)
        self.highlights = Slider.clamp(highlights)
        self.shadows = Slider.clamp(shadows)
        self.wbTemperature = Slider.clamp(wbTemperature)
        self.wbTint = Slider.clamp(wbTint)
        self.vibrance = Slider.clamp(vibrance)
        self.saturation = Slider.clamp(saturation)
        self.curves = Slider.clamp(curves)
        self.autoDodgeBurn = Slider.clamp(autoDodgeBurn)
        self.hsl = HueBand.allCases.map { band in
            band.rawValue < hsl.count ? Slider.clamp(hsl[band.rawValue]) : 0
        }
    }

    /// One hue band's saturation slider.
    public subscript(band: HueBand) -> Double {
        get { hsl[band.rawValue] }
        set { hsl[band.rawValue] = Slider.clamp(newValue) }
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
    /// Only "Auto D&B" does. Worth a branch: it is four extra dispatches and the
    /// only allocation in the whole node besides the 4 kB curve LUT.
    public var needsDodgeBurnAnalysis: Bool { autoDodgeBurn > 0 }

    /// Does anything need the linear-light round trip (two `pow` per channel
    /// each way)? Exposure and both white-balance axes do; nothing else does.
    var needsLinearLight: Bool { exposure > 0 || wbTemperature > 0 || wbTint > 0 }

    /// Total HSL band amount, so the kernel and the reference can skip the whole
    /// band evaluation on the common "no HSL" document.
    var hslTotal: Double { hsl.reduce(0, +) }
}
