import Foundation
import Testing
import simd

@testable import RPEngine

/// The "Nhiệt độ" slider's colour science, on the CPU, with **no GPU and no
/// image** — docs/ADR-0023.
///
/// These are the tests that can be checked against something outside this
/// repository: a published Bradford matrix, the CIE's own definition of
/// Illuminant A, and the arithmetic identities the mapping has to satisfy. The
/// GPU side (does the kernel compute this?) is `ColorRenderNodeTests`' golden
/// PSNR; what is here is *is the formula right in the first place*, which a
/// golden against a reference written from the same specification cannot say.
@Suite("White balance — Kelvin, mired and Bradford")
struct WhiteBalanceTests {

    /// Luminance-normalised gain a linear white gets, i.e. what the kernel
    /// actually applies to a neutral pixel.
    static func whiteGain(amount: Double, neutralKelvin: Double = 6500) -> SIMD3<Double> {
        let m = WhiteBalance.linearRGBGain(amount: amount, neutralKelvin: neutralKelvin)
        let w = m * SIMD3<Double>(1, 1, 1)
        let luma = 0.2126 * w.x + 0.7152 * w.y + 0.0722 * w.z
        return w / luma
    }

    // MARK: - Against published numbers

    /// The Bradford transform from D65 to D50 is the single most-published
    /// chromatic adaptation matrix there is — every ICC v4 profile carries it,
    /// and Bruce Lindbloom prints it as the worked example of the formula this
    /// file implements. If our `M_A`, our `M_A⁻¹` and our multiplication order
    /// are right, we must reproduce it to the digit.
    ///
    /// > Lindbloom, B. *Chromatic Adaptation*, brucelindbloom.com.
    /// > White points: D65 = (0.95047, 1, 1.08883), D50 = (0.96422, 1, 0.82521).
    @Test("Bradford reproduces Lindbloom's published D65 → D50 matrix")
    func bradfordMatchesLindbloomsWorkedExample() {
        let published: [[Double]] = [
            [1.0478112, 0.0228866, -0.0501270],
            [0.0295424, 0.9904844, -0.0170491],
            [-0.0092345, 0.0150436, 0.7521316],
        ]
        let m = WhiteBalance.bradfordXYZ(
            sourceWhite: SIMD3(0.95047, 1.00000, 1.08883),
            destinationWhite: SIMD3(0.96422, 1.00000, 0.82521))
        var worst = 0.0
        for i in 0..<3 {
            for j in 0..<3 { worst = max(worst, abs(m[i, j] - published[i][j])) }
        }
        print("WB Bradford D65->D50 vs Lindbloom: max abs difference = \(worst)")
        #expect(worst < 1e-6, "off the published matrix by \(worst)")
    }

    /// CIE Standard Illuminant A **is** a Planckian radiator at 2856 K, and the
    /// CIE fixes its chromaticity at (0.44757, 0.40745). That is a definition,
    /// not a measurement, so it is the one point on the locus we can check
    /// without trusting a second approximation. The other rows are the published
    /// locus table, which is why their bar is looser.
    @Test("The Planckian locus lands on the published chromaticities")
    func planckianLocusMatchesPublishedChromaticities() {
        let published: [(Double, Double, Double)] = [
            (2000, 0.52670, 0.41330),
            (2856, 0.44757, 0.40745),  // CIE Illuminant A, by definition
            (4000, 0.38050, 0.37680),
            (6500, 0.31350, 0.32360),
            (10000, 0.28070, 0.28840),
            (25000, 0.25190, 0.25240),
        ]
        var worst = 0.0
        for (kelvin, x, y) in published {
            let c = WhiteBalance.planckianChromaticity(kelvin: kelvin)
            let d = hypot(c.x - x, c.y - y)
            print("WB locus \(Int(kelvin)) K: (\(c.x), \(c.y)) vs published (\(x), \(y)) — \(d)")
            worst = max(worst, d)
        }
        #expect(worst < 1e-3, "the locus is off a published chromaticity by \(worst)")
    }

    /// Adapting there and back is the identity — the property that says the
    /// diagonal is being built in the right space and inverted, not merely
    /// scaled.
    ///
    /// The bar is 1e-6 and not 0 because ``WhiteBalance/bradfordFromCone`` is
    /// Lindbloom's **published, 7-digit** `M_A⁻¹` rather than a numerically
    /// exact inverse of `M_A`; the two round-trip to 4.4e-7. Taking the
    /// published constants is the deliberate choice (the point is to ship the
    /// citable matrix, not a slightly different one), and 4.4e-7 on a value in
    /// 0…1 is a tenth of an 8-bit code value — which is also why the kernel
    /// short-circuits `amount == 0` to a literal identity instead of letting
    /// this residue through.
    @Test("An adaptation composed with its reverse is the identity")
    func adaptationComposesBackToTheIdentity() {
        var worst = 0.0
        for (a, b) in [(2000.0, 6500.0), (6500.0, 50000.0), (3200.0, 7400.0)] {
            let round = WhiteBalance.bradfordXYZ(sourceKelvin: a, destinationKelvin: b)
                * WhiteBalance.bradfordXYZ(sourceKelvin: b, destinationKelvin: a)
            for i in 0..<3 {
                for j in 0..<3 {
                    worst = max(worst, abs(round[i, j] - (i == j ? 1 : 0)))
                }
            }
        }
        print("WB round-trip adaptation vs identity: max abs = \(worst)")
        #expect(worst < 1e-6, "the adaptation does not invert (\(worst))")
    }

    // MARK: - The mapping

    @Test("The mired mapping hits the neutral at 0 and the two endpoints at ±1")
    func theMiredMappingHitsItsEndpoints() {
        for neutral in [6500.0, 3200.0, 7400.0] {
            #expect(WhiteBalance.declaredKelvin(amount: 0, neutralKelvin: neutral) == neutral)
            let warm = WhiteBalance.declaredKelvin(amount: -1, neutralKelvin: neutral)
            let cool = WhiteBalance.declaredKelvin(amount: 1, neutralKelvin: neutral)
            #expect(abs(warm - WhiteBalance.warmFloorKelvin) < 1e-6)
            #expect(abs(cool - WhiteBalance.coolCeilingKelvin) < 1e-6)
            // …and the half-way point is half-way in MIRED, not in Kelvin,
            // which is the whole reason this mapping exists.
            let half = WhiteBalance.declaredKelvin(amount: -0.5, neutralKelvin: neutral)
            let expected =
                (WhiteBalance.mired(neutral) + WhiteBalance.mired(WhiteBalance.warmFloorKelvin)) / 2
            #expect(abs(WhiteBalance.mired(half) - expected) < 1e-9)
            print(
                "WB neutral \(neutral) K: -100 → \(warm) K, -50 → \(half) K, +100 → \(cool) K")
        }
    }

    /// The invariant `RPCore/EditState` states in words: *0 is the identity, for
    /// every photograph*. Not "within a tolerance" — the matrix is short-
    /// circuited precisely so this is exact, because `M_A⁻¹ · M_A` is not.
    @Test("0 is the exact identity for any neutral")
    func zeroIsExactlyTheIdentity() {
        for neutral in [2000.0, 5000.0, 6500.0, 9000.0, 50000.0] {
            #expect(WhiteBalance.linearRGBGain(amount: 0, neutralKelvin: neutral) == .identity)
            let m = WhiteBalance.matrix(amount: 0, neutralKelvin: neutral)
            #expect(m == matrix_identity_float3x3)
        }
        // A neutral the request could never supply must still land on D65 rather
        // than on a NaN.
        #expect(WhiteBalance.neutralKelvin(nil) == WhiteBalance.defaultNeutralKelvin)
        #expect(WhiteBalance.neutralKelvin(.nan) == WhiteBalance.defaultNeutralKelvin)
        #expect(WhiteBalance.neutralKelvin(0) == WhiteBalance.defaultNeutralKelvin)
        #expect(WhiteBalance.neutralKelvin(6816) == 6816)
    }

    /// The sign convention docs/ADR-0016 shipped and the UI prints
    /// (`+ ấm hơn · − lạnh hơn`). Positive maps to a *higher* declared Kelvin,
    /// which is the confusing half of Lightroom's convention and exactly why it
    /// gets its own test rather than a comment.
    @Test("Positive warms and negative cools, monotonically")
    func positiveWarmsAndNegativeCools() {
        var previous = -Double.infinity
        for step in stride(from: -100, through: 100, by: 10) {
            let w = Self.whiteGain(amount: Double(step) / 100)
            let ratio = w.x / w.z
            print("WB amount \(step): white gain \(w), R/B = \(ratio)")
            #expect(ratio > previous, "R/B is not monotone at \(step)")
            previous = ratio
        }
        #expect(Self.whiteGain(amount: 1).x > Self.whiteGain(amount: 1).z, "+100 is not warm")
        #expect(Self.whiteGain(amount: -1).x < Self.whiteGain(amount: -1).z, "−100 is not cool")
        #expect(Self.whiteGain(amount: 0) == SIMD3(1, 1, 1))
    }

    /// The number the whole change exists to move. The previous formula was a
    /// fixed `pow(1 ± 0.22, amount)` von Kries diagonal with no colour
    /// temperature in it at all; expressed as the colour-temperature shift it
    /// was equivalent to, its **entire** travel was smaller than an 85 filter.
    @Test("The new range is several times the 0.22 von Kries gain it replaces")
    func theNewRangeIsMuchWiderThanTheOldGain() {
        // The old shader, restated: gain = pow(1 ± 0.22, amount), renormalised.
        func oldWhiteGain(_ amount: Double) -> SIMD3<Double> {
            let g = SIMD3(pow(1.22, amount), 1.0, pow(0.78, amount))
            let luma = 0.2126 * g.x + 0.7152 * g.y + 0.0722 * g.z
            return g / luma
        }
        /// The slider amount whose R/B ratio matches `target`, by bisection.
        func amountMatching(_ target: Double) -> Double {
            var lo = -1.0
            var hi = 1.0
            for _ in 0..<80 {
                let mid = (lo + hi) / 2
                let w = Self.whiteGain(amount: mid)
                if w.x / w.z < target { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        let oldWarm = oldWhiteGain(1)
        let oldCool = oldWhiteGain(-1)
        let warmEquivalent = amountMatching(oldWarm.x / oldWarm.z)
        let coolEquivalent = amountMatching(oldCool.x / oldCool.z)
        let neutral = WhiteBalance.mired(6500)
        func shift(_ amount: Double) -> Double {
            neutral - WhiteBalance.mired(
                WhiteBalance.declaredKelvin(amount: amount, neutralKelvin: 6500))
        }
        print(
            "WB old +100 (R/B \(oldWarm.x / oldWarm.z)) == new \(warmEquivalent * 100), "
                + "i.e. \(shift(warmEquivalent)) mired of \(shift(1)) available")
        print(
            "WB old -100 (R/B \(oldCool.x / oldCool.z)) == new \(coolEquivalent * 100), "
                + "i.e. \(shift(coolEquivalent)) mired of \(shift(-1)) available")
        // The cooling direction is the one the photographer complained about,
        // and it is where the old formula was worst: its whole travel was under
        // a sixth of the new one's.
        #expect(abs(coolEquivalent) < 0.2, "the old cool end was worth \(coolEquivalent * 100)")
        #expect(abs(warmEquivalent) < 0.5, "the old warm end was worth \(warmEquivalent * 100)")
    }

    /// A tungsten cast, built from **published** locus chromaticities rather
    /// than from `planckianChromaticity`, so the cast and the correction do not
    /// share a possible error. If Kim et al. were wrong the residual would not
    /// cancel.
    @Test("A 3200 K cast is neutralised, where the old gain could not reach it")
    func aTungstenCastIsNeutralised() {
        func whitePoint(_ x: Double, _ y: Double) -> SIMD3<Double> {
            SIMD3(x / y, 1, (1 - x - y) / y)
        }
        func normalised(_ m: Matrix3) -> Matrix3 {
            let w = m * SIMD3<Double>(1, 1, 1)
            let luma = 0.2126 * w.x + 0.7152 * w.y + 0.0722 * w.z
            return Matrix3(rows: m.rows.map { $0 / luma })
        }
        // Published CIE Planckian-locus chromaticities, typed in here rather
        // than computed: a neutral developed for daylight but lit at 3200 K.
        let cast = normalised(
            WhiteBalance.xyzToLinearSRGB
                * (WhiteBalance.bradfordXYZ(
                    sourceWhite: whitePoint(0.3135, 0.3236),
                    destinationWhite: whitePoint(0.4234, 0.3990))
                    * WhiteBalance.linearSRGBToXYZ))
        let casted = cast * SIMD3<Double>(0.4, 0.4, 0.4)
        let castSpread = casted.max() - casted.min()

        var best = (spread: Double.infinity, amount: 0.0, output: SIMD3<Double>())
        for step in stride(from: -100.0, through: 100.0, by: 0.1) {
            let m = normalised(
                WhiteBalance.linearRGBGain(amount: step / 100, neutralKelvin: 6500))
            let out = m * casted
            let spread = out.max() - out.min()
            if spread < best.spread { best = (spread, step, out) }
        }
        // The old formula at the furthest it could go.
        let oldGain = SIMD3(pow(1.22, -1.0), 1.0, pow(0.78, -1.0))
        let oldLuma = 0.2126 * oldGain.x + 0.7152 * oldGain.y + 0.0722 * oldGain.z
        let oldOut = casted * (oldGain / oldLuma)
        let oldSpread = oldOut.max() - oldOut.min()

        print("WB 3200 K cast on a 0.4 linear grey: \(casted), channel spread \(castSpread)")
        print("WB corrected at slider \(best.amount): \(best.output), spread \(best.spread)")
        print("WB old formula at its −100 endpoint: \(oldOut), spread \(oldSpread)")
        #expect(castSpread > 0.5, "the fixture is not actually cast")
        #expect(best.spread < 0.002, "the cast was not neutralised (\(best.spread))")
        #expect(abs(best.amount) < 90, "no headroom left past the correction")
        #expect(
            oldSpread > 20 * best.spread,
            "the old formula was not measurably worse (\(oldSpread) vs \(best.spread))")
    }

    // MARK: - Plumbing

    /// Metal's `float3x3` is column-major and every matrix in this file is
    /// written row-major, so the transpose has exactly one place to go wrong.
    @Test("The float32 hand-off to Metal is column-major")
    func simdHandOffIsColumnMajor() {
        let m = Matrix3(rows: [SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9)])
        let f = m.simdFloat
        // columns.0 is the first COLUMN, i.e. (1, 4, 7).
        #expect(f.columns.0 == SIMD3<Float>(1, 4, 7))
        #expect(f.columns.1 == SIMD3<Float>(2, 5, 8))
        #expect(f.columns.2 == SIMD3<Float>(3, 6, 9))
        // …so `f * v` in Metal is the same product as `m * v` here.
        let v = SIMD3<Double>(0.3, 0.5, 0.2)
        let expected = m * v
        let actual = f * SIMD3<Float>(0.3, 0.5, 0.2)
        for i in 0..<3 { #expect(abs(Double(actual[i]) - expected[i]) < 1e-6) }
    }

    /// The neutral changes how much a slider unit is worth and nothing else.
    @Test("A different neutral rescales the slider without moving its zero")
    func theNeutralRescalesButDoesNotMoveZero() {
        let warmNeutral = 3200.0
        let coolNeutral = 9000.0
        #expect(WhiteBalance.linearRGBGain(amount: 0, neutralKelvin: warmNeutral) == .identity)
        #expect(WhiteBalance.linearRGBGain(amount: 0, neutralKelvin: coolNeutral) == .identity)
        // A photograph already shot warm has less room left to cool by, in
        // mired, and more to warm by — which is the point of anchoring the
        // mapping on the photograph rather than on a constant.
        func coolRoom(_ n: Double) -> Double {
            WhiteBalance.mired(WhiteBalance.warmFloorKelvin) - WhiteBalance.mired(n)
        }
        print("WB cool room: 3200 K \(coolRoom(warmNeutral)), 9000 K \(coolRoom(coolNeutral)) mired")
        #expect(coolRoom(warmNeutral) < coolRoom(coolNeutral))
        // And the same slider value means a bigger move on the cooler photo.
        let a = Self.whiteGain(amount: -0.5, neutralKelvin: warmNeutral)
        let b = Self.whiteGain(amount: -0.5, neutralKelvin: coolNeutral)
        #expect(b.z / b.x > a.z / a.x)
    }
}
