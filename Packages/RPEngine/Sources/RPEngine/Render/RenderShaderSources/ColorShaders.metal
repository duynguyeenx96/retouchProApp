// Phase 2 "Color" render node kernels.
//
// Compiled together with Spike/MetalSources/Shaders.metal,
// Render/RenderShaderSources/SkinShaders.metal and
// Render/RenderShaderSources/EyesTeethShaders.metal into ONE MTLLibrary by
// MetalContext (see MetalContext.shaderSources). The four files are concatenated
// in that fixed order and compiled in a single makeLibrary(source:) call, so
// adding this group costs **no extra compile** — still one per process, which is
// what RenderGraph.prewarm() relies on.
//
// Because it is one translation unit, this file must not redeclare anything the
// three earlier files declare. It deliberately *reuses* `kRPLuma` from
// SkinShaders.metal.
//
// Same conventions as the other three files:
//   image space = pixels, origin top-left, y down;
//   **value space = gamma-encoded sRGB, 0…1** (RenderQuality.pixelSpace,
//   ADR-0007). Two steps below — Exposure and White Balance — are physically
//   linear-light operations and say so: they convert, scale and convert back
//   inside one branch. Everything else is display-referred on purpose, which is
//   also what Photoshop's Curves/Contrast do and what
//   `panelpts/RetouchProUXP/commands.js` was written against.
//
// Why Metal and not a CIFilter chain, given docs/PLAN.md §1.3 says "Core Image +
// kernel" for this row: docs/ADR-0012. Short version — a golden test against a
// documented Double reference is the plan's Phase 2 bar, and CIColorControls /
// CIVibrance / CIToneCurve / CITemperatureAndTint have no published formula to
// write a reference against.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// 1. Auto D&B analysis: two-scale luminance on a small grid
//
// Port of `dodgeBurnMaps` in panelpts/RetouchProUXP/autoskin.js. That function
// worked on the panel's analysis raster — width SMALL_W = 320, height in
// proportion — and blurred the luminance plane twice: rBig = 0.055 x width
// (the large modelling blocks, which must survive) and rSmall = 0.012 x width
// (sensor noise and pores, which must not drive the correction). The deviation
// `small - big` is the local block error: negative means "darker than its
// surroundings" (dodge), positive means "brighter" (burn).
//
// Keeping the analysis on a 320-wide grid is not an approximation of the panel,
// it *is* the panel: same grid, same two fractions, same floors. It is also what
// makes the slider affordable — the alternative, two full-resolution RGBA blur
// layers, is 384 MB at 24 MP for one slider.
//
// The gf box kernels in Shaders.metal are not reused here because they filter a
// *pair* of textures at one radius, and this needs one texture at two different
// radii; pairing them would compute each blur twice.
// ---------------------------------------------------------------------------

struct ColorAnalysisParams {
    uint2 sourceSize;
    uint2 analysisSize;
};

/// Box-averages the source's luminance into the analysis grid. A block average
/// rather than a point sample: point sampling would alias exactly the pore-scale
/// detail the small blur exists to reject.
kernel void rp_color_luma_downsample(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> outLuma [[texture(1)]],
    constant ColorAnalysisParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.analysisSize.x || gid.y >= prm.analysisSize.y) { return; }
    // Integer block bounds, so the CPU reference lands on the same pixels.
    uint x0 = gid.x * prm.sourceSize.x / prm.analysisSize.x;
    uint y0 = gid.y * prm.sourceSize.y / prm.analysisSize.y;
    uint x1 = max(x0 + 1u, (gid.x + 1u) * prm.sourceSize.x / prm.analysisSize.x);
    uint y1 = max(y0 + 1u, (gid.y + 1u) * prm.sourceSize.y / prm.analysisSize.y);
    x1 = min(x1, prm.sourceSize.x);
    y1 = min(y1, prm.sourceSize.y);

    float sum = 0.0;
    float n = 0.0;
    for (uint y = y0; y < y1; ++y) {
        for (uint x = x0; x < x1; ++x) {
            sum += dot(source.read(uint2(x, y)).rgb, kRPLuma);
            n += 1.0;
        }
    }
    outLuma.write(float4((n > 0.0) ? sum / n : 0.0), gid);
}

struct ColorBoxParams {
    uint2 size;
    int radius;
};

/// Single-channel horizontal box, clamp-to-edge.
kernel void rp_color_box_h(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ColorBoxParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    int maxX = int(prm.size.x) - 1;
    float acc = 0.0;
    float n = 0.0;
    for (int d = -prm.radius; d <= prm.radius; ++d) {
        int x = clamp(int(gid.x) + d, 0, maxX);
        acc += input.read(uint2(uint(x), gid.y)).r;
        n += 1.0;
    }
    output.write(float4(acc / n), gid);
}

/// Single-channel vertical box, clamp-to-edge.
kernel void rp_color_box_v(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ColorBoxParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    int maxY = int(prm.size.y) - 1;
    float acc = 0.0;
    float n = 0.0;
    for (int d = -prm.radius; d <= prm.radius; ++d) {
        int y = clamp(int(gid.y) + d, 0, maxY);
        acc += input.read(uint2(gid.x, uint(y))).r;
        n += 1.0;
    }
    output.write(float4(acc / n), gid);
}

// ---------------------------------------------------------------------------
// 2. The "Color" composite
//
// One pass, 18 slider values, three bound inputs besides the picture:
//
//   curveLUT — 256 x 1 RGBA32Float, the fixed film curve (ColorToneCurve);
//   dnbBig   — analysis-grid luminance, blurred at rBig, twice;
//   dnbSmall — analysis-grid luminance, blurred at rSmall, once.
//
// The two analysis textures are only read inside the Auto D&B branch, and are
// bound to the LUT texture when that slider is 0 — a valid binding that is never
// sampled, the same substitution the eyes/teeth composite makes for an unused
// layer.
//
// The step order below is fixed and the Double reference in RPEngineTests
// reproduces it step for step; changing it changes the picture, so it is part of
// the contract, not an implementation detail.
// ---------------------------------------------------------------------------

struct ColorParams {
    // float4 first so Metal's 16-byte alignment and Swift's agree with no
    // padding surprises in between (ColorRenderNodeTests pins the stride).
    //
    // Sixteen of the eighteen amounts are SIGNED, -1…1 (docs/ADR-0016); the two
    // marked 0…1 below are the ones that stayed one-directional. Every `> 0`
    // test on a signed amount had to become `!= 0`, and every sum used as an
    // "is anything on" test had to become a sum of absolute values — a signed
    // sum cancels (+50 exposure, -50 contrast) and would take the passthrough
    // branch on a picture the user has graded.
    float4 hslA;   // red, orange, yellow, green      — -1…1
    float4 hslB;   // aqua, blue, purple, magenta     — -1…1
    /// Linear-sRGB white-balance gain for `wbTemperature`, computed on the CPU
    /// by `WhiteBalance.linearRGBGain` (docs/ADR-0023): the slider is mapped
    /// linearly in **mired** to a declared colour temperature between 2000 K and
    /// 50000 K, and that becomes a **Bradford chromatic adaptation** from the
    /// declared illuminant to the photograph's own neutral.
    ///
    /// It is a matrix and not the old `float3` von Kries diagonal because a
    /// Bradford CAT is only diagonal in *cone* space; reduced to a diagonal in
    /// sRGB primaries it explodes (a 2000 K adaptation wants a 48x blue gain
    /// that way, against 6.5x through Bradford — measured, ADR-0023).
    ///
    /// **Exactly the identity when `wbTemperature == 0`**, short-circuited on the
    /// CPU rather than computed, so a render that only moves Exposure is
    /// bit-exact what it was before this matrix existed.
    ///
    /// Uniform over the frame, so the whole of the colour science is paid once
    /// per render on the CPU and the kernel pays one 3x3 multiply — which is
    /// *cheaper* than the three per-pixel `pow()` calls it replaces
    /// (docs/ADR-0016 filed that hoist as "a known move, not a discovery").
    float3x3 wbMatrix;
    uint2 size;
    uint2 analysisSize;
    float exposure;        // -1…1
    float contrast;        // -1…1
    float highlights;      // -1…1
    float shadows;         // -1…1
    float wbTemperature;   // -1…1
    float wbTint;          // -1…1
    float vibrance;        // -1…1
    float saturation;      // -1…1
    float curves;          //  0…1  (one-directional)
    float autoDodgeBurn;   //  0…1  (one-directional)
    uint curveLUTSize;
    // "Tạo khối" (Contour, docs/PLAN.md §6.2). 0 = the group is off, and every
    // line of the contour branch below is skipped — the render is then bit-exact
    // what it was before the group existed. The three sliders' amounts are not
    // here: they are already baked into each lobe's `strength`, because a lobe
    // belongs to exactly one of the three regions.
    uint contourLobeCount;
};

/// One soft ellipse of the contour mask, in image pixels. Must match
/// `ContourLobe` in ContourMask.swift field for field (the Swift side pins the
/// stride in a test).
struct ContourLobe {
    float2 centre;
    float2 axisU;        // unit; the short axis is its perpendicular (-y, x)
    float2 halfExtent;   // (along axisU, across it), pixels — always a fraction
                         // of faceWidth on the CPU side, never a pixel constant
    float strength;      // signed: + dodges (highlight), - burns (shadow)
    float pad;
};

/// Stops of exposure at slider ±100 — **five**, Lightroom's convention
/// (docs/ADR-0023). It was 1.0 until 2026-09-21, on the argument that "a portrait
/// that needs more than a stop needs a re-shoot"; that argument is wrong for the
/// one thing this group exists to do, which is *correct* a file that arrived
/// wrong, and a frame off the a6300 metered two stops down cannot be rescued by
/// a slider that stops at one. `exp2(amount * stops)` is symmetric in *stops*:
/// -100 is 1/32x, the exact inverse of +100's 32x, which a mirrored linear gain
/// (1 ± amount) would not be.
constant float kRPExposureStops = 5.0;
/// Green pulled down at "WB tint" = 100, i.e. toward magenta; pushed up (toward
/// green) at -100. Applied as pow(1 - gain, amount), so the two ends of the
/// slider are exact channel-wise inverses of each other.
///
/// Deliberately untouched by the 2026-09-21 temperature rework (docs/ADR-0023):
/// tint is the green/magenta axis *off* the Planckian locus, it has no Kelvin
/// meaning, and Lightroom keeps it on its own small relative scale too.
constant float kRPWBTintGain = 0.12;
/// Gamma applied to the brightest pixels at "Highlights" = 100. > 1 darkens; the
/// negative half uses its RECIPROCAL, so the two directions are symmetric in the
/// exponent's log space the same way exposure is symmetric in stops. A mirrored
/// mix (extrapolating past the gamma) was rejected: for shadows it sends a
/// near-black pixel below 0 and crushes it.
constant float kRPHighlightGamma = 1.45;
/// Luma at which highlight recovery starts ramping in.
constant float kRPHighlightPivot = 0.45;
/// Gamma applied to the darkest pixels at "Shadows" = 100. < 1 lifts; the
/// negative half uses its reciprocal (1/0.65 = 1.538) and deepens.
constant float kRPShadowGamma = 0.65;
/// Luma at which shadow lifting has ramped out.
constant float kRPShadowPivot = 0.55;
/// How much of the smoothstep S-curve is mixed in at "Contrast" = 100. At -100
/// the same number is used to EXTRAPOLATE away from the S-curve, which flattens
/// toward mid-grey. Still monotone (the mix's slope bottoms out at 1.5 - 0.5 *
/// max S' = 0.75) and still endpoint-preserving, because S(0) = 0 and S(1) = 1
/// hold for any mix weight.
constant float kRPContrastMax = 0.50;
/// Saturation change at "Vibrance" = ±100 on a fully unsaturated colour.
constant float kRPVibranceMax = 1.0;
/// How much vibrance is held back on the skin-tone hue band. 0.6 = 40 % of the
/// change survives there, in both directions, so a face neither clips nor goes
/// grey before the rest of the frame.
constant float kRPVibranceSkinProtect = 0.6;
/// Centre and half-width of that band, degrees. 25° is between "orange" (30°)
/// and the redder end of real skin.
constant float kRPVibranceSkinHue = 25.0;
constant float kRPVibranceSkinHalfWidth = 40.0;
/// Saturation change at "Saturation" = ±100: 1.0 means 2x at +100 and 0x —
/// grayscale — at -100. Linear in the multiplier, not exponential, precisely so
/// that -100 lands exactly on grayscale (an exponential 2^amount would only
/// reach 0.5x and never get there).
constant float kRPSaturationMax = 1.0;
/// Saturation change at one HSL band = ±100, once band weights are normalised.
constant float kRPHSLSatMax = 1.0;
/// Half-width of a hue band's triangular window, degrees.
constant float kRPHSLBandHalfWidth = 60.0;
/// Auto D&B: mask gain. autoskin.js used `k = strength / 50 * 9` on 0…255
/// luminance, i.e. `|dev| * 18` on 0…1 values at strength 100 — "one stop of
/// local error fills the mask".
constant float kRPDnBGain = 18.0;
/// Auto D&B dodge curve, fitted to commands.js's [[0,0],[128,146],[255,255]]:
/// x^0.8091 sends 128/255 to 146/255 exactly.
constant float kRPDodgeGamma = 0.8091;
/// Auto D&B burn curve, fitted to [[0,0],[128,110],[255,255]].
constant float kRPBurnGamma = 1.2199;

/// sRGB transfer function, gamma-encoded -> linear light.
static inline float3 rp_color_to_linear(float3 c)
{
    float3 x = max(c, 0.0);
    float3 lo = x / 12.92;
    float3 hi = pow((x + 0.055) / 1.055, 2.4);
    return select(hi, lo, x <= 0.04045);
}

/// Linear light -> gamma-encoded sRGB.
static inline float3 rp_color_to_srgb(float3 c)
{
    float3 x = max(c, 0.0);
    float3 lo = x * 12.92;
    float3 hi = 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    return select(hi, lo, x <= 0.0031308);
}

/// HSV hue in degrees, 0…360. Undefined for a neutral colour, where it returns
/// 0 — harmless, because every consumer multiplies by a saturation difference
/// that is zero there.
static inline float rp_color_hue(float3 c)
{
    float hi = max(c.r, max(c.g, c.b));
    float lo = min(c.r, min(c.g, c.b));
    float d = hi - lo;
    if (d <= 1e-6) { return 0.0; }
    float h;
    if (hi == c.r)      { h = fmod((c.g - c.b) / d, 6.0); }
    else if (hi == c.g) { h = (c.b - c.r) / d + 2.0; }
    else                { h = (c.r - c.g) / d + 4.0; }
    h *= 60.0;
    return (h < 0.0) ? h + 360.0 : h;
}

/// Triangular window on the hue circle.
static inline float rp_color_band_weight(float hue, float centre, float halfWidth)
{
    float d = fabs(hue - centre);
    d = min(d, 360.0 - d);
    return max(0.0, 1.0 - d / halfWidth);
}

/// Saturation scaling about the pixel's own luma. `k = 0` is the identity.
static inline float3 rp_color_saturation(float3 c, float k)
{
    float g = dot(c, kRPLuma);
    return float3(g) + (c - float3(g)) * (1.0 + k);
}

/// One channel of the curve LUT, linearly interpolated between entries.
static inline float rp_color_curve(
    texture2d<float, access::read> lut, uint n, float x, uint channel)
{
    float u = saturate(x) * float(n - 1u);
    uint i0 = uint(floor(u));
    uint i1 = min(i0 + 1u, n - 1u);
    float f = u - float(i0);
    float a = lut.read(uint2(i0, 0u))[channel];
    float b = lut.read(uint2(i1, 0u))[channel];
    return a + (b - a) * f;
}

/// Bilinear read of an analysis-grid texture at an image pixel centre.
///
/// Done by hand rather than through a `sampler`: a sampler's interpolation
/// weights are fixed-point and implementation-defined, and this value has to be
/// reproducible by a `Double` CPU reference to 45 dB.
static inline float rp_color_analysis(
    texture2d<float, access::read> t, uint2 gid, uint2 imageSize, uint2 n)
{
    float2 p =
        (float2(gid) + 0.5) * (float2(n) / float2(imageSize)) - 0.5;
    p = clamp(p, float2(0.0), float2(n) - 1.0);
    uint x0 = uint(floor(p.x));
    uint y0 = uint(floor(p.y));
    uint x1 = min(x0 + 1u, n.x - 1u);
    uint y1 = min(y0 + 1u, n.y - 1u);
    float fx = p.x - float(x0);
    float fy = p.y - float(y0);
    float a = t.read(uint2(x0, y0)).r;
    float b = t.read(uint2(x1, y0)).r;
    float c = t.read(uint2(x0, y1)).r;
    float d = t.read(uint2(x1, y1)).r;
    return mix(mix(a, b, fx), mix(c, d, fx), fy);
}

/// The contour mask at one pixel centre: the signed sum of every lobe, clamped
/// to -1…1.
///
/// Positive means "highlight here" and negative means "shadow here"; the caller
/// turns that into the *existing* dodge/burn LUT step. The falloff is
/// `1 - smoothstep(0, 1, r)` on the ellipse's normalised radius, i.e. 1 at the
/// centre and 0 at the rim with zero slope at both ends, so two overlapping lobes
/// blend and a lobe's rim never shows as an edge.
///
/// Summation order is the buffer's order and the clamp is last — the `Double` CPU
/// reference (`ContourMask.value(at:lobes:)`) does the same two things in the same
/// order, because a different order would be a different float32 sum.
static inline float rp_contour_mask(
    constant ContourLobe *lobes, uint count, uint2 gid)
{
    float2 p = float2(gid) + 0.5;
    float m = 0.0;
    for (uint i = 0; i < count; ++i) {
        float2 d = p - lobes[i].centre;
        float2 u = lobes[i].axisU;
        float a = dot(d, u) / lobes[i].halfExtent.x;
        float b = dot(d, float2(-u.y, u.x)) / lobes[i].halfExtent.y;
        float r2 = a * a + b * b;
        if (r2 >= 1.0) { continue; }
        float r = sqrt(r2);
        m += lobes[i].strength * (1.0 - r * r * (3.0 - 2.0 * r));
    }
    return clamp(m, -1.0, 1.0);
}

kernel void rp_color_composite(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> curveLUT [[texture(1)]],
    texture2d<float, access::read> dnbBig [[texture(2)]],
    texture2d<float, access::read> dnbSmall [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant ColorParams &prm [[buffer(0)]],
    constant ContourLobe *contourLobes [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 src = source.read(gid);

    // ABSOLUTE totals: the amounts are signed now, and a signed sum would read
    // "exposure +50, contrast -50" as "nothing is on" and return the source.
    float hslTotal = dot(fabs(prm.hslA), float4(1.0)) + dot(fabs(prm.hslB), float4(1.0));
    float active = fabs(prm.exposure) + fabs(prm.contrast) + fabs(prm.highlights)
                 + fabs(prm.shadows) + fabs(prm.wbTemperature) + fabs(prm.wbTint)
                 + fabs(prm.vibrance) + fabs(prm.saturation)
                 + prm.curves + prm.autoDodgeBurn + hslTotal;
    // Bit-exact passthrough with every slider at 0. Each step below is already
    // the identity at 0, but the final clamp is not, and "slider at 0 changes
    // nothing" has to hold for out-of-range inputs too.
    //
    // Contour is tested separately rather than added to `active`: its amounts do
    // not reach the kernel as scalars (they are baked into the lobes), and a
    // frame with contour up but every colour slider at 0 must still take the
    // branch below.
    if (!(active > 0.0) && prm.contourLobeCount == 0u) {
        destination.write(src, gid);
        return;
    }

    float3 c = src.rgb;

    // 1. Auto D&B. First, because its analysis was measured on the incoming
    //    picture: it is a correction of *this* frame's local luminance error,
    //    and every step after it is a global grade on the corrected frame.
    if (prm.autoDodgeBurn > 0.0) {
        float big = rp_color_analysis(dnbBig, gid, prm.size, prm.analysisSize);
        float small = rp_color_analysis(dnbSmall, gid, prm.size, prm.analysisSize);
        float dev = small - big;   // < 0 darker than its surroundings -> dodge
        float w = min(1.0, fabs(dev) * kRPDnBGain * prm.autoDodgeBurn);
        float g = (dev < 0.0) ? kRPDodgeGamma : kRPBurnGamma;
        c = mix(c, pow(max(c, 0.0), float3(g)), w);
    }

    // 1b. Contour ("Tạo khối", docs/PLAN.md §6.2). The SAME dodge/burn LUT step
    //     as Auto D&B above — same two gammas, same endpoint-preserving mix — with
    //     the landmark-anchored mask supplying the weight and the direction where
    //     Auto D&B has the frame's own local luminance error supply both. That is
    //     the whole difference between the two, and it is why this needed no new
    //     kernel: a contour is a dodge/burn that knows where the cheekbone is.
    //
    //     Immediately after Auto D&B and before the grade, for the same reason:
    //     it is a modelling correction of the incoming picture, and everything
    //     from step 2 on is a global grade of the corrected one.
    //
    //     Outside every lobe the mask is exactly 0, `w` is exactly 0, and `mix`
    //     with t = 0 returns `c` bit-for-bit — which is what makes "the forehead
    //     centre moved by exactly 0" a measurable claim and not a tolerance.
    if (prm.contourLobeCount > 0u) {
        float m = rp_contour_mask(contourLobes, prm.contourLobeCount, gid);
        float w = fabs(m);
        if (w > 0.0) {
            float g = (m > 0.0) ? kRPDodgeGamma : kRPBurnGamma;
            c = mix(c, pow(max(c, 0.0), float3(g)), w);
        }
    }

    // 2. Exposure + White Balance, in **linear light**. Both are scalings of the
    //    light that reached the sensor, so both belong here and not in the
    //    display-referred space the rest of this file works in; doing them
    //    together pays for the transfer function once.
    if (prm.exposure != 0.0 || prm.wbTemperature != 0.0 || prm.wbTint != 0.0) {
        float3 lin = rp_color_to_linear(c);
        lin *= exp2(prm.exposure * kRPExposureStops);
        // Temperature: the CPU-built Bradford adaptation matrix (see wbMatrix
        // above and docs/ADR-0023). Exactly the identity at wbTemperature == 0,
        // so "only Exposure moved" is still bit-exact.
        float3 adapted = prm.wbMatrix * lin;
        // Tint: unchanged from docs/ADR-0012 — one channel, one pow, no Kelvin.
        float3 tint = float3(1.0, pow(1.0 - kRPWBTintGain, prm.wbTint), 1.0);
        adapted *= tint;
        // Renormalise so the white balance changes the colour of the light and
        // not the amount of it: divide by what the pair does to a linear white.
        // kRPLuma's weights are the Rec.709 luminance coefficients, and here —
        // unlike everywhere else in this package — they are applied to genuinely
        // linear values, which is what they are for.
        float3 white = (prm.wbMatrix * float3(1.0)) * tint;
        adapted /= max(dot(white, kRPLuma), 1e-4);
        c = rp_color_to_srgb(adapted);
    }

    // 3. Highlights (recovery / push) and 4. Shadows (lift / deepen). Both are
    //    endpoint-preserving gammas weighted by luma, so neither can crush black
    //    or clip white, and a neutral stays neutral. The sign picks the gamma —
    //    g or 1/g — and the magnitude is the mix weight, so both directions stay
    //    inside [0,1] by construction.
    float luma = dot(c, kRPLuma);
    if (prm.highlights != 0.0) {
        float w = smoothstep(kRPHighlightPivot, 1.0, luma);
        float g = (prm.highlights > 0.0) ? kRPHighlightGamma : 1.0 / kRPHighlightGamma;
        c = mix(c, pow(max(c, 0.0), float3(g)), fabs(prm.highlights) * w);
    }
    if (prm.shadows != 0.0) {
        float w = 1.0 - smoothstep(0.0, kRPShadowPivot, luma);
        float g = (prm.shadows > 0.0) ? kRPShadowGamma : 1.0 / kRPShadowGamma;
        c = mix(c, pow(max(c, 0.0), float3(g)), fabs(prm.shadows) * w);
    }

    // 5. Contrast: a smoothstep S about mid-grey, mixed toward at a positive
    //    amount and extrapolated away from at a negative one (which flattens the
    //    picture toward mid-grey). Endpoint-preserving and monotone in BOTH
    //    directions, unlike the usual `pivot + (c - pivot) * gain`, which clips.
    if (prm.contrast != 0.0) {
        float3 x = saturate(c);
        c = mix(c, x * x * (3.0 - 2.0 * x), prm.contrast * kRPContrastMax);
    }

    // 6. Curves: the fixed per-channel film LUT (ColorToneCurve). ONE-DIRECTIONAL
    //    (0…1): extrapolating past 0 would send the curve's lifted toe (0.030)
    //    negative and crush the bottom 3 % of the range to black. docs/ADR-0016.
    if (prm.curves > 0.0) {
        float3 f = float3(
            rp_color_curve(curveLUT, prm.curveLUTSize, c.r, 0u),
            rp_color_curve(curveLUT, prm.curveLUTSize, c.g, 1u),
            rp_color_curve(curveLUT, prm.curveLUTSize, c.b, 2u));
        c = mix(c, f, prm.curves);
    }

    // 7. Vibrance: saturation weighted by how unsaturated the pixel already is,
    //    held back on the skin-tone hue band. Signed: the weight is unchanged and
    //    only `k` flips, so a negative vibrance desaturates the flattest colours
    //    first and leaves the already-vivid ones alone — the same asymmetry, run
    //    backwards, which is also what Adobe documents for negative Vibrance.
    if (prm.vibrance != 0.0) {
        float hi = max(c.r, max(c.g, c.b));
        float lo = min(c.r, min(c.g, c.b));
        float sat = (hi - lo) / max(hi, 1e-4);
        float skin = rp_color_band_weight(
            rp_color_hue(c), kRPVibranceSkinHue, kRPVibranceSkinHalfWidth);
        float k = prm.vibrance * kRPVibranceMax * saturate(1.0 - sat)
                * (1.0 - kRPVibranceSkinProtect * skin);
        c = rp_color_saturation(c, k);
    }

    // 8. Saturation: uniform. -1 takes the (1 + k) factor to exactly 0, i.e.
    //    grayscale, which is what a saturation slider at -100 has to be.
    if (prm.saturation != 0.0) {
        c = rp_color_saturation(c, prm.saturation * kRPSaturationMax);
    }

    // 9. HSL: per-hue-band saturation. The eight triangular windows are
    //    normalised by their sum, so they are a partition of unity: every band
    //    at ±100 is exactly step 8 at ±100, and no hue is moved twice for
    //    sitting between two centres. `amountSum` stays SIGNED — only the
    //    branch test above uses absolute values.
    if (hslTotal > 0.0) {
        float hue = rp_color_hue(c);
        float centres[8] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 280.0, 320.0 };
        float amounts[8] = {
            prm.hslA.x, prm.hslA.y, prm.hslA.z, prm.hslA.w,
            prm.hslB.x, prm.hslB.y, prm.hslB.z, prm.hslB.w
        };
        float weightSum = 0.0;
        float amountSum = 0.0;
        for (uint i = 0; i < 8; ++i) {
            float w = rp_color_band_weight(hue, centres[i], kRPHSLBandHalfWidth);
            weightSum += w;
            amountSum += w * amounts[i];
        }
        if (weightSum > 0.0) {
            c = rp_color_saturation(c, (amountSum / weightSum) * kRPHSLSatMax);
        }
    }

    destination.write(float4(clamp(c, 0.0, 1.0), src.a), gid);
}
