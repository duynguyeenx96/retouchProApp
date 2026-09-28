// Phase 5 "Tóc" (hair) render node kernel — docs/ADR-0026.
//
// Compiled into the same single MTLLibrary as every other render kernel
// (MetalContext.shaderSources), appended **last** so no earlier file's line
// numbers move. One translation unit, so this file reuses `kRPLuma` from
// SkinShaders.metal rather than redeclaring it; the mask is rasterised by the
// generic `rp_skin_mask` kernel through `MaskRasteriser`, like every other
// parsing mask.
//
// Conventions as in the other files:
//   image space = pixels, origin top-left, y down;
//   value space = gamma-encoded sRGB, 0…1 (RenderQuality.pixelSpace, ADR-0007).
//
// Inputs:
//   source   — the incoming picture;
//   low      — the source through a double box blur (guided filter, huge
//              epsilon) at ~0.08 x face width: the neighbourhood a sheen band is
//              brighter than. Bound to `source` when "Bóng tóc" is 0;
//   hairMask — feathered CelebAMask-HQ `hair` coverage.

#include <metal_stdlib>
using namespace metal;

/// Must match `HairParams` in HairRenderNode.swift; `HairRenderNodeTests` pins
/// the stride (48).
struct HairParams {
    uint2 size;
    float gloss;              // 0…1
    float dye;                // 0…1
    float lightnessExponent;  // 1 = untouched; computed on the CPU (HairSliders)
    float pad0;
    float pad1;
    float pad2;
    float4 dyeTint;           // rgb normalised to luma 1; a unused
};

/// Local-contrast gain at "Bóng tóc" = 100: a strand's departure from its
/// neighbourhood is increased by 60 %. Less than "Nét mắt"'s 100 % because hair
/// is a large textured area and doubling its contrast reads as crunchy.
constant float kRPHairGlossContrast = 0.6;
/// Luma excess over the local mean at which a pixel counts fully as sheen. Same
/// scale as `kRPWhitenLumaKnee` (a meaningful local step in gamma sRGB).
constant float kRPHairGlossKnee = 0.06;
/// How far a full-weight sheen pixel is lifted toward white at 100.
constant float kRPHairGlossLift = 0.25;
/// Fraction of the chroma replaced at "Nhuộm màu" = 100. Not 1: a full replace
/// flattens every strand to the same hue, and real dye leaves the natural
/// variation underneath.
constant float kRPHairDyeStrength = 0.85;
/// Largest factor the lightness step may multiply a pixel by. pow(y, 0.65) / y
/// grows without bound as y → 0, and near-black sensor noise with a bit of
/// chroma would otherwise turn into coloured speckle.
constant float kRPHairMaxLightRatio = 4.0;

kernel void rp_hair_composite(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> low [[texture(1)]],
    texture2d<float, access::read> hairMask [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    constant HairParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 src = source.read(gid);
    float m = hairMask.read(gid).r;

    // Bit-exact passthrough wherever nothing applies — the final clamp is not
    // the identity for out-of-range values, and "0 changes nothing" must hold
    // for them too.
    float active = m * (prm.gloss + prm.dye + abs(prm.lightnessExponent - 1.0));
    if (!(active > 0.0)) {
        destination.write(src, gid);
        return;
    }

    float3 c = src.rgb;

    // 1. Bóng tóc — first, while `c` and `low` are both the undyed picture, so
    //    (c - L) is texture and not the chroma difference the dye would add.
    if (prm.gloss > 0.0) {
        float3 L = low.read(gid).rgb;
        float g = prm.gloss * m;
        float sheen = saturate((dot(c, kRPLuma) - dot(L, kRPLuma)) / kRPHairGlossKnee);
        c = c + (c - L) * (g * kRPHairGlossContrast);
        c = c + (1.0 - c) * (g * sheen * kRPHairGlossLift);
    }

    // 2. Nhuộm màu — the tint scaled to this pixel's own luma, so brightness is
    //    kept and only the chroma moves. Consequence stated in ADR-0026: on
    //    near-black hair the dye is nearly invisible, which is also what dye
    //    without bleach does.
    if (prm.dye > 0.0) {
        float y = dot(c, kRPLuma);
        float3 dyed = prm.dyeTint.rgb * y;
        c = mix(c, dyed, prm.dye * m * kRPHairDyeStrength);
    }

    // 3. Sáng / Tối tóc — on luma, then every channel scaled by the same ratio.
    //    Per-channel gamma would shift the hue (a darkened brown drifts toward
    //    red, a lightened one toward yellow); a common ratio cannot.
    if (prm.lightnessExponent != 1.0) {
        float y = max(dot(c, kRPLuma), 0.0);
        float ratio = y > 1e-4
            ? min(pow(y, prm.lightnessExponent) / y, kRPHairMaxLightRatio)
            : 1.0;
        c = mix(c, c * ratio, m);
    }

    destination.write(float4(clamp(c, 0.0, 1.0), src.a), gid);
}
