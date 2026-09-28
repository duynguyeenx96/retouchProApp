// Phase 5 "Trang điểm" (makeup) render node kernel — docs/ADR-0027.
//
// Same single MTLLibrary as every other render kernel, appended **last** in
// MetalContext.shaderSources. It reuses, from earlier files of the one
// translation unit:
//   * `kRPLuma` (SkinShaders.metal);
//   * `ContourLobe` and `rp_contour_mask` (ColorShaders.metal) — "Má hồng" is two
//     soft ellipses per face, exactly the lobe shape "Tạo khối" draws, so it is
//     evaluated by the same function rather than a copy of it.
//
// Value space = gamma-encoded sRGB, 0…1, like every other render kernel.

#include <metal_stdlib>
using namespace metal;

/// Must match `MakeupParams` in MakeupRenderNode.swift; the Swift test pins the
/// stride (64) and the two float4 offsets (32, 48).
struct MakeupParams {
    uint2 size;
    float lipstick;          // 0…1
    float blush;             // 0…1
    float browsExponent;     // 1 = untouched; computed on the CPU
    uint blushLobeCount;
    float lipTintLuma;       // the lipstick colour's own luma
    float pad0;
    float4 lipTint;          // rgb normalised to luma 1
    float4 blushTint;        // rgb normalised to luma 1
};

/// Fraction of the lip colour replaced at "Son môi" = 100. Not 1, for the same
/// reason the hair dye is not: a full replace erases the lips' own variation.
constant float kRPLipstickStrength = 0.8;
/// How far the lips' luma moves toward the lipstick's own luma at full strength
/// (MakeupSliders.lipLumaPull — keep the two in step).
constant float kRPLipLumaPull = 0.4;
/// Fraction of the skin's chroma replaced by the blush tint at the lobe centre
/// and "Má hồng" = 100. Low on purpose: blush is a flush, not paint.
constant float kRPBlushStrength = 0.35;
/// Cap on the brow darkening ratio's inverse — the ratio can only go down, so
/// the cap here is a floor: never below 25 % of the original.
constant float kRPBrowMinRatio = 0.25;

kernel void rp_makeup_composite(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> lipsMask [[texture(1)]],
    texture2d<float, access::read> browsMask [[texture(2)]],
    texture2d<float, access::read> skinMask [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant MakeupParams &prm [[buffer(0)]],
    constant ContourLobe *lobes [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 src = source.read(gid);
    float lips = lipsMask.read(gid).r;
    float brows = browsMask.read(gid).r;
    float blushM = 0.0;
    if (prm.blush > 0.0 && prm.blushLobeCount > 0) {
        // Positive lobes only, so the clamp to -1…1 inside rp_contour_mask is a
        // clamp to 0…1 here. Skin-gated so a lobe overlapping an eye, a nostril
        // or a strand of hair on the cheek does not tint it.
        blushM = max(rp_contour_mask(lobes, prm.blushLobeCount, gid), 0.0)
               * skinMask.read(gid).r;
    }

    float active = lips * prm.lipstick + brows * abs(prm.browsExponent - 1.0)
                 + blushM * prm.blush;
    if (!(active > 0.0)) {
        destination.write(src, gid);
        return;
    }

    float3 c = src.rgb;

    // 1. Lông mày — luma exponent, every channel scaled by one ratio (never
    //    per-channel gamma: that shifts the hue, docs/ADR-0026).
    if (prm.browsExponent != 1.0 && brows > 0.0) {
        float y = max(dot(c, kRPLuma), 0.0);
        float ratio = y > 1e-4 ? max(pow(y, prm.browsExponent) / y, kRPBrowMinRatio) : 1.0;
        c = mix(c, c * ratio, brows);
    }

    // 2. Son môi — the tint at a luma pulled part-way to the lipstick's own.
    if (prm.lipstick > 0.0 && lips > 0.0) {
        float y = dot(c, kRPLuma);
        float yT = y + (prm.lipTintLuma - y) * kRPLipLumaPull;
        c = mix(c, prm.lipTint.rgb * yT, prm.lipstick * lips * kRPLipstickStrength);
    }

    // 3. Má hồng — chroma toward rose at the skin's own luma.
    if (blushM > 0.0) {
        float y = dot(c, kRPLuma);
        c = mix(c, prm.blushTint.rgb * y, prm.blush * blushM * kRPBlushStrength);
    }

    destination.write(float4(clamp(c, 0.0, 1.0), src.a), gid);
}
