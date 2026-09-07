// Phase 2 "Da" (skin) render node kernels.
//
// Compiled together with Spike/MetalSources/Shaders.metal into one MTLLibrary by
// MetalContext — see its doc comment for why the sources travel as copied
// *directories* and are compiled with makeLibrary(source:). This file must not
// redeclare anything Shaders.metal already declares.
//
// Same conventions as Shaders.metal:
//   image space   = pixels, origin top-left, y down;
//   texture space = normalised (u, v) in [0,1], same axes.
//
// **Value space: gamma-encoded sRGB, 0…1.** Not linear light. ADR-0007 measured
// the difference (the same epsilon smooths the darkest luminance decile 2.58x
// harder in linear light) and RenderQuality.pixelSpace fixes the choice. Every
// constant below — the shine knee, the dark-circle knee, the brighten gamma —
// is calibrated in that space and is meaningless in another one.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// 0. Copy
//
// Not a blit. `MTLBlitCommandEncoder.copy(from:to:)` requires the two textures
// to have the same pixel format, and the graph's destination is not always the
// source's format — the golden harness renders into RGBA32Float so a PSNR
// number is not capped by half-float output quantisation. A blit across those
// two produces garbage rather than an error, which is how this was found.
// rgba16Float -> rgba32Float through this kernel is exact: every half-float
// value is representable in float32.
// ---------------------------------------------------------------------------

struct RenderCopyParams {
    uint2 size;
};

kernel void rp_render_copy(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant RenderCopyParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    destination.write(source.read(gid), gid);
}

// ---------------------------------------------------------------------------
// 1. Mask rasterisation
//
// RPVision produces one 512x512 parsing crop per face plus an affine that puts
// it back on the photo. This pass walks the *destination* and pulls, so N faces
// cost one dispatch and overlapping faces combine with max() rather than with
// whatever order the CPU happened to submit them in.
// ---------------------------------------------------------------------------

struct SkinMaskParams {
    uint2 imageSize;
    uint2 maskSize;
    uint faceCount;
};

/// Row of the image->mask affine, as (a, c, tx) so that mask.x = dot(row, (x, y, 1)).
struct SkinMaskTransform {
    float3 rowX;
    float3 rowY;
};

kernel void rp_skin_mask(
    texture2d_array<float, access::sample> masks [[texture(0)]],
    texture2d<float, access::write> outMask [[texture(1)]],
    constant SkinMaskTransform *transforms [[buffer(0)]],
    constant SkinMaskParams &prm [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.imageSize.x || gid.y >= prm.imageSize.y) { return; }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                               filter::linear, mip_filter::none);
    float3 p = float3(float(gid.x) + 0.5, float(gid.y) + 0.5, 1.0);
    float2 extent = float2(prm.maskSize);
    float acc = 0.0;
    for (uint i = 0; i < prm.faceCount; ++i) {
        float2 mp = float2(dot(transforms[i].rowX, p), dot(transforms[i].rowY, p));
        // Explicit bounds test rather than clamp_to_edge addressing: a face crop
        // usually has non-zero skin coverage right at its border (the neck), and
        // clamping would smear that band across the whole frame.
        if (mp.x < 0.0 || mp.y < 0.0 || mp.x >= extent.x || mp.y >= extent.y) { continue; }
        acc = max(acc, masks.sample(bilinear, mp / extent, i).r);
    }
    outMask.write(float4(acc, acc, acc, 1.0), gid);
}

// ---------------------------------------------------------------------------
// 2. The "Da" composite
//
// Three inputs, one pass:
//   source — the incoming picture;
//   base   — the same picture through the guided filter (edge-preserving, radius
//            ~0.03 x face width): high-frequency skin texture removed, edges kept;
//   low    — the same picture through a large-radius double box blur (the guided
//            filter with epsilon >> any local variance degenerates to exactly
//            that, which GuidedFilterTests.hugeEpsilonIsDoubleBox proves), radius
//            ~0.15 x face width: the local colour/brightness the skin *should*
//            have.
//
// detail = source - base is pores and fine wrinkles.
// base - low is meso structure: cheek shading, dark circles, shine.
//
// The order below is fixed and the Double reference in RPEngineTests reproduces
// it step for step; changing it changes the picture, so it is part of the
// contract, not an implementation detail.
// ---------------------------------------------------------------------------

struct SkinCompositeParams {
    uint2 size;
    float smoothAmount;   // 0…1
    float keepTexture;    // 0…1
    float evenTone;       // 0…1
    float redness;        // 0…1
    float shine;          // 0…1
    float brighten;       // 0…1
    float darkCircle;     // 0…1
    float wrinkle;        // 0…1
};

// Rec.709 luma weights. Applied to gamma-encoded values, which is not
// photometric luminance — it is the same approximation Photoshop's blend modes
// make, and commands.js (the code this is ported from) worked the same way.
constant float3 kRPLuma = float3(0.2126, 0.7152, 0.0722);
/// Luma excess over the local mean at which shine removal reaches full strength.
constant float kRPShineKnee = 0.06;
/// Luma deficit below the local mean at which dark-circle lifting reaches full strength.
constant float kRPDarkKnee = 0.10;
/// Gamma applied at brighten = 100. Fitted to commands.js's "Sáng da" curve
/// [[0,0],[64,74],[128,143],[255,255]]: 0.25 -> 0.290 needs gamma 0.893 and
/// 0.50 -> 0.561 needs 0.835; 0.86 is between them and monotone everywhere.
constant float kRPBrightenGamma = 0.86;

kernel void rp_skin_composite(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> base [[texture(1)]],
    texture2d<float, access::read> low [[texture(2)]],
    texture2d<float, access::read> mask [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant SkinCompositeParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 src = source.read(gid);
    float m = mask.read(gid).r;

    // Bit-exact passthrough outside the mask. Every operation below is a mix()
    // that is the identity at m == 0, but the final clamp is not, and "slider at
    // 0 changes nothing" has to hold for out-of-range values too.
    float active = m * (prm.smoothAmount + prm.evenTone + prm.redness + prm.shine
                        + prm.brighten + prm.darkCircle + prm.wrinkle);
    if (!(active > 0.0)) {
        destination.write(src, gid);
        return;
    }

    float3 I = src.rgb;
    float3 S = base.read(gid).rgb;
    float3 L = low.read(gid).rgb;
    float3 detail = I - S;
    float3 c = I;

    // 1. Mịn da + Giữ texture.
    //    keepTexture = 0 -> the plain guided-filter layer (ADR-0007's `amount`);
    //    keepTexture = 1 -> S + detail == I, i.e. the smoothing is cancelled.
    c = mix(c, S + detail * prm.keepTexture, prm.smoothAmount * m);

    // 2. Đều màu da. commands.js used a heavy Gaussian in Photoshop's "Color"
    //    blend at 55 %: take hue+saturation from the blur, keep luminance. Here:
    //    rescale the blurred colour to the current luma, then cross-fade.
    {
        float lumC = dot(c, kRPLuma);
        float lumL = dot(L, kRPLuma);
        float3 evened = L * (lumC / max(lumL, 1e-4));
        c = mix(c, evened, prm.evenTone * m);
    }

    // 3. Khử đỏ. "Redness" is the red channel's excess over the mean of the
    //    other two; only the part *above* the local mean is a blotch, the rest is
    //    the subject's skin tone and must survive.
    {
        float excess = max((c.r - 0.5 * (c.g + c.b)) - (L.r - 0.5 * (L.g + L.b)), 0.0);
        c.r -= prm.redness * m * excess;
    }

    // 4. Khử bóng dầu. commands.js: blurred layer, "Darken" blend at 70 %.
    //    Weighted by how much brighter than its neighbourhood the pixel is, so a
    //    uniformly lit cheek is not dimmed along with the T-zone.
    {
        float w = saturate((dot(c, kRPLuma) - dot(L, kRPLuma)) / kRPShineKnee);
        c = mix(c, min(c, L), prm.shine * m * w);
    }

    // 5. Sáng da.
    c = mix(c, pow(max(c, 0.0), float3(kRPBrightenGamma)), prm.brighten * m);

    // 6. Quầng thâm. The "Lighten" counterpart of step 4, weighted by how much
    //    *darker* than its neighbourhood the pixel is. See the node's doc comment
    //    for why this is not restricted to the eye sockets yet.
    {
        float w = saturate((dot(L, kRPLuma) - dot(c, kRPLuma)) / kRPDarkKnee);
        c = mix(c, max(c, L), prm.darkCircle * m * w);
    }

    // 7. Nếp nhăn. Fine wrinkles are the negative half of the high-frequency
    //    residual; filling only the negative half leaves highlights untouched.
    c -= prm.wrinkle * m * min(detail, 0.0);

    destination.write(float4(clamp(c, 0.0, 1.0), src.a), gid);
}
