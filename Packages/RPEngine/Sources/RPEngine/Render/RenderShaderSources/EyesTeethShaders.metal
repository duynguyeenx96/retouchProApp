// Phase 2 "Mắt / Răng" (eyes / teeth) render node kernel.
//
// Compiled together with Spike/MetalSources/Shaders.metal and
// Render/RenderShaderSources/SkinShaders.metal into ONE MTLLibrary by
// MetalContext (see MetalContext.shaderSources). The three files are
// concatenated in that fixed order and compiled in a single
// makeLibrary(source:) call, so adding this group costs **no extra compile** —
// still one per process, which is what RenderGraph.prewarm() relies on.
//
// Because it is one translation unit, this file must not redeclare anything the
// two earlier files declare. It deliberately *reuses* two of them:
//   * `kRPLuma`   — the Rec.709 luma weights from SkinShaders.metal;
//   * `rp_skin_mask` — the (entirely generic, despite the name) mask
//     rasterisation kernel, driven from Swift by `MaskRasteriser`.
//
// Same conventions as the other two files:
//   image space = pixels, origin top-left, y down;
//   **value space = gamma-encoded sRGB, 0…1** (RenderQuality.pixelSpace,
//   ADR-0007). Every knee below is a distance in that space and is meaningless
//   in linear light.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// The "Mắt / Răng" composite
//
// Four sliders, one pass, two masks and one blurred layer:
//
//   source — the incoming picture;
//   low    — the same picture through a double box blur (the guided filter with
//            epsilon >> any local variance degenerates to exactly that, which
//            GuidedFilterTests.hugeEpsilonIsDoubleBox proves) at radius
//            ~0.05 x face width, i.e. roughly half an eye / half a mouth. It is
//            the local reference this file compares against: "brighter than its
//            own surroundings" is what separates sclera from iris and teeth from
//            lips, gums, tongue and shadow;
//   eyeMask — feathered CelebAMask-HQ l_eye + r_eye coverage;
//   mouthMask — feathered CelebAMask-HQ `mouth`, which is the mouth *interior*.
//
// **There is no teeth mask and no sclera mask, because no such class exists.**
// CelebAMask-HQ's 19 classes have `mouth` (the gap between the lips) and
// `l_eye`/`r_eye` (the whole eye opening: sclera + iris + pupil). Spike S2 §3c
// settled that the whiten-teeth slider must derive teeth from luminance inside
// `mouth`; the same argument applies to sclera inside the eye opening. Both use
// `rp_et_whiten_weight` below.
// ---------------------------------------------------------------------------

struct EyesTeethParams {
    uint2 size;
    float eyeBrighten;     // 0…1
    float eyeDefinition;   // 0…1
    float scleraWhiten;    // 0…1
    float teethWhiten;     // 0…1
};

/// Gamma applied at "Sáng mắt" = 100. Deliberately the same number as
/// `kRPBrightenGamma` in SkinShaders.metal, which was fitted to commands.js's
/// "Sáng da" curve — there is no separate measured curve for eyes, and inventing
/// a second constant would imply one exists.
constant float kRPEyeBrightenGamma = 0.86;
/// Local-contrast gain at "Nét mắt" = 100. 1.0 means the pixel's departure from
/// its local mean is doubled.
constant float kRPEyeDefinitionGain = 1.0;
/// Luma excess over the local mean at which the sclera / teeth weight saturates.
/// Same scale as `kRPShineKnee`, and for the same reason: it is the size of a
/// meaningful local brightness step in gamma-encoded sRGB.
constant float kRPWhitenLumaKnee = 0.06;
/// Saturation above which a pixel is not sclera. Loose: a bloodshot or pink
/// sclera is exactly the case the slider exists for, so it must not be excluded
/// by its own tint. The iris is rejected by the luma term, not by this one.
constant float kRPScleraSatKnee = 0.60;
/// Saturation above which a pixel is not a tooth. Tighter than the sclera knee:
/// inside the mouth interior the competition is lips, gums and tongue, all of
/// which are strongly red, while a yellow tooth sits well below this.
constant float kRPTeethSatKnee = 0.40;
/// How much of the chroma is removed at slider 100.
constant float kRPWhitenChroma = 0.85;
/// How far the result is then lifted toward white at slider 100.
constant float kRPWhitenLift = 0.10;

/// How much a pixel looks like sclera / teeth: bright for its neighbourhood and
/// close to neutral.
///
/// `c` is the current colour, `L` its local mean, `satKnee` the group's
/// saturation cut-off. Returns 0…1.
static inline float rp_et_whiten_weight(float3 c, float3 L, float satKnee)
{
    float lift = saturate((dot(c, kRPLuma) - dot(L, kRPLuma)) / kRPWhitenLumaKnee);
    float hi = max(c.r, max(c.g, c.b));
    float lo = min(c.r, min(c.g, c.b));
    float sat = (hi - lo) / max(hi, 1e-4);
    float neutral = saturate(1.0 - sat / satKnee);
    return lift * neutral;
}

/// The whitened version of a colour: most of the chroma removed at constant
/// luma, then a small lift toward white. Splitting it this way (rather than
/// "add white") is what keeps a yellow tooth from turning grey-brown: the
/// desaturation is on the luma-preserving axis, so only the cast is removed.
static inline float3 rp_et_whiten(float3 c)
{
    float3 grey = float3(dot(c, kRPLuma));
    float3 w = mix(c, grey, kRPWhitenChroma);
    return w + (1.0 - w) * kRPWhitenLift;
}

kernel void rp_eyes_teeth_composite(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> low [[texture(1)]],
    texture2d<float, access::read> eyeMask [[texture(2)]],
    texture2d<float, access::read> mouthMask [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant EyesTeethParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 src = source.read(gid);
    float e = eyeMask.read(gid).r;
    float t = mouthMask.read(gid).r;

    // Bit-exact passthrough wherever nothing applies. Every step below is the
    // identity at amount 0, but the final clamp is not, and "slider at 0 changes
    // nothing" has to hold for out-of-range values too.
    float active = e * (prm.eyeBrighten + prm.eyeDefinition + prm.scleraWhiten)
                 + t * prm.teethWhiten;
    if (!(active > 0.0)) {
        destination.write(src, gid);
        return;
    }

    float3 c = src.rgb;
    float3 L = low.read(gid).rgb;

    // 1. Sáng mắt. A gamma lift inside the eye mask — the whole eye opening,
    //    catchlight and iris included, which is what "brighten the eyes" means
    //    in every editor that has the slider.
    c = mix(c, pow(max(c, 0.0), float3(kRPEyeBrightenGamma)), prm.eyeBrighten * e);

    // 2. Nét mắt. Local contrast at the eye's own scale: push the pixel away
    //    from its local mean. Not a pixel-scale sharpen — see the node's doc
    //    comment for what that does and does not buy.
    c = c + (c - L) * (prm.eyeDefinition * e * kRPEyeDefinitionGain);

    // 3. Trắng lòng trắng, inside the eye mask, weighted toward the sclera.
    {
        float w = rp_et_whiten_weight(c, L, kRPScleraSatKnee);
        c = mix(c, rp_et_whiten(c), prm.scleraWhiten * e * w);
    }

    // 4. Trắng răng, inside the mouth *interior* mask, weighted toward teeth.
    {
        float w = rp_et_whiten_weight(c, L, kRPTeethSatKnee);
        c = mix(c, rp_et_whiten(c), prm.teethWhiten * t * w);
    }

    destination.write(float4(clamp(c, 0.0, 1.0), src.a), gid);
}
