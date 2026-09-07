import Foundation

/// The fixed per-channel tone curve behind the "Curves" slider, and the 256-entry
/// LUT the kernel samples it through.
///
/// ## Why a fixed curve and not a knot editor
/// docs/PLAN.md Phase 2 lists "Curves" as one 0–100 slider in the Color group.
/// One slider cannot carry an arbitrary spline, so the slider is the **amount**
/// of a curve that is fixed here, and the machinery around it — a per-channel LUT
/// built on the CPU, uploaded once, sampled with a lerp in the shader — is the
/// part a later knot editor would need. Replacing this function with user knots
/// is then a data change: ``table()`` still returns 256 RGBA entries and
/// `rp_color_composite` still does three lookups. Nothing in the kernel knows
/// where the numbers came from.
///
/// ## The curve
/// A film-style response, deliberately *not* the same shape as the "Contrast"
/// slider (which is a symmetric smoothstep about mid-grey and touches neither
/// end):
///
/// ```
/// s(x)     = x·x·(3 − 2x)                      smoothstep, the S
/// mid(x)   = mix(x, s(x), 0.35)                a gentle S, not a hard one
/// f_c(x)   = toe_c + (1 − toe_c − shoulder_c) · mid(x)
/// ```
///
/// so `f(0) = toe` (lifted blacks — the matte film foot) and `f(1) = 1 −
/// shoulder` (rolled highlights). Monotone everywhere: a convex combination of
/// two monotone functions, scaled and shifted.
///
/// The three channels differ slightly, which is what makes the LUT *per channel*
/// rather than one curve stored three times: blue has the highest toe and red the
/// deepest shoulder, i.e. **cool shadows and warm highlights** — the split-tone a
/// film stock leaves. The side effect is real and stated: at high values the
/// slider moves the white balance a little. That is what the look is.
///
/// Values are gamma-encoded sRGB (`RenderQuality.pixelSpace`), like every other
/// constant in this package.
public enum ColorToneCurve {
    /// LUT entries. 256 because the curve is smooth and the source of the whole
    /// idea is 8-bit display-referred code (`panelpts/RetouchProUXP`); the shader
    /// lerps between entries, so the sampling error is second order in 1/255 —
    /// `ColorRenderNodeTests.lutSamplingErrorIsNegligible` measures it.
    public static let size = 256

    /// Black lift per channel (r, g, b).
    public static let toe = (r: 0.030, g: 0.035, b: 0.045)
    /// Highlight roll-off per channel (r, g, b).
    public static let shoulder = (r: 0.028, g: 0.020, b: 0.016)
    /// How much of the smoothstep S is mixed into the straight line.
    public static let sCurveAmount = 0.35

    /// The curve for one channel (0 = red, 1 = green, 2 = blue) at `x`.
    public static func value(_ x: Double, channel: Int) -> Double {
        let t = min(max(x, 0), 1)
        let s = t * t * (3 - 2 * t)
        let mid = t + (s - t) * sCurveAmount
        let (toe, shoulder) = limits(channel: channel)
        return toe + (1 - toe - shoulder) * mid
    }

    static func limits(channel: Int) -> (toe: Double, shoulder: Double) {
        switch channel {
        case 0: (toe.r, shoulder.r)
        case 1: (toe.g, shoulder.g)
        default: (toe.b, shoulder.b)
        }
    }

    /// The LUT as interleaved RGBA float32, `size` entries: entry `i` is the
    /// curve evaluated at `i / (size − 1)` in each channel. Alpha is 1 and unused.
    public static func table() -> [Float] {
        var out = [Float](repeating: 0, count: size * 4)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            for channel in 0..<3 {
                out[i * 4 + channel] = Float(value(x, channel: channel))
            }
            out[i * 4 + 3] = 1
        }
        return out
    }

    /// The lerped lookup the shader performs, in `Double`. Used by the reference
    /// and by the LUT-error measurement; the shipped path is the shader.
    public static func lookup(_ table: [Float], _ x: Double, channel: Int) -> Double {
        let u = min(max(x, 0), 1) * Double(size - 1)
        let i0 = min(size - 1, max(0, Int(u.rounded(.down))))
        let i1 = min(size - 1, i0 + 1)
        let f = u - Double(i0)
        let a = Double(table[i0 * 4 + channel])
        let b = Double(table[i1 * 4 + channel])
        return a + (b - a) * f
    }
}
