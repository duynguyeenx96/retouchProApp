import CoreGraphics
import Foundation
import Testing

import RPCore
import RPEngine
@testable import RPUI

/// The two slider interactions added on 2026-09-21 — **typing a value into the
/// number**, and **double-clicking the track to reset it** — reduced to the two
/// pure pieces that carry all of their rules: ``SliderValueEntry`` (format and
/// parse) and ``DoubleActivation`` (was that the second click?).
///
/// Neither SwiftUI gesture recognition nor a keyboard can be driven from a unit
/// test, so what is pinned here is everything that decides *what value gets
/// written*: the clamping, the reverting, the Kelvin conversion and the reset.
/// The recognisers themselves are the reviewer's job on a device.
@Suite("Slider value entry")
struct SliderValueEntryTests {

    // MARK: - Typed values: clamping and reverting

    @Test("A typed number clamps to the row's range, exactly like a drag")
    func typedValuesClamp() {
        let oneWay = SliderValueEntry(unit: .amount, range: Slider.range)
        #expect(oneWay.parse("40") == 40)
        #expect(oneWay.parse("0") == 0)
        #expect(oneWay.parse("100") == 100)
        #expect(oneWay.parse("250") == 100)
        #expect(oneWay.parse("-30") == 0)
        // Whole units, the same rounding `RPSliderTrack.value(atFraction:)` does.
        #expect(oneWay.parse("40.6") == 41)

        let signed = SliderValueEntry(unit: .amount, range: Slider.signedRange)
        #expect(signed.parse("-40") == -40)
        #expect(signed.parse("+40") == 40)
        #expect(signed.parse("-999") == -100)
        #expect(signed.parse("999") == 100)
        // The display's Unicode minus, typed or pasted back.
        #expect(signed.parse("\u{2212}40") == -40)
        // Vietnamese decimal comma.
        #expect(signed.parse("40,4") == 40)

        // Nothing a parse can return is outside the range.
        for text in ["1e9", "-1e9", "99999999999"] {
            let value = signed.parse(text)
            #expect(value == nil || Slider.signedRange.contains(value!), "\(text)")
        }
    }

    @Test("Anything that is not a number reverts instead of writing")
    func invalidInputReverts() {
        let entry = SliderValueEntry(unit: .amount, range: Slider.signedRange)
        for text in ["", "   ", "abc", "--5", "4 5", "+", "-", "?", "5/2", "nan", "inf"] {
            #expect(entry.parse(text) == nil, "\(text) should not parse")
        }
    }

    @Test("The number a row shows is the number its field starts with")
    func displayAndEditTextAgree() {
        let signed = SliderValueEntry(unit: .amount, range: Slider.signedRange)
        #expect(signed.displayText(for: 40) == "+40")
        #expect(signed.displayText(for: -40) == "-40")
        #expect(signed.displayText(for: 0) == "0")
        // The field drops the "+" so it round-trips untouched…
        #expect(signed.editText(for: 40) == "40")
        #expect(signed.parse(signed.editText(for: 40)) == 40)
        #expect(signed.parse(signed.editText(for: -40)) == -40)

        let oneWay = SliderValueEntry(unit: .amount, range: Slider.range)
        #expect(oneWay.displayText(for: 40) == "40")
        #expect(oneWay.unitSuffix.isEmpty)
    }

    // MARK: - "Nhiệt độ": the field is Kelvin, not slider units

    /// The decision, stated so a reviewer can check it in one place: the
    /// `wbTemperature` field takes a **literal Kelvin**, the way Lightroom's
    /// Temp field does, and converts it back through the exact inverse of
    /// `WhiteBalance.declaredKelvin`.
    @Test("Typing a Kelvin writes the amount that declares that Kelvin")
    func kelvinFieldTakesKelvin() throws {
        let entry = SliderValueEntry(
            unit: .kelvin(neutral: WhiteBalance.defaultNeutralKelvin),
            range: Slider.signedRange)

        // The neutral is 0 — the identity render, exactly.
        #expect(entry.parse("6500") == 0)
        #expect(entry.displayText(for: 0) == "6500K")

        // A warm declaration is the negative half (cooler picture), per ADR-0023.
        let warm = try #require(entry.parse("3200"))
        #expect(warm < 0)
        #expect(entry.displayText(for: warm) == "3200K")
        let cool = try #require(entry.parse("9000"))
        #expect(cool > 0)
        #expect(entry.displayText(for: cool) == "9000K")

        // Out of reach clamps to the endpoints rather than refusing.
        #expect(entry.parse("1000") == -100)
        #expect(entry.parse("99000") == 100)
        #expect(entry.displayText(for: -100) == "2000K")
        #expect(entry.displayText(for: 100) == "50000K")

        // The "K" the row itself draws, typed back by habit.
        #expect(entry.parse("5200K") == entry.parse("5200"))
        #expect(entry.parse("banana") == nil)

        // The field pre-fills with the temperature, not the raw amount, and the
        // suffix is drawn beside it rather than inside it.
        #expect(entry.editText(for: warm) == "3200")
        #expect(entry.unitSuffix == "K")
    }

    /// Every displayable temperature comes back as an amount that displays the
    /// same temperature: typing what the row already shows never moves it.
    @Test("Kelvin display → field → parse → display is a fixed point")
    func kelvinRoundTripsThroughTheField() throws {
        let entry = SliderValueEntry(
            unit: .kelvin(neutral: WhiteBalance.defaultNeutralKelvin),
            range: Slider.signedRange)
        for step in -100...100 {
            let amount = Double(step)
            let shown = entry.displayText(for: amount)
            let typed = try #require(entry.parse(entry.editText(for: amount)), "\(step)")
            #expect(entry.displayText(for: typed) == shown, "\(step): \(shown)")
        }
    }

    /// The display used to feed the raw −100…100 straight into
    /// `WhiteBalance.declaredKelvin`, which clamps at ±1 — so every warm value
    /// read "2000K" and every cool one "50000K" (the bug in commit b3edace).
    /// The row divides by 100 now, the same as `ColorRenderNode` does.
    @Test("The shown Kelvin is the one the render node computes, not the clamped one")
    func kelvinDisplayMatchesTheRenderNode() throws {
        let entry = SliderValueEntry(
            unit: .kelvin(neutral: WhiteBalance.defaultNeutralKelvin),
            range: Slider.signedRange)
        #expect(entry.displayText(for: 40) != "50000K")
        #expect(entry.displayText(for: -40) != "2000K")
        for amount in [-80.0, -40, -10, 10, 40, 80] {
            let expected = WhiteBalance.declaredKelvin(
                amount: amount / 100, neutralKelvin: WhiteBalance.defaultNeutralKelvin)
            let shown = entry.displayText(for: amount).dropLast()
            let value = try #require(Double(shown))
            #expect(abs(value - expected) <= 25, "\(amount): \(shown) vs \(expected)")
        }
    }

    // MARK: - Double-click resets to neutral

    @Test("Two quick clicks in the same spot are a double; slow or far apart are not")
    func doubleActivationRecognises() {
        var detector = DoubleActivation()
        #expect(detector.register(x: 100, at: 0) == false)
        #expect(detector.register(x: 104, at: 0.12) == true)

        // Too slow.
        detector = DoubleActivation()
        #expect(detector.register(x: 100, at: 0) == false)
        #expect(detector.register(x: 100, at: 0.9) == false)

        // Too far.
        detector = DoubleActivation()
        #expect(detector.register(x: 100, at: 0) == false)
        #expect(detector.register(x: 180, at: 0.1) == false)

        // A drag is never half of a double, in either position.
        detector = DoubleActivation()
        #expect(detector.register(x: 100, at: 0) == false)
        #expect(detector.register(x: 100, at: 0.1, isStationary: false) == false)
        #expect(detector.register(x: 100, at: 0.2) == false)

        // A triple click is one reset and then a fresh first click, not two.
        detector = DoubleActivation()
        #expect(detector.register(x: 100, at: 0) == false)
        #expect(detector.register(x: 100, at: 0.1) == true)
        #expect(detector.register(x: 100, at: 0.2) == false)
    }

    /// The call path the gesture takes: a single click writes the value under
    /// the pointer, a double writes `Slider.defaultValue` — on a one-directional
    /// row and on a bidirectional one alike, because "neutral" is 0 in both.
    @Test("A double-click writes the neutral, a single one writes where it landed")
    func doubleClickWritesTheNeutral() {
        #expect(
            RPSliderTrack.activationValue(atFraction: 0.75, in: Slider.range, isDouble: false)
                == 75)
        #expect(
            RPSliderTrack.activationValue(atFraction: 0.75, in: Slider.range, isDouble: true)
                == Slider.defaultValue)
        #expect(
            RPSliderTrack.activationValue(
                atFraction: 0.75, in: Slider.signedRange, isDouble: false) == 50)
        #expect(
            RPSliderTrack.activationValue(
                atFraction: 0.75, in: Slider.signedRange, isDouble: true) == 0)
        #expect(Slider.defaultValue == 0)
    }

    /// What the row does with a committed field, spelled out as the three rules
    /// the view's `commitDraft()` follows, so a regression in any of them is a
    /// test failure and not a screenshot.
    @Test("A disabled row and an unchanged value write nothing")
    func commitRules() {
        let entry = SliderValueEntry(unit: .amount, range: Slider.range)
        // 1. Out of range clamps (never rejected, never out of bounds).
        #expect(entry.parse("140") == 100)
        // 2. Not a number → nil → the view writes nothing and reverts.
        #expect(entry.parse("x") == nil)
        // 3. The same number back → the view compares and skips the write, so
        //    opening and closing a field is not a disk write.
        #expect(entry.parse(entry.editText(for: 40)) == 40)
    }
}
