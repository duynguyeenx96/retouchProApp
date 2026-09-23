import Foundation

/// "Tự động v1" — one-tap auto retouch with a **fixed recipe**
/// (docs/PLAN.md §6.5, formula settled 2026-09-11 in "Cập nhật lần 3").
///
/// Not a render path and not a new `EditState` value: it is a ``Preset`` built
/// on the fly and applied through ``EditState/applying(_:mode:)`` like any other
/// preset. The one thing it adds is the **overall strength** ("cường độ tổng"):
/// a factor in `0...1` that scales every recipe value *before* the preset is
/// built. The factor is not stored anywhere — ``strength(in:)`` reads it back
/// off the document, so undo/redo, switching shots and reopening the project
/// all show the right position without a second piece of state that could
/// disagree with the sliders.
///
/// ## What it touches, and what it leaves alone
///
/// Exactly the four keys in ``recipe`` — **key-scoped, not section-scoped**.
/// Every other slider the user has already moved, including the other keys of
/// the same sections (Khử đỏ next to Mịn da, Exposure next to Auto D&B), is
/// untouched, and the "Mặt" reshape group is never in the recipe at all
/// (docs/PLAN.md §6.5: warping geometry wrongly is far more visible than
/// over-smoothing). The preset library replaces *whole sections* instead,
/// because a preset is a complete look for its sections; a four-key recipe is
/// not, and wiping the user's Exposure because auto wanted Dodge & Burn would
/// be surprising.
///
/// Inside those four keys the recipe is the whole truth: applying at strength
/// `s` sets each to `value × s`, whatever it was before — including `0` at
/// `s = 0`, which *removes* the key (the "absent == 0" storage rule). The
/// user's own pre-auto values for those keys are one Hoàn tác away.
public enum AutoRetouch {
    /// One recipe entry: a slider (section + key) and its value at full strength.
    public struct Ingredient: Hashable, Sendable {
        /// `EditState.SectionKey` namespace.
        public let section: String
        /// Parameter key inside the section — RPEngine's own key string. RPCore
        /// cannot import RPEngine, so `RPUITests.AutoRetouchWiringTests` pins
        /// these to `SkinSliders.Key` / `EyesTeethSliders.Key` /
        /// `ColorSliders.Key` (the same arrangement
        /// `Slider.oneDirectionalParameters` uses).
        public let key: String
        /// Value at strength 1, on the slider's own `0...100` scale.
        public let value: Double

        public init(section: String, key: String, value: Double) {
            self.section = section
            self.key = key
            self.value = value
        }
    }

    /// The v1 recipe, in the order the plan lists it:
    /// **Mịn da 30, Đều màu da 20, Sáng mắt 15, Auto D&B 40**.
    ///
    /// All four are one-directional `0...100` sliders — "Dodge & Burn tự động"
    /// is one of the two "Color" keys that stay one-directional
    /// (`Slider.oneDirectionalParameters`) — so scaling by `[0, 1]` can never
    /// leave the range.
    public static let recipe: [Ingredient] = [
        Ingredient(section: EditState.SectionKey.skin, key: "smooth", value: 30),
        Ingredient(section: EditState.SectionKey.skin, key: "evenTone", value: 20),
        Ingredient(section: EditState.SectionKey.eyesTeeth, key: "eyeBrighten", value: 15),
        Ingredient(section: EditState.SectionKey.color, key: "autoDodgeBurn", value: 40),
    ]

    /// Fixed so two builds of the recipe compare equal. Never written to
    /// `presets/` — the recipe is code, not a library entry.
    public static let presetID = PresetID("auto-retouch-v1")!

    /// The recipe's namespaces. Never contains `face`.
    public static var sectionNames: Set<String> { Set(recipe.map(\.section)) }

    /// Clamps a strength into `0...1`; a non-finite value reads as 0, the way
    /// `Slider.clamp` treats one.
    public static func clampStrength(_ strength: Double) -> Double {
        guard strength.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, strength))
    }

    /// The recipe as a ``Preset``, every value multiplied by `strength`
    /// (clamped to `0...1`). Zero values are dropped the way
    /// `EditSection(sliders:)` always drops them — which is why
    /// ``EditState/applyingAutoRetouch(strength:)`` clears the recipe keys the
    /// preset no longer carries.
    public static func preset(strength: Double) -> Preset {
        let s = clampStrength(strength)
        var sliders: [String: [String: Double]] = [:]
        for ingredient in recipe {
            sliders[ingredient.section, default: [:]][ingredient.key] = ingredient.value * s
        }
        return Preset(
            id: Self.presetID,
            name: "Tự động",
            createdAt: Date(timeIntervalSince1970: 0),
            sections: sliders.reduce(into: [:]) { sections, entry in
                let section = EditSection(sliders: entry.value, in: entry.key)
                if !section.isEmpty { sections[entry.key] = section }
            })
    }

    /// The strength the document is currently at, read back off the four
    /// recipe keys: `nil` when they are **not** a single multiple of the recipe
    /// (the user moved one of them by hand after applying, or never applied
    /// and had their own values there), otherwise that multiple in `0...1`.
    /// An untouched document reads as `0`.
    public static func strength(in state: EditState) -> Double? {
        let estimate = estimatedStrength(in: state)
        let tolerance = 0.05  // slider units; values are never rounded on write
        for ingredient in recipe {
            let actual = state.slider(ingredient.key, in: ingredient.section)
            if abs(actual - ingredient.value * estimate) > tolerance { return nil }
        }
        return estimate
    }

    /// The best single factor for the four recipe keys (least squares, clamped
    /// to `0...1`) — what the strength slider shows when ``strength(in:)`` is
    /// `nil`, so it sits near where the picture actually is rather than at 0.
    public static func estimatedStrength(in state: EditState) -> Double {
        var dot = 0.0
        var norm = 0.0
        for ingredient in recipe {
            dot += state.slider(ingredient.key, in: ingredient.section) * ingredient.value
            norm += ingredient.value * ingredient.value
        }
        guard norm > 0 else { return 0 }
        return clampStrength(dot / norm)
    }
}

extension EditState {
    /// This state with the auto recipe applied at `strength` (`0...1`).
    ///
    /// ``AutoRetouch/preset(strength:)`` goes through the ordinary
    /// ``applying(_:mode:)`` in `.merge` mode — which writes the four recipe
    /// keys and leaves every other key and section alone — and then clears any
    /// recipe key the scaled preset dropped for being 0, because `.merge`
    /// cannot remove a key. ``perImage`` is never touched.
    public func applyingAutoRetouch(strength: Double) -> EditState {
        let preset = AutoRetouch.preset(strength: strength)
        var result = applying(preset, mode: .merge)
        for ingredient in AutoRetouch.recipe
        where preset.sections[ingredient.section]?.values[ingredient.key] == nil {
            result.setSlider(ingredient.key, in: ingredient.section, to: Slider.defaultValue)
        }
        return result
    }
}
