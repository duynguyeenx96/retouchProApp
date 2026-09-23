// Phase 6.1 — the hand-painted mask ("Cọ mask thủ công", docs/PLAN.md §6.1).
//
// Compiled together with the other render kernels into one MTLLibrary by
// MetalContext — see its doc comment. This file must not redeclare anything
// Shaders.metal / SkinShaders.metal already declares.
//
// Three kernels, all on an r8Unorm coverage texture ("mask space"):
//
//   rp_manual_mask_clear     fill with a constant (0 = nothing painted);
//   rp_manual_mask_splat     stamp a batch of soft circles into the mask;
//   rp_manual_mask_modulate  multiply a *gated* copy of another coverage
//                            texture (the face/skin mask) by this one.
//
// ## Why the splat ping-pongs instead of writing in place
//
// The obvious shape is one `access::read_write` texture. `read_write` on an
// r8Unorm texture needs `MTLReadWriteTextureTier2`, which Apple silicon has and
// older Intel Macs do not, so the kernel would compile and then fail to create
// a pipeline on exactly the machines nobody tests on. Reading and writing the
// *same* texture through separate `read` / `write` bindings is not a fix either
// — it is undefined behaviour in Metal even when each thread only touches its
// own pixel. So the pass reads `source`, writes `destination`, and the CPU side
// swaps the two. The cost is one full-mask copy per batch (2048x1365 r8 is
// 2.8 MB, ~0.1 ms), which is why stamps are dispatched in batches rather than
// one dispatch per stamp.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// 1. Clear
// ---------------------------------------------------------------------------

struct RPManualMaskClearParams {
    uint2 size;
    float value;
};

kernel void rp_manual_mask_clear(
    texture2d<float, access::write> destination [[texture(0)]],
    constant RPManualMaskClearParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    destination.write(float4(prm.value, 0.0, 0.0, 1.0), gid);
}

// ---------------------------------------------------------------------------
// 2. Splat
//
// One stamp is a soft circle: full coverage out to `hardness x radius`, then a
// smoothstep down to zero at `radius`. `hardness = 1` is a hard-edged disc
// (still antialiased by the half-pixel the smoothstep spans), `hardness = 0` is
// a full-width falloff.
//
// The stamps of one batch combine with max() (add) or min() (subtract) rather
// than accumulating alpha. That is deliberate and is what makes undo-by-replay
// exact: max/min are idempotent and order-independent, so rasterising the first
// 40 stamps of a stroke and then the next 3 (which is what a live drag does)
// gives bit-identical output to rasterising all 43 in one go. An
// alpha-accumulating brush would instead darken wherever consecutive stamps
// overlap, i.e. everywhere, and the live result would drift from the replayed
// one.
// ---------------------------------------------------------------------------

struct RPManualMaskStamp {
    /// Centre in mask pixels, y down.
    float2 center;
    /// Radius in mask pixels, pressure already applied.
    float radius;
};

struct RPManualMaskSplatParams {
    uint2 size;
    /// 0…1 plateau fraction of the radius.
    float hardness;
    /// 0…1 peak coverage this stroke deposits.
    float flow;
    uint stampCount;
    /// 0 = add (max), 1 = subtract (min against 1 - coverage).
    uint subtract;
    /// Top-left of the dispatched region (the batch's bounding box); the grid
    /// covers only that region since 2026-09-23 (ADR-0019 addendum).
    uint2 origin;
};

kernel void rp_manual_mask_splat(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant RPManualMaskStamp *stamps [[buffer(0)]],
    constant RPManualMaskSplatParams &prm [[buffer(1)]],
    uint2 local [[thread_position_in_grid]])
{
    uint2 gid = local + prm.origin;
    if (gid.x >= prm.size.x || gid.y >= prm.size.y) { return; }
    float existing = source.read(gid).r;

    float2 q = float2(float(gid.x) + 0.5, float(gid.y) + 0.5);
    float plateau = clamp(prm.hardness, 0.0, 0.999);
    float coverage = 0.0;
    for (uint i = 0; i < prm.stampCount; ++i) {
        float radius = max(stamps[i].radius, 1e-4);
        float distance = length(q - stamps[i].center);
        if (distance >= radius) { continue; }
        float t = distance / radius;
        coverage = max(coverage, 1.0 - smoothstep(plateau, 1.0, t));
        if (coverage >= 1.0) { break; }
    }
    coverage *= clamp(prm.flow, 0.0, 1.0);

    float value = existing;
    if (coverage > 0.0) {
        value = prm.subtract != 0 ? min(existing, 1.0 - coverage)
                                  : max(existing, coverage);
    }
    destination.write(float4(value, 0.0, 0.0, 1.0), gid);
}

// ---------------------------------------------------------------------------
// 3. Modulate
//
// `coverage` is whatever the node already computed (rp_skin_mask's output, in
// image pixels); `manual` is the painted mask, which has its own size and its
// own affine back onto the image. Walking the *destination* and pulling is the
// same shape rp_skin_mask uses, for the same reason.
//
// Outside the painted canvas the result is 0, not the unmodulated coverage: a
// mask that does not cover a pixel has not selected it. The bounds test is
// explicit rather than clamp_to_edge for the reason rp_skin_mask gives —
// clamping would smear the border row across the whole frame.
// ---------------------------------------------------------------------------

struct RPManualMaskModulateParams {
    uint2 imageSize;
    uint2 maskSize;
    /// Rows of the image->mask affine, as (a, c, tx) so mask.x = dot(row, (x, y, 1)).
    float3 rowX;
    float3 rowY;
    /// 0 = the manual mask does nothing, 1 = it gates fully. A cross-fade rather
    /// than a hard switch so a future "strength" control needs no new kernel.
    float amount;
};

kernel void rp_manual_mask_modulate(
    texture2d<float, access::read> coverage [[texture(0)]],
    texture2d<float, access::sample> manual [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant RPManualMaskModulateParams &prm [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= prm.imageSize.x || gid.y >= prm.imageSize.y) { return; }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge,
                               filter::linear, mip_filter::none);
    float base = coverage.read(gid).r;
    float3 p = float3(float(gid.x) + 0.5, float(gid.y) + 0.5, 1.0);
    float2 mp = float2(dot(prm.rowX, p), dot(prm.rowY, p));
    float2 extent = float2(prm.maskSize);
    float painted = 0.0;
    if (mp.x >= 0.0 && mp.y >= 0.0 && mp.x < extent.x && mp.y < extent.y) {
        painted = manual.sample(bilinear, mp / extent).r;
    }
    float gated = base * painted;
    destination.write(float4(mix(base, gated, clamp(prm.amount, 0.0, 1.0)), 0.0, 0.0, 1.0), gid);
}
