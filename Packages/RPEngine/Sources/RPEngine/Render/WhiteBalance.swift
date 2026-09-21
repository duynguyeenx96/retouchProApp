import Foundation
import simd

/// The colour science behind the "Nhiệt độ" (`wbTemperature`) slider: a real
/// correlated-colour-temperature control, mapped linearly in **mired** and
/// applied as a **Bradford chromatic adaptation transform**.
///
/// Pure arithmetic, no GPU, no Metal, no image — so every number below is
/// testable on the CPU (`WhiteBalanceTests`) and the `Double` golden reference
/// can reproduce it from this specification rather than from the shader.
/// docs/ADR-0023 records the decision, the sources and the measurements.
///
/// ## What the slider means
///
/// The slider value is the **colour temperature the user declares the scene
/// light was**, exactly the way Lightroom's "Temp" slider is defined. Declare a
/// higher Kelvin ("the light was bluer than I thought") and the correction warms
/// the picture; declare a lower one and it cools it. That is why *positive =
/// warmer* — the convention docs/ADR-0016 already shipped and the UI already
/// prints (`+ ấm hơn · − lạnh hơn`) — even though the Kelvin number it maps to
/// goes *up* on the positive side.
///
/// ## Why mired and not Kelvin
///
/// Equal steps in **mired** (`10⁶ / K`) are roughly equal perceptual steps along
/// the Planckian locus, which Kelvin steps are emphatically not: 2000→3000 K is
/// a violent change and 24000→25000 K is invisible. Mired is also what makes the
/// wildly asymmetric 2000…50000 K range expressible on a symmetric −100…100
/// slider without a non-linear fudge:
///
/// ```
/// neutralMired = 10⁶ / neutralKelvin
/// declaredMired = neutralMired + |amount| · (endpointMired − neutralMired)
///     endpoint = coolCeilingKelvin (20 mired) when amount > 0  → warms
///     endpoint = warmFloorKelvin  (500 mired) when amount < 0  → cools
/// ```
///
/// At `amount == 0` the declared temperature **is** the neutral, the adaptation
/// is the identity, and the render is bit-exact the source — the invariant every
/// slider in this project keeps (`RPCore/Slider`: "a slider whose neutral is not
/// its default is not allowed anywhere"). The two halves are deliberately *not*
/// symmetric in strength: from a 6500 K neutral the cool half is 346 mired wide
/// and the warm half only 134, because that is what the Planckian locus actually
/// looks like and what Lightroom's own 2000…50000 K range does.
///
/// ## Why the neutral is a parameter and not a constant
///
/// `amount == 0` has to mean *this photograph's* neutral, and the neutral is what
/// decides how many mired one slider unit is worth. `RenderRequest`
/// carries it (``RenderRequest/referenceColorTemperatureKelvin``); `nil` falls
/// back to ``defaultNeutralKelvin``. docs/ADR-0023 records what is actually
/// available from a real a6300 file today, which is: nothing, out of EXIF.
public enum WhiteBalance {

    // MARK: - The range

    /// Neutral used when the request carries none — D65, the white point sRGB is
    /// encoded against, so "no information" and "the file is an ordinary sRGB
    /// image" are the same assumption.
    public static let defaultNeutralKelvin = 6500.0

    /// Declared temperature at `amount == -1`: the coolest the picture can be
    /// pushed. Lightroom's floor, and the warmest light a photographer plausibly
    /// shoots under (candle / deep tungsten).
    public static let warmFloorKelvin = 2000.0

    /// Declared temperature at `amount == +1`: the warmest the picture can be
    /// pushed. Lightroom's ceiling.
    public static let coolCeilingKelvin = 50000.0

    /// `10⁶ / kelvin`.
    public static func mired(_ kelvin: Double) -> Double { 1_000_000 / max(kelvin, 1) }

    /// The neutral a request asks for, guarded against nonsense.
    public static func neutralKelvin(_ requested: Double?) -> Double {
        guard let requested, requested.isFinite, requested >= 1000, requested <= 100_000 else {
            return defaultNeutralKelvin
        }
        return requested
    }

    /// The temperature `amount` (−1…1) declares, given this photograph's neutral.
    ///
    /// Linear in mired on each side, hitting the neutral exactly at 0 and the two
    /// endpoints exactly at ±1.
    public static func declaredKelvin(amount: Double, neutralKelvin: Double) -> Double {
        let a = min(max(amount, -1), 1)
        let neutral = mired(neutralKelvin)
        guard a != 0 else { return neutralKelvin }
        let endpoint = mired(a > 0 ? coolCeilingKelvin : warmFloorKelvin)
        let declared = neutral + abs(a) * (endpoint - neutral)
        return 1_000_000 / declared
    }

    /// The exact inverse of ``declaredKelvin(amount:neutralKelvin:)``: the amount
    /// (−1…1) whose declared temperature is `kelvin`.
    ///
    /// Needed because the "Nhiệt độ" row is typed into in **Kelvin**, not in
    /// slider units (2026-09-21): the row prints "5200K", so the number a
    /// photographer types back into it is a temperature, the way Lightroom's Temp
    /// field works. The UI reads it here rather than inverting the mired formula
    /// a second time next to the text field, so the two directions cannot drift.
    ///
    /// Same mired-linear interpolation, solved for `|a|`:
    /// `|a| = (declaredMired − neutralMired) / (endpointMired − neutralMired)`,
    /// with the *cool* endpoint (fewer mired than neutral) on the positive side —
    /// which is what makes positive = warmer, as the type's note explains.
    ///
    /// Out-of-reach temperatures clamp to ±1 rather than returning nil: a typed
    /// "1000" means "as warm as this slider goes", which is exactly −1.
    public static func amount(declaringKelvin kelvin: Double, neutralKelvin: Double) -> Double {
        guard kelvin.isFinite else { return 0 }
        let neutral = mired(neutralKelvin)
        let declared = mired(kelvin)
        guard declared != neutral else { return 0 }
        let isWarming = declared < neutral
        let endpoint = mired(isWarming ? coolCeilingKelvin : warmFloorKelvin)
        let span = endpoint - neutral
        guard span != 0 else { return 0 }
        let magnitude = min(1, max(0, (declared - neutral) / span))
        return isWarming ? magnitude : -magnitude
    }

    // MARK: - Planckian locus

    /// CIE 1931 `xy` of a blackbody at `kelvin`, by the **Kim et al. (2002)**
    /// cubic-spline approximation — the one Wikipedia's "Planckian locus" article
    /// and Bruce Lindbloom both publish, transcribed coefficient for coefficient.
    ///
    /// > Kim, Y., Lee, S., Kim, H., & Kim, J. (2002). *Design of Advanced Color
    /// > Temperature Control System for HDTV Applications.* Journal of the Korean
    /// > Physical Society, 41(6), 865–871.
    ///
    /// **Stated validity is 1667 K … 25000 K**, and ``coolCeilingKelvin`` is
    /// 50000 K, i.e. the cool end extrapolates. That is measured rather than
    /// waved through (docs/ADR-0023): against a numerical integration of Planck's
    /// law over the CIE 1931 2° observer the extrapolation to 50000 K is off by
    /// **0.0004** in `xy`, an order of magnitude *less* than this fit's own error
    /// at 2000 K (**0.0036**) — which is inside its stated range and is the
    /// endpoint we actually ship on the warm side. Clamping the cool end to
    /// 25000 K would therefore have bought nothing but a 15 % narrower slider.
    public static func planckianChromaticity(kelvin: Double) -> (x: Double, y: Double) {
        let t = 1 / max(kelvin, 1)
        let x: Double =
            kelvin < 4000
            ? -0.266_123_9e9 * t * t * t - 0.234_358_9e6 * t * t + 0.877_695_6e3 * t + 0.179_910
            : -3.025_846_9e9 * t * t * t + 2.107_037_9e6 * t * t + 0.222_634_7e3 * t + 0.240_390
        let y: Double
        if kelvin < 2222 {
            y = -1.106_381_4 * x * x * x - 1.348_110_20 * x * x + 2.185_558_32 * x - 0.202_196_83
        } else if kelvin < 4000 {
            y = -0.954_947_6 * x * x * x - 1.374_185_93 * x * x + 2.091_370_15 * x - 0.167_488_67
        } else {
            y = 3.081_758_0 * x * x * x - 5.873_386_70 * x * x + 3.751_129_97 * x - 0.370_014_83
        }
        return (x, y)
    }

    /// `xy` → XYZ of a white normalised to `Y = 1`.
    public static func whitePoint(kelvin: Double) -> SIMD3<Double> {
        let c = planckianChromaticity(kelvin: kelvin)
        let y = max(c.y, 1e-6)
        return SIMD3(c.x / y, 1, (1 - c.x - c.y) / y)
    }

    // MARK: - Bradford chromatic adaptation

    /// XYZ → Bradford cone response (ρ, γ, β). Bruce Lindbloom, *Chromatic
    /// Adaptation*, the `M_A` matrix.
    static let bradfordToCone = Matrix3(rows: [
        SIMD3(0.895_100_0, 0.266_400_0, -0.161_400_0),
        SIMD3(-0.750_200_0, 1.713_500_0, 0.036_700_0),
        SIMD3(0.038_900_0, -0.068_500_0, 1.029_600_0),
    ])

    /// The published inverse of ``bradfordToCone`` (Lindbloom's `M_A⁻¹`). Taken
    /// from the reference rather than inverted here, so the constants are exactly
    /// the citable ones.
    static let bradfordFromCone = Matrix3(rows: [
        SIMD3(0.986_992_9, -0.147_054_3, 0.159_962_7),
        SIMD3(0.432_305_3, 0.518_360_3, 0.049_291_2),
        SIMD3(-0.008_528_7, 0.040_042_8, 0.968_486_7),
    ])

    /// Linear sRGB (D65) → XYZ. Lindbloom, *RGB/XYZ Matrices*, sRGB / D65.
    static let linearSRGBToXYZ = Matrix3(rows: [
        SIMD3(0.412_456_4, 0.357_576_1, 0.180_437_5),
        SIMD3(0.212_672_9, 0.715_152_2, 0.072_175_0),
        SIMD3(0.019_333_9, 0.119_192_0, 0.950_304_1),
    ])

    /// XYZ → linear sRGB (D65). Same source.
    static let xyzToLinearSRGB = Matrix3(rows: [
        SIMD3(3.240_454_2, -1.537_138_5, -0.498_531_4),
        SIMD3(-0.969_266_0, 1.876_010_8, 0.041_556_0),
        SIMD3(0.055_643_4, -0.204_025_9, 1.057_225_2),
    ])

    /// The Bradford transform that carries a colour seen under `sourceKelvin` to
    /// the colour it would be under `destinationKelvin`, in **XYZ**.
    ///
    /// `M = M_A⁻¹ · diag(ρ_d/ρ_s, γ_d/γ_s, β_d/β_s) · M_A` — Lindbloom's formula
    /// verbatim.
    public static func bradfordXYZ(sourceKelvin: Double, destinationKelvin: Double) -> Matrix3 {
        bradfordXYZ(
            sourceWhite: whitePoint(kelvin: sourceKelvin),
            destinationWhite: whitePoint(kelvin: destinationKelvin))
    }

    /// The same transform between two arbitrary white points. Split out from the
    /// Kelvin form so the published D65→D50 worked example (the matrix every ICC
    /// profile carries) can be checked against it directly —
    /// `WhiteBalanceTests.bradfordMatchesLindbloomsWorkedExample`.
    public static func bradfordXYZ(
        sourceWhite: SIMD3<Double>, destinationWhite: SIMD3<Double>
    ) -> Matrix3 {
        let source = bradfordToCone * sourceWhite
        let destination = bradfordToCone * destinationWhite
        let diagonal = Matrix3(diagonal: destination / source)
        return bradfordFromCone * (diagonal * bradfordToCone)
    }

    /// The gain the kernel applies, in the pipeline's **linear sRGB** working
    /// space, for a slider amount of `amount` (−1…1) on a photograph whose
    /// neutral is `neutralKelvin`.
    ///
    /// The adaptation runs **from the declared illuminant to the neutral one**:
    /// "the light was `declaredKelvin`; render it as if it had been the
    /// photograph's own neutral". Declare bluer light than the photo was shot
    /// under and the correction warms it, which is the direction the slider's
    /// sign promises.
    ///
    /// Exactly the identity at `amount == 0` — short-circuited rather than
    /// computed, because `M_A⁻¹ · I · M_A` and the two RGB/XYZ matrices only
    /// round-trip to ~1e-7 in float, and "0 changes nothing" is a bit-exact
    /// claim, not a tolerance.
    public static func linearRGBGain(amount: Double, neutralKelvin: Double) -> Matrix3 {
        guard amount != 0 else { return .identity }
        let declared = declaredKelvin(amount: amount, neutralKelvin: neutralKelvin)
        let xyz = bradfordXYZ(sourceKelvin: declared, destinationKelvin: neutralKelvin)
        return xyzToLinearSRGB * (xyz * linearSRGBToXYZ)
    }

    /// The same gain in the float32 column-major form `ColorParams.wbMatrix`
    /// hands to Metal.
    static func matrix(amount: Double, neutralKelvin: Double) -> simd_float3x3 {
        linearRGBGain(amount: amount, neutralKelvin: neutralKelvin).simdFloat
    }
}

/// A 3×3 of `Double`, row-major on the way in because every published colour
/// matrix is written that way, column-major on the way out because Metal's
/// `float3x3` is.
public struct Matrix3: Equatable, Sendable {
    /// `rows[i][j]` is row `i`, column `j`.
    public var rows: [SIMD3<Double>]

    public init(rows: [SIMD3<Double>]) {
        precondition(rows.count == 3)
        self.rows = rows
    }

    public init(diagonal d: SIMD3<Double>) {
        self.rows = [SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z)]
    }

    public static let identity = Matrix3(diagonal: SIMD3(1, 1, 1))

    public subscript(row: Int, column: Int) -> Double { rows[row][column] }

    public static func * (lhs: Matrix3, rhs: Matrix3) -> Matrix3 {
        var rows: [SIMD3<Double>] = []
        for i in 0..<3 {
            var row = SIMD3<Double>(0, 0, 0)
            for j in 0..<3 {
                var sum: Double = 0
                for k in 0..<3 { sum += lhs.rows[i][k] * rhs.rows[k][j] }
                row[j] = sum
            }
            rows.append(row)
        }
        return Matrix3(rows: rows)
    }

    public static func * (lhs: Matrix3, rhs: SIMD3<Double>) -> SIMD3<Double> {
        var out = SIMD3<Double>(0, 0, 0)
        for i in 0..<3 {
            var sum: Double = 0
            for k in 0..<3 { sum += lhs.rows[i][k] * rhs[k] }
            out[i] = sum
        }
        return out
    }

    /// Column-major float32, the layout `float3x3` expects.
    public var simdFloat: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(Float(rows[0][0]), Float(rows[1][0]), Float(rows[2][0])),
            SIMD3<Float>(Float(rows[0][1]), Float(rows[1][1]), Float(rows[2][1])),
            SIMD3<Float>(Float(rows[0][2]), Float(rows[1][2]), Float(rows[2][2])))
    }
}
