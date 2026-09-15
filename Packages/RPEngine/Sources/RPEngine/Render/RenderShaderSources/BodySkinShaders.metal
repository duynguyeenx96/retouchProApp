// Phase 6 §6.2 "Sửa da" — đồng bộ da toàn thân.
//
// One kernel: it merges the whole-frame skin coverage (SkinCore / BodySkinMask,
// classical colour classification) with the per-face BiSeNet coverage that the
// "Da" group already rasterises, and hands SkinRenderNode's existing composite a
// single mask. **No retouch maths lives here** — the eight sliders and their
// kernel (rp_skin_composite, measured at 79.0 dB in docs/ADR-0009) are untouched
// by this feature; only what mask feeds them changes.
//
// Compiled together with the other RenderShaderSources files into one MTLLibrary
// by MetalContext, listed last in MetalContext.shaderSources so no other file's
// line numbers move. Same conventions as SkinShaders.metal: image space is
// pixels, origin top-left, y down.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Union with a feathered seam
//
// The two masks do not have equal standing:
//
//   * inside a face's parsing crop the BiSeNet mask is *authoritative*. It knows
//     that lips, eyes, brows, hair and glasses are not skin; the colour
//     classifier does not, and lips in particular score as skin (they sit inside
//     the CbCr skin ellipse). Letting the colour mask contribute there would
//     smooth the mouth.
//   * outside every crop — neck below the chin, shoulders, chest, arms — the
//     BiSeNet mask does not exist at all and the colour mask is all there is.
//
// So the merge is not max(face, body): it is
//
//     authority = smoothstep over the distance to the crop border, in mask px
//     out       = max(face, body * (1 - authority))
//
// `authority` is 1 well inside a crop and ramps to 0 across a band `feather`
// wide at its border, which for a CelebAMask-HQ-framed crop (1.87 x face width)
// runs across the neck — the seam the plan asks to be feathered so the two masks
// do not meet at a visible edge. `max` with the face mask keeps the guarantee
// that turning this feature on can never *weaken* the mask inside the face:
// the union is >= the face mask everywhere, pixel for pixel.
//
// The distance is computed analytically from the same image->mask affine the
// rasteriser uses, so nothing extra is uploaded and the ramp has no texture
// quantisation of its own.
// ---------------------------------------------------------------------------

struct BodySkinUnionParams {
    uint2 size;
    uint faceCount;
};

struct BodySkinUnionTransform {
    /// Rows of the image->mask affine, as (a, c, tx) — same packing as
    /// SkinMaskTransform in SkinShaders.metal.
    float3 rowX;
    float3 rowY;
    /// The crop's size in mask pixels.
    float2 maskSize;
    /// Width of the authority ramp, in mask pixels.
    float feather;
};

kernel void rp_body_skin_union(
    texture2d<float, access::read> faceMask [[texture(0)]],
    texture2d<float, access::read> bodyMask [[texture(1)]],
    texture2d<float, access::write> outMask [[texture(2)]],
    constant BodySkinUnionTransform *transforms [[buffer(0)]],
    constant BodySkinUnionParams &prm [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float f = faceMask.read(gid).r;
    float b = bodyMask.read(gid).r;

    float3 p = float3(float(gid.x) + 0.5, float(gid.y) + 0.5, 1.0);
    float authority = 0.0;
    for (uint i = 0; i < prm.faceCount; ++i) {
        float2 mp = float2(dot(transforms[i].rowX, p), dot(transforms[i].rowY, p));
        float2 extent = transforms[i].maskSize;
        // Signed distance to the nearest crop edge, in mask pixels: positive
        // inside, negative outside.
        float d = min(min(mp.x, mp.y), min(extent.x - mp.x, extent.y - mp.y));
        float t = saturate(d / max(transforms[i].feather, 1e-3));
        t = t * t * (3.0 - 2.0 * t);  // smoothstep: no kink where the ramp ends
        authority = max(authority, t);
    }

    float u = max(f, b * (1.0 - authority));
    outMask.write(float4(u, u, u, 1.0), gid);
}
