// Phase 0 spike S3 kernels: guided filter + Moving-Least-Squares mesh warp.
// docs/PLAN.md §1.3 ("Mịn da giữ texture", "Bóp mặt … Moving Least Squares").
//
// This file is shipped as a SwiftPM *resource* and compiled at run time by
// MetalContext — SwiftPM's build system does not compile .metal sources. See
// MetalContext's doc comment.
//
// Coordinate conventions used throughout, stated once so they can be checked:
//   * image space  = pixels, origin top-left, y down (same as RPVision's
//     FaceCrop / FaceLandmarks478.imagePoints, so landmarks can be handed
//     straight to the warp with no flip);
//   * texture space = normalised (u, v) in [0,1], origin top-left, y down —
//     identical axes to image space, u = x / width;
//   * clip space   = x right in [-1,1], **y up** in [-1,1]. The vertex shader
//     is the only place the y flip happens.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Guided filter (He, Sun & Tang 2010; "fast guided filter" He & Sun 2015)
//
//   mean_I  = box_r(I)          mean_II = box_r(I*I)
//   var_I   = mean_II - mean_I^2
//   a       = var_I / (var_I + eps)      b = mean_I * (1 - a)
//   q       = box_r(a) * I + box_r(b)
//
// Self-guided (guide == input), per channel. The subsampled variant computes
// everything from `a`'s input down to box_r(b) at 1/s resolution and bilinearly
// upsamples a and b for the final reconstruction, which is what makes 24 MP
// affordable.
// ---------------------------------------------------------------------------

struct GFDownsampleParams {
    uint2 sourceSize;  // full-res pixels
    uint2 subSize;     // ceil(sourceSize / subsample)
    uint subsample;    // s >= 1
};

/// Box-averages each s×s block of the source into I and I*I at 1/s resolution.
/// A block average rather than a point sample: point sampling aliases the very
/// high-frequency skin texture this filter exists to preserve, which would make
/// the variance estimate noise-dependent.
kernel void rp_gf_downsample(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> outI [[texture(1)]],
    texture2d<float, access::write> outII [[texture(2)]],
    constant GFDownsampleParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.subSize.x || gid.y >= prm.subSize.y) { return; }
    uint x0 = gid.x * prm.subsample;
    uint y0 = gid.y * prm.subsample;
    uint x1 = min(x0 + prm.subsample, prm.sourceSize.x);
    uint y1 = min(y0 + prm.subsample, prm.sourceSize.y);
    float4 sum = float4(0.0);
    float4 sumSq = float4(0.0);
    float n = 0.0;
    for (uint y = y0; y < y1; ++y) {
        for (uint x = x0; x < x1; ++x) {
            float4 v = source.read(uint2(x, y));
            sum += v;
            sumSq += v * v;
            n += 1.0;
        }
    }
    float inv = (n > 0.0) ? (1.0 / n) : 0.0;
    outI.write(sum * inv, gid);
    outII.write(sumSq * inv, gid);
}

struct GFBoxParams {
    uint2 size;
    int radius;
};

/// Horizontal box pass over two textures at once (I and I*I, or a and b), so
/// the pair costs one dispatch instead of two.
kernel void rp_gf_box_h(
    texture2d<float, access::read> inA [[texture(0)]],
    texture2d<float, access::read> inB [[texture(1)]],
    texture2d<float, access::write> outA [[texture(2)]],
    texture2d<float, access::write> outB [[texture(3)]],
    constant GFBoxParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    int maxX = int(prm.size.x) - 1;
    float4 accA = float4(0.0);
    float4 accB = float4(0.0);
    float n = 0.0;
    for (int d = -prm.radius; d <= prm.radius; ++d) {
        int x = clamp(int(gid.x) + d, 0, maxX);  // clamp-to-edge
        accA += inA.read(uint2(uint(x), gid.y));
        accB += inB.read(uint2(uint(x), gid.y));
        n += 1.0;
    }
    outA.write(accA / n, gid);
    outB.write(accB / n, gid);
}

kernel void rp_gf_box_v(
    texture2d<float, access::read> inA [[texture(0)]],
    texture2d<float, access::read> inB [[texture(1)]],
    texture2d<float, access::write> outA [[texture(2)]],
    texture2d<float, access::write> outB [[texture(3)]],
    constant GFBoxParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    int maxY = int(prm.size.y) - 1;
    float4 accA = float4(0.0);
    float4 accB = float4(0.0);
    float n = 0.0;
    for (int d = -prm.radius; d <= prm.radius; ++d) {
        int y = clamp(int(gid.y) + d, 0, maxY);
        accA += inA.read(uint2(gid.x, uint(y)));
        accB += inB.read(uint2(gid.x, uint(y)));
        n += 1.0;
    }
    outA.write(accA / n, gid);
    outB.write(accB / n, gid);
}

struct GFCoefficientParams {
    uint2 size;
    float epsilon;
};

/// a = var / (var + eps), b = mean * (1 - a). Clamped variance: the box passes
/// are float32 but mean_II - mean_I^2 is a catastrophic cancellation on flat
/// regions and can land a few ULP below zero.
kernel void rp_gf_coefficients(
    texture2d<float, access::read> meanI [[texture(0)]],
    texture2d<float, access::read> meanII [[texture(1)]],
    texture2d<float, access::write> outA [[texture(2)]],
    texture2d<float, access::write> outB [[texture(3)]],
    constant GFCoefficientParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float4 mI = meanI.read(gid);
    float4 mII = meanII.read(gid);
    float4 variance = max(mII - mI * mI, float4(0.0));
    // max(..., 1e-20) rather than a plain divide: with epsilon = 0 a perfectly
    // flat region is 0/0 = NaN, and one NaN pixel poisons every box filter
    // downstream of it.
    float4 a = variance / max(variance + prm.epsilon, float4(1e-20));
    float4 b = mI * (float4(1.0) - a);
    outA.write(a, gid);
    outB.write(b, gid);
}

struct GFReconstructParams {
    uint2 size;
    // Denominator that maps a full-res pixel centre onto the subsampled
    // texture's normalised coordinates: u = (x + 0.5) / (s * subWidth).
    // Using (x + 0.5) / width instead is the classic half-texel error and
    // shifts the smoothed layer by (s-1)/2 pixels.
    float2 coefficientDenominator;
    float amount;  // 0 = original, 1 = fully filtered
};

kernel void rp_gf_reconstruct(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::sample> coefA [[texture(1)]],
    texture2d<float, access::sample> coefB [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    constant GFReconstructParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                               filter::linear, mip_filter::none);
    float2 uv = (float2(gid) + 0.5) / prm.coefficientDenominator;
    float4 I = source.read(gid);
    float4 a = coefA.sample(bilinear, uv);
    float4 b = coefB.sample(bilinear, uv);
    float4 q = a * I + b;
    float4 outValue = mix(I, q, prm.amount);
    outValue.a = I.a;  // alpha is carried, never filtered
    destination.write(outValue, gid);
}

// ---------------------------------------------------------------------------
// Moving Least Squares deformation (Schaefer, McPhail & Warren 2006)
//
// Written with complex arithmetic, which makes the *similarity* case exact and
// two lines long: minimising sum_i w_i |a * p̂_i - q̂_i|^2 over a complex `a` has
// the closed form a = sum_i w_i conj(p̂_i) q̂_i / sum_i w_i |p̂_i|^2, and
// f(v) = q* + a (v - p*). The *rigid* case is the same numerator normalised to
// unit modulus, which is Schaefer eq. (8) rewritten.
//
// One thread per grid vertex. The mesh warp evaluates this on a coarse grid and
// lets the rasteriser interpolate; running it per pixel is the same kernel with
// gridSize == imageSize, which is how the spike measures what the mesh buys.
// ---------------------------------------------------------------------------

struct MLSParams {
    uint controlCount;
    float alpha;       // weight exponent: w_i = 1 / |p_i - v|^(2*alpha)
    uint rigid;        // 0 = similarity (allows uniform scale), 1 = rigid
    uint _pad;
    uint2 gridSize;    // vertices, so cells = gridSize - 1
    float2 imageSize;  // pixels
};

static inline float2 rp_mls_evaluate(
    float2 v,
    device const float2 *P,
    device const float2 *Q,
    constant MLSParams &prm,
    float scale)
{
    // All of the weight maths runs in units of `scale` (the image's long edge)
    // so that 1/d^4 stays near 1.0 instead of near 1e-15 at 6000 px.
    float2 vn = v / scale;

    float wsum = 0.0;
    float2 pstar = float2(0.0);
    float2 qstar = float2(0.0);
    for (uint i = 0; i < prm.controlCount; ++i) {
        float2 p = P[i] / scale;
        float2 d = p - vn;
        float d2 = dot(d, d);
        if (d2 < 1e-14) { return Q[i]; }  // interpolation property: f(p_i) = q_i
        // alpha == 2 is the default and `pow` is ~10x a reciprocal here, so the
        // common case gets a closed form. Uniform branch, no divergence.
        float w = (prm.alpha == 2.0f) ? 1.0f / (d2 * d2) : pow(d2, -prm.alpha);
        wsum += w;
        pstar += w * p;
        qstar += w * (Q[i] / scale);
    }
    if (!(wsum > 0.0)) { return v; }
    pstar /= wsum;
    qstar /= wsum;

    float2 A = float2(0.0);  // sum_i w_i conj(p̂_i) q̂_i, as a complex number
    float mu = 0.0;
    for (uint i = 0; i < prm.controlCount; ++i) {
        float2 p = P[i] / scale;
        float2 d = p - vn;
        float d2 = dot(d, d);
        float w = (prm.alpha == 2.0f) ? 1.0f / (d2 * d2) : pow(d2, -prm.alpha);
        float2 ph = p - pstar;
        float2 qh = (Q[i] / scale) - qstar;
        A += w * float2(ph.x * qh.x + ph.y * qh.y, ph.x * qh.y - ph.y * qh.x);
        mu += w * dot(ph, ph);
    }

    float2 a;
    if (prm.rigid != 0) {
        float m = length(A);
        // Degenerate: every control point coincident, or the fit collapses.
        a = (m > 1e-20) ? (A / m) : float2(1.0, 0.0);
    } else {
        a = (mu > 1e-20) ? (A / mu) : float2(1.0, 0.0);
    }

    float2 dv = vn - pstar;
    float2 mapped = qstar + float2(a.x * dv.x - a.y * dv.y, a.x * dv.y + a.y * dv.x);
    return mapped * scale;
}

/// Deformed position for every vertex of a `gridSize.x × gridSize.y` lattice
/// spanning the whole image, written in image pixels (y down).
kernel void rp_mls_grid(
    device const float2 *P [[buffer(0)]],
    device const float2 *Q [[buffer(1)]],
    device float2 *out [[buffer(2)]],
    constant MLSParams &prm [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.gridSize.x || gid.y >= prm.gridSize.y) { return; }
    float2 cells = float2(prm.gridSize) - 1.0;
    float2 v = float2(gid) / max(cells, float2(1.0)) * prm.imageSize;
    float scale = max(prm.imageSize.x, prm.imageSize.y);
    out[gid.y * prm.gridSize.x + gid.x] = rp_mls_evaluate(v, P, Q, prm, scale);
}

// ---------------------------------------------------------------------------
// Mesh warp render pass.
//
// Forward warp, the way Schaefer's paper does it: a vertex sits at the deformed
// position f(v) and carries the *undeformed* texture coordinate v, so the
// rasteriser performs the inverse mapping for free and no per-pixel inverse has
// to be solved.
// ---------------------------------------------------------------------------

struct WarpVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex WarpVertexOut rp_warp_vertex(
    uint vid [[vertex_id]],
    device const float2 *deformed [[buffer(0)]],
    device const float2 *source [[buffer(1)]],
    constant float2 &imageSize [[buffer(2)]])
{
    float2 p = deformed[vid];
    float2 s = source[vid];
    WarpVertexOut out;
    // The single y flip: image space is y-down, clip space is y-up.
    out.position = float4(2.0 * p.x / imageSize.x - 1.0,
                          1.0 - 2.0 * p.y / imageSize.y,
                          0.0, 1.0);
    out.uv = s / imageSize;
    return out;
}

fragment float4 rp_warp_fragment(
    WarpVertexOut in [[stage_in]],
    texture2d<float, access::sample> source [[texture(0)]])
{
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                               filter::linear, mip_filter::none);
    return source.sample(bilinear, in.uv);
}
