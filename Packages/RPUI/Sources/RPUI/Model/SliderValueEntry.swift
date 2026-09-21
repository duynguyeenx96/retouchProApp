import Foundation
import RPCore
import RPEngine

/// What a slider row's number **means** — both directions of it: the string
/// drawn next to the label, and the reading of a string the user typed back into
/// that spot (2026-09-21, user request: "click vào số để gõ giá trị chính xác",
/// the way Lightroom and Photoshop let you type into a slider's readout).
///
/// It is a value type in the model layer rather than two closures on the view so
/// that the conversion is testable without a window — `SliderValueEntryTests`
/// is the whole contract — and so the *display* and the *parse* of one row can
/// never disagree: they are the same case of the same enum.
enum SliderValueUnit: Equatable, Sendable {
    /// The raw slider amount is the value: "40", "+40", "-40". Every row in the
    /// app except one, because an amount already *is* the value there (Phơi
    /// sáng's EV is derived from it, Bão hoà's % is it).
    case amount

    /// Kelvin, for "Nhiệt độ" (`wbTemperature`): shows the temperature the
    /// amount declares (docs/ADR-0023 `WhiteBalance.declaredKelvin`) and reads a
    /// typed number back as a **literal Kelvin**, not as a slider amount.
    ///
    /// Typing Kelvin is the deliberate choice, not an accident of the display
    /// string: the row prints "5200K" precisely because the raw −100…100 means
    /// nothing to a photographer (commit b3edace), so making them type that raw
    /// number back would hand the meaninglessness straight back. Lightroom's
    /// Temp field is a Kelvin field, and this is that field.
    ///
    /// `neutral` is the photograph's own neutral — the same one the render node
    /// uses — because it is what decides how many mired one slider unit is
    /// worth.
    case kelvin(neutral: Double)
}

/// One row's number, formatted and parsed.
///
/// The `range` is the row's, so a typed value clamps **exactly the way a drag
/// does**: `RPSliderTrack.value(atFraction:in:)` clamps to the same bounds and
/// rounds to whole units, and so does ``parse(_:)``. There is one rounding rule
/// in this app, not two.
struct SliderValueEntry: Equatable, Sendable {
    var unit: SliderValueUnit = .amount
    var range: ClosedRange<Double> = Slider.range

    private var isBidirectional: Bool { range.lowerBound < 0 }

    /// The read-only text next to the label: "40", "+40", "5200K".
    ///
    /// An explicit sign on the bidirectional rows only, so a glance at the
    /// number says which half of the track the thumb is on without reading the
    /// thumb.
    func displayText(for value: Double) -> String {
        switch unit {
        case .amount:
            let rounded = Int(value.rounded())
            return isBidirectional && rounded > 0 ? "+\(rounded)" : "\(rounded)"
        case .kelvin:
            return "\(Int(kelvin(for: value).rounded()))K"
        }
    }

    /// What the text field is pre-filled with when editing starts: the same
    /// number with nothing a parser would have to strip — no "+", no "K" — so
    /// the field round-trips if the user commits it untouched.
    func editText(for value: Double) -> String {
        switch unit {
        case .amount: return "\(Int(value.rounded()))"
        case .kelvin: return "\(Int(kelvin(for: value).rounded()))"
        }
    }

    /// The unit drawn after the field while editing, so "5200" in a box still
    /// reads as a temperature. Empty for a plain amount.
    var unitSuffix: String {
        switch unit {
        case .amount: return ""
        case .kelvin: return "K"
        }
    }

    /// A typed string back to a **raw slider amount**, clamped to ``range`` and
    /// rounded the same way a drag is.
    ///
    /// `nil` means "that is not a number" — the caller reverts to the value it
    /// already had rather than writing something. Nothing here can return a
    /// value outside the range, so the document cannot be corrupted by typing.
    func parse(_ text: String) -> Double? {
        guard let number = Self.number(in: text) else { return nil }
        switch unit {
        case .amount:
            return clampToRange(number)
        case .kelvin(let neutral):
            let amount = WhiteBalance.amount(declaringKelvin: number, neutralKelvin: neutral)
            // `amount` is −1…1; the document stores −100…100.
            return clampToRange(amount * 100)
        }
    }

    /// The temperature one raw amount declares. `/100` because the slider stores
    /// −100…100 and `WhiteBalance` speaks −1…1 — the same division
    /// `ColorRenderNode` does, which is why the label and the pixels agree.
    ///
    /// Rounded to the nearest 50 K on the way out, because the 201 steps of the
    /// slider land on temperatures like 5193.7 K and no camera or photographer
    /// thinks in those.
    private func kelvin(for value: Double) -> Double {
        guard case .kelvin(let neutral) = unit else { return value }
        let exact = WhiteBalance.declaredKelvin(
            amount: clampToRange(value) / 100, neutralKelvin: neutral)
        return (exact / 50).rounded() * 50
    }

    private func clampToRange(_ value: Double) -> Double {
        guard value.isFinite else { return Slider.defaultValue }
        return min(range.upperBound, max(range.lowerBound, value)).rounded()
    }

    /// The number inside whatever the user typed, or `nil`.
    ///
    /// Tolerant of the three things a real keyboard produces and `Double.init`
    /// rejects: the "K" the field itself draws (typed back by habit), the
    /// Unicode minus U+2212 the display uses, and a decimal **comma** — this app
    /// is Vietnamese, where "5,5" is five and a half. Thousands separators are
    /// *not* stripped: "5.200" would then be ambiguous with "5.2", and a wrong
    /// guess writes a wrong temperature silently, which is worse than refusing.
    static func number(in text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "\u{2212}", with: "-")
        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        if cleaned.lowercased().hasSuffix("k") { cleaned = String(cleaned.dropLast()) }
        if cleaned.hasPrefix("+") { cleaned = String(cleaned.dropFirst()) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let number = Double(cleaned), number.isFinite else { return nil }
        return number
    }
}
